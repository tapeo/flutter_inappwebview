//
//  ExtensionManager.swift
//  flutter_inappwebview
//
//  Created by Lorenzo on 21/10/18.
//

import AppKit
import FlutterMacOS
import Foundation
@preconcurrency import WebKit

@MainActor
final class ExtensionManager: NSObject, ObservableObject, WKWebExtensionControllerDelegate {
    static let shared = ExtensionManager()

    private struct WeakWebView {
        weak var value: WKWebView?
    }

    private struct InstalledSafariExtensionMetadata {
        let name: String
        let path: String
        let iconBase64: String?
        let description: String?
    }

    private struct DiscoveredSafariExtension {
        let bundleURL: URL
        let metadata: InstalledSafariExtensionMetadata
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
    private let readinessTimeout: TimeInterval = 20.0
    private let readinessStep: TimeInterval = 0.05
    private let tabReadinessTimeout: TimeInterval = 5.0
    private var preparingTask: Task<Bool, Never>?
    private let extensionWindow: SimpleExtensionWindow?
    private weak var lastActiveTabRef: SimpleExtensionTab?
    private var pendingControllerActions: [() -> Void] = []
    private var didNotifyWindowOpen = false
    private var acknowledgedTabs: Set<String> = []
    private let popupManager = ExtensionPopupWindowManager.shared
    private var extensionMetadata: [String: InstalledSafariExtensionMetadata] = [:]

    var extensionController: WKWebExtensionController? { controller }
    var extensionContext: WKWebExtensionContext? { controller?.extensionContexts.first }
    var isReady: Bool { !contexts.isEmpty && contexts.allSatisfy { $0.isLoaded } }

    override init() {
        if #available(macOS 15.4, *) {
            extensionWindow = SimpleExtensionWindow(identifier: "pola-main-window")
        } else {
            extensionWindow = nil
        }
        super.init()

