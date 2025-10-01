//
//  ExtensionTab.swift
//  flutter_inappwebview
//
//  Simplified tab wrapper for WKWebExtension integration.
//

import Foundation
@preconcurrency import WebKit

@available(macOS 15.4, *)
final class SimpleExtensionTab: NSObject, WKWebExtensionTab {
    private weak var webView: WKWebView?
    private weak var parentTab: WKWebExtensionTab?
    private(set) var identifier: String

    init(webView: WKWebView, identifier: String) {
        self.webView = webView
        self.identifier = identifier
        super.init()
    }

    func attach(webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - WKWebExtensionTab

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

    func indexInWindow(for context: WKWebExtensionContext) -> Int { 0 }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { webView?.isLoading == false }
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
    func pendingURL(for context: WKWebExtensionContext) -> URL? { webView?.url }

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
    func title(for context: WKWebExtensionContext) -> String? { webView?.title }
    func url(for context: WKWebExtensionContext) -> URL? { webView?.url }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { webView }
    func window(for context: WKWebExtensionContext) -> WKWebExtensionWindow? { nil }
    func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(webView?.pageZoom ?? 1.0) }
}
