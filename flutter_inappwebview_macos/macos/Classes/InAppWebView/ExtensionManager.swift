//
//  ExtensionManager.swift
//  flutter_inappwebview
//
//  Created by Lorenzo on 21/10/18.
//

import FlutterMacOS
import Foundation
@preconcurrency import WebKit

final class ExtensionManager: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    static let shared = ExtensionManager()

    private struct WeakWebView {
        weak var value: WKWebView?
    }

    private static let commonPermissions: [WKWebExtension.Permission] = [
        .storage,
        .tabs,
        .activeTab,
        .scripting,
        .alarms,
        .contextMenus,
        .declarativeNetRequest,
        .webNavigation,
        .cookies
    ]

    private var controller: WKWebExtensionController?
    private var contexts: [WKWebExtensionContext] = []
    private var webViews: [String: WeakWebView] = [:]
    private var identifierForWebView = NSMapTable<WKWebView, NSString>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private weak var lastActiveWebView: WKWebView?
    private var tabs: [String: SimpleExtensionTab] = [:]
    private let readinessTimeout: TimeInterval = 5.0
    private let readinessStep: TimeInterval = 0.05
    private var preparingTask: Task<Bool, Never>?

    var extensionController: WKWebExtensionController? { controller }
    var extensionContext: WKWebExtensionContext? { controller?.extensionContexts.first }
    var isReady: Bool { !contexts.isEmpty && contexts.allSatisfy { $0.isLoaded } }

    // MARK: Public API

    static func prepareExtensionSystem() async -> Bool {
        guard ExtensionUtils.isExtensionSupportAvailable else {
            ExtensionUtils.showUnsupportedOSAlert()
            return false
        }
        return await shared.prepareIfNeeded()
    }

    func installAndLoadExtensions() {
        if controller != nil { return }
        if preparingTask != nil { return }
        preparingTask = Task { [weak self] in
            defer { self?.preparingTask = nil }
            return await ExtensionManager.prepareExtensionSystem()
        }
    }

    func applyExtensions(to configuration: WKWebViewConfiguration) {
        if let controller {
            configuration.webExtensionController = controller
            return
        }

        Task { @MainActor [weak self, weak configuration] in
            guard let self else { return }
            let success = await ExtensionManager.prepareExtensionSystem()
            guard success, let controller = self.controller else { return }
            configuration?.webExtensionController = controller
        }
    }

    func registerWebView(_ webView: WKWebView, id: String) {
        webViews[id] = WeakWebView(value: webView)
        identifierForWebView.setObject(id as NSString, forKey: webView)
        lastActiveWebView = webView

        if #available(macOS 15.4, *) {
            if let existing = tabs[id] {
                existing.attach(webView: webView)
            } else {
                tabs[id] = SimpleExtensionTab(webView: webView, identifier: id)
            }
        }
    }

    func unregisterWebView(id: String) {
        if let webView = webViews[id]?.value {
            identifierForWebView.removeObject(forKey: webView)
        }
        webViews.removeValue(forKey: id)
        tabs.removeValue(forKey: id)
    }

    func markWebViewActive(_ webView: WKWebView) {
        lastActiveWebView = webView
    }

    func waitForExtensionRulesSync() {
        guard !isReady else { return }
        waitUntilReady()
    }

    func ensureAllExtensionsReady() {
        waitUntilReady()
    }

    func openExtensionPopup(for extensionId: String) -> Bool {
        guard let controller = controller else { return false }
        guard let context = controller.extensionContexts.first(where: { $0.uniqueIdentifier == extensionId }) else { return false }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if #available(macOS 15.4, *) {
                context.performAction(for: self.activeTab())
            } else {
                context.performAction(for: nil)
            }
        }
        return true
    }

    func getAllInstalledExtensions() -> [[String: Any]] {
        contexts.map { context in
            [
                "id": context.uniqueIdentifier,
                "name": context.webExtension.displayName ?? "Unknown",
                "version": context.webExtension.version ?? "Unknown",
                "isLoaded": context.isLoaded
            ]
        }
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                for context: WKWebExtensionContext,
                                completionHandler: @escaping (WKWebExtensionTab?, Error?) -> Void) {
        guard #available(macOS 15.4, *) else {
            completionHandler(nil, nil)
            return
        }

        guard let webView = lastActiveWebView ?? webViews.values.compactMap({ $0.value }).first else {
            completionHandler(nil, nil)
            return
        }

        if let url = configuration.url {
            DispatchQueue.main.async { [weak webView] in
                if let webView { webView.load(URLRequest(url: url)) }
            }
        }

        completionHandler(tab(for: webView), nil)
    }

    // MARK: - Private helpers

    @MainActor
    private func prepareIfNeeded() async -> Bool {
        if let controller, !controller.extensionContexts.isEmpty {
            contexts = Array(controller.extensionContexts)
            return true
        }

        do {
            let loadedContexts = try await loadExtensionsFromDisk()
            guard !loadedContexts.isEmpty else { return false }

            let controller = WKWebExtensionController()
            controller.delegate = self

            for context in loadedContexts {
                try controller.load(context)
            }

            self.controller = controller
            self.contexts = loadedContexts
            return true
        } catch {
            print("[ExtensionManager] Failed to prepare extensions: \(error)")
            return false
        }
    }

    @MainActor
    private func loadExtensionsFromDisk() async throws -> [WKWebExtensionContext] {
        let root = ExtensionManager.getExtensionsDirectory()
        var contexts: [WKWebExtensionContext] = []
        let fm = FileManager.default

        guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else {
            return []
        }

        for entry in contents {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

            let manifestURL = entry.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            _ = try ExtensionUtils.validateManifest(at: manifestURL)
            let webExtension = try await WKWebExtension(resourceBaseURL: entry)
            let context = WKWebExtensionContext(for: webExtension)

            grantPermissions(to: context, for: webExtension)
            contexts.append(context)
        }

        return contexts
    }

    private func grantPermissions(to context: WKWebExtensionContext, for webExtension: WKWebExtension) {
        for permission in Self.commonPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }

        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }

        if let allURLs = try? WKWebExtension.MatchPattern.allURLs() {
            context.setPermissionStatus(.grantedExplicitly, for: allURLs)
        }
    }

    private func waitUntilReady() {
        let deadline = Date().addingTimeInterval(readinessTimeout)
        while Date() < deadline {
            if isReady { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(readinessStep))
        }
    }

    @available(macOS 15.4, *)
    private func tab(for webView: WKWebView) -> SimpleExtensionTab? {
        guard let id = identifierForWebView.object(forKey: webView) as String? else { return nil }
        if let tab = tabs[id] {
            tab.attach(webView: webView)
            return tab
        }
        let tab = SimpleExtensionTab(webView: webView, identifier: id)
        tabs[id] = tab
        return tab
    }

    @available(macOS 15.4, *)
    private func activeTab() -> SimpleExtensionTab? {
        if let webView = lastActiveWebView, let tab = tab(for: webView) {
            return tab
        }
        for case let (id, wrapper) in webViews {
            if let webView = wrapper.value {
                lastActiveWebView = webView
                return tab(for: webView) ?? tabs[id]
            }
        }
        return nil
    }

    static func getExtensionsDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Pola").appendingPathComponent("Extensions")
    }
}