        popupManager.onPopoverClosed = { [weak self] extensionId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard #available(macOS 15.4, *) else { return }
                guard let context = self.contexts.first(where: { $0.uniqueIdentifier == extensionId }) else { return }
                context.action(for: nil)?.closePopup()
            }
        }
    }

    // MARK: Public API

    static func prepareExtensionSystem() async -> Bool {
        guard ExtensionUtils.isExtensionSupportAvailable else {
            ExtensionUtils.showUnsupportedOSAlert()
            return false
        }

        let pendingTask = await MainActor.run { () -> Task<Bool, Never>? in
            let manager = shared
            manager.startPreparationIfNeeded()
            return manager.preparingTask
        }

        if let pendingTask {
            return await pendingTask.value
        }

        return await MainActor.run { shared.isReady }
    }

    func installAndLoadExtensions() {
        startPreparationIfNeeded()
    }

    func applyExtensions(to configuration: WKWebViewConfiguration) {
        if let controller {
            configuration.webExtensionController = controller
            return
        }

        if let controller {
            configuration.webExtensionController = controller
        }
    }

    func registerWebView(_ webView: WKWebView, id: String) {
        webViews[id] = WeakWebView(value: webView)
        identifierForWebView.setObject(id as NSString, forKey: webView)
        lastActiveWebView = webView

        if #available(macOS 15.4, *) {
            let tab: SimpleExtensionTab
            if let existing = tabs[id] {
                existing.attach(webView: webView)
                tab = existing
            } else {
                let created = SimpleExtensionTab(webView: webView, identifier: id)
                tabs[id] = created
                tab = created
            }

            acknowledgedTabs.remove(id)
            extensionWindow?.attach(tab: tab)
            enqueueControllerAction { [weak self, weak tab] in
                guard let self,
                      let controller = self.controller,
                      let tab else { return }
                controller.didOpenTab(tab)
                self.notifyInitialState(for: tab, controller: controller)
            }
        }
    }

    func unregisterWebView(id: String) {
        if let webView = webViews[id]?.value {
            identifierForWebView.removeObject(forKey: webView)
        }
        webViews.removeValue(forKey: id)
        if #available(macOS 15.4, *), let tab = tabs.removeValue(forKey: id) {
            extensionWindow?.detach(tab: tab)
            enqueueControllerAction { [weak self, weak tab] in
                guard let self,
                      let controller = self.controller,
                      let tab else { return }
                controller.didCloseTab(tab, windowIsClosing: false)
            }
            if lastActiveTabRef === tab {
                lastActiveTabRef = nil
            }
            acknowledgedTabs.remove(id)
        }
    }

    func markWebViewActive(_ webView: WKWebView) {
        lastActiveWebView = webView
        guard #available(macOS 15.4, *),
              let tab = tab(for: webView) else { return }

        let previousTab = lastActiveTabRef
        if previousTab === tab { return }

        lastActiveTabRef = tab
        extensionWindow?.markActive(tab)

        enqueueControllerAction { [weak self, weak tab] in
            guard let self,
                  let controller = self.controller,
                  let tab else { return }
            controller.didActivateTab(tab, previousActiveTab: previousTab)
            controller.didSelectTabs([tab])
            if let previous = previousTab, previous !== tab {
                controller.didDeselectTabs([previous])
            }
        }
    }

    func updatePendingNavigation(for webView: WKWebView, url: URL?) {
        guard #available(macOS 15.4, *),
              let id = identifierForWebView.object(forKey: webView) as String?,
              let tab = tabs[id] else { return }
        let changed = tab.updatePendingNavigation(url)
        notifyTabProperties(changed, for: tab)
        lastActiveWebView = webView
    }

    func commitNavigation(for webView: WKWebView, url: URL?) {
        guard #available(macOS 15.4, *),
              let id = identifierForWebView.object(forKey: webView) as String?,
              let tab = tabs[id] else { return }
        let changed = tab.commitNavigation(url)
        notifyTabProperties(changed, for: tab)
        lastActiveWebView = webView
    }

    func updateTitle(for webView: WKWebView, title: String?) {
        guard #available(macOS 15.4, *),
              let id = identifierForWebView.object(forKey: webView) as String?,
              let tab = tabs[id] else { return }
        let changed = tab.updateTitle(title)
        notifyTabProperties(changed, for: tab)
    }

    func updateLoadingState(for webView: WKWebView, isLoading: Bool) {
        guard #available(macOS 15.4, *),
              let id = identifierForWebView.object(forKey: webView) as String?,
              let tab = tabs[id] else { return }
        var changed = tab.updateLoadingState(isLoading)
        if !isLoading {
            changed.formUnion(tab.clearPendingNavigation())
        }
        notifyTabProperties(changed, for: tab)
    }

    #if os(macOS)
    func updateWindow(for webView: WKWebView, window: NSWindow?) {
        guard #available(macOS 15.4, *),
              let tab = tab(for: webView) else { return }
        extensionWindow?.updateWindowReference(window)
        if window != nil {
            extensionWindow?.attach(tab: tab)
        }
        ensureWindowRegisteredWithController()
    }
    #endif

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
            let webExtension = context.webExtension
            let action = context.action(for: nil)
            let metadata = extensionMetadata[context.uniqueIdentifier]
            let resolvedName = webExtension.displayName
                ?? webExtension.displayShortName
                ?? action?.label
                ?? metadata?.name
                ?? "Unknown"
            let resolvedVersion = webExtension.displayVersion
                ?? webExtension.version
                ?? "Unknown"
            let resolvedDescription = webExtension.displayDescription
                ?? metadata?.description
                ?? ""

            var data: [String: Any] = [
                "id": context.uniqueIdentifier,
                "name": resolvedName,
                "version": resolvedVersion,
                "isLoaded": context.isLoaded,
                "hasPopup": action?.presentsPopup ?? false,
                "description": resolvedDescription
            ]

            if let path = metadata?.path { data["path"] = path }
            if let iconBase64 = metadata?.iconBase64 { data["icon"] = iconBase64 }

            return data
        }
    }

    func setExtensionEnabled(extensionId: String, isEnabled: Bool) -> Bool {
        guard ExtensionUtils.isExtensionSupportAvailable else { return false }

        guard let context = contexts.first(where: { $0.uniqueIdentifier == extensionId }) else {
            print("[ExtensionManager] No extension context found for id \(extensionId)")
            return false
        }

        guard let controller else {
            print("[ExtensionManager] Controller not ready while toggling extension \(extensionId)")
            return false
        }

        do {
            if isEnabled {
                try? controller.unload(context)
                try controller.load(context)
                ensureWindowRegisteredWithController()
            } else {
                guard context.isLoaded else { return true }
                try controller.unload(context)
            }
            return true
        } catch {
            print("[ExtensionManager] Failed to toggle extension \(extensionId) to \(isEnabled ? "enabled" : "disabled"): \(error)")
            return false
        }
    }

