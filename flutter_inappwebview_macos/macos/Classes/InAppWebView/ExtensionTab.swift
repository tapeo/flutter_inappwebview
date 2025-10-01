//
//  ExtensionTab.swift
//  flutter_inappwebview
//
//  Simplified tab wrapper for WKWebExtension integration.
//

import AppKit
import Foundation
@preconcurrency import WebKit

@available(macOS 15.4, *)
private extension WKWebExtension.TabChangedProperties {
    static let loading = Self(rawValue: UInt(1) << 1)
    static let title = Self(rawValue: UInt(1) << 7)
    static let url = Self(rawValue: UInt(1) << 8)
}

@available(macOS 15.4, *)
final class SimpleExtensionWindow: NSObject, WKWebExtensionWindow {
    private struct WeakTab {
        weak var value: SimpleExtensionTab?
    }

    let identifier: String
    private var tabs: [WeakTab] = []
    private weak var activeTab: SimpleExtensionTab?
    private weak var nsWindow: NSWindow?

    init(identifier: String) {
        self.identifier = identifier
        super.init()
    }

    func attach(tab: SimpleExtensionTab) {
        cleanTabs()
        if !tabs.contains(where: { $0.value === tab }) {
            tabs.append(WeakTab(value: tab))
        }
        activeTab = tab
        tab.setWindow(self)
    }

    func detach(tab: SimpleExtensionTab) {
        cleanTabs()
        tabs.removeAll { $0.value === tab }
        if activeTab === tab {
            activeTab = tabs.first { $0.value != nil }?.value
        }
    }

    func updateWindowReference(_ window: NSWindow?) {
        nsWindow = window
    }

    func markActive(_ tab: SimpleExtensionTab) {
        attach(tab: tab)
        activeTab = tab
    }

    func currentTabs() -> [SimpleExtensionTab] {
        cleanTabs()
        return tabs.compactMap { $0.value }
    }

    func index(of tab: SimpleExtensionTab) -> Int {
        cleanTabs()
        for (idx, entry) in tabs.enumerated() where entry.value === tab {
            return idx
        }
        return NSNotFound
    }

    private func cleanTabs() {
        tabs.removeAll { $0.value == nil }
    }

    // MARK: - WKWebExtensionWindow

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        currentTabs().map { $0 as any WKWebExtensionTab }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        cleanTabs()
        return activeTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = nsWindow else { return .normal }
        if window.styleMask.contains(.fullScreen) { return .fullscreen }
        if window.isMiniaturized { return .minimized }
        if window.isZoomed { return .maximized }
        return .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        nsWindow?.screen?.frame ?? .null
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        nsWindow?.frame ?? .null
    }

    func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = nsWindow else {
            completionHandler(nil)
            return
        }
        window.setFrame(frame, display: true, animate: false)
        completionHandler(nil)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        nsWindow?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        guard let window = nsWindow else {
            completionHandler(nil)
            return
        }
        window.performClose(nil)
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
final class SimpleExtensionTab: NSObject, WKWebExtensionTab {
    private weak var webView: WKWebView?
    private weak var parentTab: WKWebExtensionTab?
    private weak var windowRef: SimpleExtensionWindow?
    private(set) var identifier: String
    private var committedURL: URL?
    private var pendingNavigationURL: URL?
    private var cachedTitle: String?
    private var isLoadingFlag = false

    init(webView: WKWebView, identifier: String) {
        self.webView = webView
        self.identifier = identifier
        super.init()
        syncFromWebView()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
        syncFromWebView()
    }

    public typealias TabProperties = WKWebExtension.TabChangedProperties

    @discardableResult
    func updatePendingNavigation(_ url: URL?) -> TabProperties {
        if pendingNavigationURL == url { return [] }
        pendingNavigationURL = url
        return [.url]
    }

    @discardableResult
    func commitNavigation(_ url: URL?) -> TabProperties {
        var changed: TabProperties = []
        if committedURL != url {
            committedURL = url
            changed.insert(.url)
        }
        committedURL = url
        if pendingNavigationURL == url {
            pendingNavigationURL = nil
        }
        return changed
    }

    @discardableResult
    func updateTitle(_ title: String?) -> TabProperties {
        if cachedTitle == title { return [] }
        cachedTitle = title
        return [.title]
    }

    @discardableResult
    func updateLoadingState(_ isLoading: Bool) -> TabProperties {
        if isLoadingFlag == isLoading { return [] }
        isLoadingFlag = isLoading
        return [.loading]
    }

    @discardableResult
    func clearPendingNavigation() -> TabProperties {
        guard pendingNavigationURL != nil else { return [] }
        pendingNavigationURL = nil
        return [.url]
    }

    func setWindow(_ window: SimpleExtensionWindow?) {
        windowRef = window
    }

    private func syncFromWebView() {
        committedURL = webView?.url
        cachedTitle = webView?.title
        isLoadingFlag = webView?.isLoading ?? false
        if isLoadingFlag {
            pendingNavigationURL = committedURL
        }
    }

    // MARK: - WKWebExtensionTab

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { windowRef }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let view = self?.webView else {
                completionHandler(nil)
                return
            }
            view.window?.makeKeyAndOrderFront(nil)
            completionHandler(nil)
        }
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { completionHandler(nil) }
    }

    func detectWebpageLocale(for context: WKWebExtensionContext, completionHandler: @escaping (Locale?, Error?) -> Void) {
        completionHandler(Locale.current, nil)
    }

    func duplicate(using configuration: WKWebExtension.TabConfiguration,
                   for context: WKWebExtensionContext,
                   completionHandler: @escaping (WKWebExtensionTab?, Error?) -> Void) {
        completionHandler(nil, nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.goBack()
            completionHandler(nil)
        }
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.goForward()
            completionHandler(nil)
        }
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        windowRef?.index(of: self) ?? NSNotFound
    }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !isLoadingFlag }
    func isMuted(for context: WKWebExtensionContext) -> Bool { false }
    func isPinned(for context: WKWebExtensionContext) -> Bool { false }
    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { false }
    func isReaderModeActive(for context: WKWebExtensionContext) -> Bool { false }
    func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool { false }
    func isSelected(for context: WKWebExtensionContext) -> Bool { true }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.load(URLRequest(url: url))
            completionHandler(nil)
        }
    }

    func parentTab(for context: WKWebExtensionContext) -> WKWebExtensionTab? { parentTab }
    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        pendingNavigationURL ?? committedURL ?? webView?.url
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if fromOrigin {
                self?.webView?.reloadFromOrigin()
            } else {
                self?.webView?.reload()
            }
            completionHandler(nil)
        }
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    func setParentTab(_ parentTab: WKWebExtensionTab?, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        self.parentTab = parentTab
        completionHandler(nil)
    }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    func setReaderModeActive(_ active: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.pageZoom = zoomFactor
            completionHandler(nil)
        }
    }

    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool { false }
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }
    func size(for context: WKWebExtensionContext) -> CGSize { webView?.frame.size ?? .zero }
    func title(for context: WKWebExtensionContext) -> String? { cachedTitle ?? webView?.title }
    func url(for context: WKWebExtensionContext) -> URL? { committedURL ?? webView?.url }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView?.pageZoom ?? 1.0) }
}