func getExtensionsDirectoryPath() -> String {
    let extensionsDir = Self.getExtensionsDirectory()
    do {
        try FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true, attributes: nil)
    } catch {
        print("Failed to create extensions directory: \(error)")
    }

    let foldersDir = extensionsDir.appendingPathComponent("Folders")
    do {
        try FileManager.default.createDirectory(at: foldersDir, withIntermediateDirectories: true, attributes: nil)
    } catch {
        print("Failed to create Folders directory: \(error)")
    }

    let bundlesDir = extensionsDir.appendingPathComponent("Bundles")
    do {
        try FileManager.default.createDirectory(at: bundlesDir, withIntermediateDirectories: true, attributes: nil)
    } catch {
        print("Failed to create Bundles directory: \(error)")
    }

    return extensionsDir.path
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

    func webExtensionController(_ controller: WKWebExtensionController,
                                openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        guard #available(macOS 15.4, *),
              let extensionWindow = extensionWindow,
              !extensionWindow.currentTabs().isEmpty else { return [] }
        return [extensionWindow]
    }

    func webExtensionController(_ controller: WKWebExtensionController,
                                focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard #available(macOS 15.4, *),
              let extensionWindow = extensionWindow else { return nil }
        return activeTab() == nil ? nil : extensionWindow
    }

    @available(macOS 15.4, *)
    func webExtensionController(_ controller: WKWebExtensionController,
                                presentActionPopup action: WKWebExtension.Action,
                                for extensionContext: WKWebExtensionContext,
                                completionHandler: @escaping (Error?) -> Void) {
        guard #available(macOS 15.4, *) else {
            completionHandler(NSError(
                domain: "ExtensionManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Extension popups require macOS 15.4 or newer"]
            ))
            return
        }

        guard action.presentsPopup, let popover = action.popupPopover else {
            completionHandler(NSError(
                domain: "ExtensionManager",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Extension action does not provide a popup"]
            ))
            return
        }
        
        action.webExtensionContext?.isInspectable = true
        extensionContext.isInspectable = true
        action.popupWebView?.isInspectable = true
        
        let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15"
        action.popupWebView?.customUserAgent = ua
            
        popupManager.closeExistingPopoverForExtension(extensionContext.uniqueIdentifier)

        let targetTab: SimpleExtensionTab?
        if let associatedTab = action.associatedTab as? SimpleExtensionTab {
            targetTab = associatedTab
        } else {
            targetTab = activeTab()
        }

        guard let tab = targetTab,
              let anchorView = tab.webView(for: extensionContext) ?? lastActiveWebView else {
            completionHandler(NSError(
                domain: "ExtensionManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to determine anchor view for extension popup"]
            ))
            return
        }

        Task { @MainActor in
            if let window = anchorView.window {
                extensionWindow?.updateWindowReference(window)
            }

            popover.behavior = .semitransient
            popupManager.addPopover(popover, forExtension: extensionContext.uniqueIdentifier)
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)

            completionHandler(nil)
        }
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
            ensureWindowRegisteredWithController()
            flushPendingControllerActions()
            return true
        } catch {
            print("[ExtensionManager] Failed to prepare extensions: \(error)")
            return false
        }
    }

    @MainActor
    private func loadExtensionsFromDisk() async throws -> [WKWebExtensionContext] {
        var contexts: [WKWebExtensionContext] = []
        var loadedIdentifiers: Set<String> = []
        extensionMetadata.removeAll()

        let installed = await loadInstalledSafariExtensionContexts()
        contexts.append(contentsOf: installed.contexts)
        extensionMetadata.merge(installed.metadata) { current, _ in current }
        loadedIdentifiers.formUnion(installed.identifiers)

        let legacy = await loadLegacyExtensionContexts(excluding: loadedIdentifiers)
        contexts.append(contentsOf: legacy.contexts)
        extensionMetadata.merge(legacy.metadata) { current, _ in current }
        loadedIdentifiers.formUnion(legacy.identifiers)

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

    private func startPreparationIfNeeded() {
        guard ExtensionUtils.isExtensionSupportAvailable else { return }
        guard controller == nil else { return }
        guard preparingTask == nil else { return }

        preparingTask = Task { @MainActor [weak self] in
            guard let self else { return false }
            defer { self.preparingTask = nil }
            return await self.prepareIfNeeded()
        }
    }

    private func enqueueControllerAction(_ action: @escaping () -> Void) {
        if controller != nil {
            ensureWindowRegisteredWithController()
            action()
        } else {
            pendingControllerActions.append { [weak self] in
                guard let self else { return }
                self.ensureWindowRegisteredWithController()
                action()
            }
        }
    }

    private func flushPendingControllerActions() {
        guard controller != nil else { return }
        let actions = pendingControllerActions
        pendingControllerActions.removeAll()
        actions.forEach { $0() }
    }

    private func ensureWindowRegisteredWithController() {
        guard #available(macOS 15.4, *),
              let controller = controller,
              let extensionWindow = extensionWindow else { return }
        if !didNotifyWindowOpen {
            controller.didOpenWindow(extensionWindow)
            didNotifyWindowOpen = true
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
        acknowledgedTabs.remove(id)
        return tab
    }

    @available(macOS 15.4, *)
    private func activeTab() -> SimpleExtensionTab? {
        if let tab = lastActiveTabRef {
            return tab
        }
        if let windowTab = extensionWindow?.currentTabs().first {
            lastActiveTabRef = windowTab
            return windowTab
        }
        if let webView = lastActiveWebView, let tab = tab(for: webView) {
            lastActiveTabRef = tab
            return tab
        }
        for case let (_, wrapper) in webViews {
            if let webView = wrapper.value, let tab = tab(for: webView) {
                lastActiveWebView = webView
                lastActiveTabRef = tab
                return tab
            }
        }
        return nil
    }

    @available(macOS 15.4, *)
    private func notifyTabProperties(_ properties: WKWebExtension.TabChangedProperties, for tab: SimpleExtensionTab) {
        guard !properties.isEmpty else { return }
        enqueueControllerAction { [weak self, weak tab] in
            guard let self,
                  let controller = self.controller,
                  let tab else { return }
            controller.didChangeTabProperties(properties, for: tab)
        }
    }

    @available(macOS 15.4, *)
    private func notifyInitialState(for tab: SimpleExtensionTab, controller: WKWebExtensionController) {
        controller.didChangeTabProperties([.URL, .title, .loading], for: tab)
    }

    @available(macOS 15.4, *)
    private func contextContainsTab(_ context: WKWebExtensionContext, tab: SimpleExtensionTab) -> Bool {
        for entry in context.openTabs {
            let base = entry.base
            if let candidate = base as? SimpleExtensionTab, candidate === tab {
                return true
            }
            if let candidate = base as? NSObject, candidate === tab {
                return true
            }
        }
        return false
    }

    static func getExtensionsDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Pola").appendingPathComponent("Extensions")
    }

    // MARK: - Safari extension discovery

    private func loadInstalledSafariExtensionContexts() async -> (contexts: [WKWebExtensionContext], metadata: [String: InstalledSafariExtensionMetadata], identifiers: Set<String>) {
        var contexts: [WKWebExtensionContext] = []
        var metadata: [String: InstalledSafariExtensionMetadata] = [:]
        var identifiers: Set<String> = []

        for discoveredExtension in discoverInstalledSafariExtensions() {
            do {
                guard let bundle = Bundle(url: discoveredExtension.bundleURL) else {
                    continue
                }

                let webExtension = try await WKWebExtension(appExtensionBundle: bundle)
                let context = WKWebExtensionContext(for: webExtension)

                let identifier = context.uniqueIdentifier
                if identifiers.contains(identifier) { continue }
                identifiers.insert(identifier)

                metadata[identifier] = discoveredExtension.metadata

                grantPermissions(to: context, for: webExtension)
                contexts.append(context)
            } catch {
                print("[ExtensionManager] Failed to load installed extension from \(discoveredExtension.bundleURL.path): \(error)")
            }
        }

        return (contexts, metadata, identifiers)
    }

    private func loadLegacyExtensionContexts(excluding existingIdentifiers: Set<String>) async -> (contexts: [WKWebExtensionContext], metadata: [String: InstalledSafariExtensionMetadata], identifiers: Set<String>) {
        var contexts: [WKWebExtensionContext] = []
        var metadata: [String: InstalledSafariExtensionMetadata] = [:]
        var identifiers: Set<String> = []
        let fm = FileManager.default

        let userRoot = ExtensionManager.getExtensionsDirectory().appendingPathComponent("Folders")
        let bundleRoot = ExtensionManager.getExtensionsDirectory().appendingPathComponent("Bundles")

        // Load folder-based extensions (unpacked)
        if let userContents = try? fm.contentsOfDirectory(at: userRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for entry in userContents {
                let manifestURL = entry.appendingPathComponent("manifest.json")
                guard fm.fileExists(atPath: manifestURL.path) else { continue }

                do {
                    let webExtension = try await WKWebExtension(resourceBaseURL: entry)
                    let context = WKWebExtensionContext(for: webExtension)
                    let identifier = context.uniqueIdentifier
                    if existingIdentifiers.contains(identifier) || identifiers.contains(identifier) { continue }

                    identifiers.insert(identifier)
                    grantPermissions(to: context, for: webExtension)

                    let name = webExtension.displayName
                        ?? webExtension.displayShortName
                        ?? entry.lastPathComponent

                    let description = trimmedNonEmpty(webExtension.displayDescription)

                    metadata[identifier] = InstalledSafariExtensionMetadata(
                        name: name,
                        path: entry.path,
                        iconBase64: nil,
                        description: description
                    )

                    contexts.append(context)
                } catch {
                    print("[ExtensionManager] Failed to load folder extension from \(entry.path): \(error)")
                }
            }
        }

        // Load bundled extensions (.appex bundles placed by user)
        if let bundleContents = try? fm.contentsOfDirectory(at: bundleRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for entry in bundleContents {
                guard entry.pathExtension == "appex" else { continue }
                do {
                    guard let bundle = Bundle(url: entry) else { continue }
                    let webExtension = try await WKWebExtension(appExtensionBundle: bundle)
                    let context = WKWebExtensionContext(for: webExtension)
                    let identifier = context.uniqueIdentifier
                    if existingIdentifiers.contains(identifier) || identifiers.contains(identifier) { continue }

                    identifiers.insert(identifier)
                    grantPermissions(to: context, for: webExtension)

                    let name = webExtension.displayName
                        ?? webExtension.displayShortName
                        ?? entry.deletingPathExtension().lastPathComponent

                    let description = trimmedNonEmpty(webExtension.displayDescription)

                    let metadataEntry = InstalledSafariExtensionMetadata(
                        name: name,
                        path: entry.path,
                        iconBase64: loadIconBase64(forExtensionAt: entry),
                        description: description
                    )

                    metadata[identifier] = metadataEntry
                    contexts.append(context)
                } catch {
                    print("[ExtensionManager] Failed to load bundle extension from \(entry.path): \(error)")
                }
            }
        }

        return (contexts, metadata, identifiers)
    }

    private func discoverInstalledSafariExtensions() -> [DiscoveredSafariExtension] {
        let fileManager = FileManager.default
        var discovered: [DiscoveredSafariExtension] = []
        var seenPaths = Set<String>()

        for directory in safariApplicationDirectories() {
            guard fileManager.fileExists(atPath: directory.path) else { continue }

            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "app" {
                for extensionInfo in safariExtensions(inAppBundle: fileURL) {
                    let path = extensionInfo.bundleURL.path
                    guard !seenPaths.contains(path) else { continue }
                    seenPaths.insert(path)
                    discovered.append(extensionInfo)
                }
            }
        }

        return discovered
    }

    private func safariApplicationDirectories() -> [URL] {
        var directories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        ]

        if let userApplications = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            directories.append(userApplications)
        }

        return directories
    }

    private func safariExtensions(inAppBundle appURL: URL) -> [DiscoveredSafariExtension] {
        let plugInsURL = appURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: plugInsURL.path) else { return [] }

        guard let plugInContents = try? fileManager.contentsOfDirectory(
            at: plugInsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return plugInContents.compactMap { extensionBundleURL in
            guard extensionBundleURL.pathExtension == "appex" else { return nil }
            guard let metadata = extensionMetadata(forExtensionBundleAt: extensionBundleURL) else { return nil }
            return DiscoveredSafariExtension(bundleURL: extensionBundleURL, metadata: metadata)
        }
    }

    private func extensionMetadata(forExtensionBundleAt bundleURL: URL) -> InstalledSafariExtensionMetadata? {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")

        guard
            let infoPlist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any],
            let extensionDictionary = infoPlist["NSExtension"] as? [String: Any],
            let extensionPointIdentifier = extensionDictionary["NSExtensionPointIdentifier"] as? String,
            extensionPointIdentifier.hasPrefix("com.apple.Safari")
        else {
            return nil
        }

        let name = (infoPlist["CFBundleDisplayName"] as? String)
            ?? (infoPlist["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent

        let iconBase64 = loadIconBase64(forExtensionAt: bundleURL)

        let descriptionFromPlist = infoPlist["NSHumanReadableDescription"] as? String
        let description = trimmedNonEmpty(descriptionFromPlist)
            ?? loadManifestDescription(forExtensionAt: bundleURL)

        return InstalledSafariExtensionMetadata(
            name: name,
            path: bundleURL.path,
            iconBase64: iconBase64,
            description: description
        )
    }

    private func loadIconBase64(forExtensionAt bundleURL: URL) -> String? {
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 64, height: 64)

        guard
            let tiffData = icon.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        return pngData.base64EncodedString()
    }

    private func loadManifestDescription(forExtensionAt bundleURL: URL) -> String? {
        let manifestURL = bundleURL.appendingPathComponent("Contents/Resources/manifest.json")

        guard
            let data = try? Data(contentsOf: manifestURL),
            let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
            let manifest = jsonObject as? [String: Any],
            let description = manifest["description"] as? String
        else {
            return nil
        }

        return trimmedNonEmpty(description)
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
