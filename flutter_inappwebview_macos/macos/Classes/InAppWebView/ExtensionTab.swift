//
//  ExtensionTab.swift
//  Pods
//
//  Created by Matteo Ricupero on 28/09/25.
//
import FlutterMacOS
import Foundation
@preconcurrency import WebKit
import UniformTypeIdentifiers

// Implementation of WKWebExtensionTab protocol to represent a tab to web extensions
@available(macOS 15.4, *)
public class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var webView: WKWebView?
    let id: String
    var currentURL: URL?
    weak var parentTabRef: WKWebExtensionTab?
    weak var extensionWindow: ExtensionWindow?

    init(webView: WKWebView, id: String, window: ExtensionWindow? = nil) {
        self.webView = webView
        self.id = id
        self.currentURL = webView.url
        self.extensionWindow = window
        super.init()

        // Observe URL changes for dynamic tracking
        webView.addObserver(self, forKeyPath: "URL", options: [.new], context: nil)

        // Add this tab to the window if provided
        if let window = window {
            window.addTab(self)
        }
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "URL", let url = change?[.newKey] as? URL {
            currentURL = url
        }
    }

    deinit {
        if let webView = webView {
            webView.removeObserver(self, forKeyPath: "URL")
        }
    }

    // MARK: - WKWebExtensionTab Protocol Implementation

    public func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            // Bring the tab to front - this would typically involve UI operations
            completionHandler(nil)
        }
    }

    public func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            // Close the tab - this would typically involve removing from UI
            completionHandler(nil)
        }
    }

    public func detectWebpageLocale(for context: WKWebExtensionContext, completionHandler: @escaping (Locale?, Error?) -> Void) {
        DispatchQueue.main.async {
            // Return system locale as fallback
            completionHandler(Locale.current, nil)
        }
    }

    public func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping (WKWebExtensionTab?, Error?) -> Void) {
        DispatchQueue.main.async {
            // Tab duplication not implemented
            completionHandler(nil, ExtensionError.installationFailed("Tab duplication not implemented"))
        }
    }

    public func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            self.webView?.goBack()
            completionHandler(nil)
        }
    }

    public func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            self.webView?.goForward()
            completionHandler(nil)
        }
    }

    public func indexInWindow(for context: WKWebExtensionContext) -> Int {
        return 0 // Default index for single tab
    }

    public func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        return webView?.isLoading == false
    }

    public func isMuted(for context: WKWebExtensionContext) -> Bool {
        return false // Audio muting not implemented
    }

    public func isPinned(for context: WKWebExtensionContext) -> Bool {
        return false // Tab pinning not implemented
    }

    public func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        return false // Audio detection not implemented
    }

    public func isReaderModeActive(for context: WKWebExtensionContext) -> Bool {
        return false // Reader mode not implemented
    }

    public func isReaderModeAvailable(for context: WKWebExtensionContext) -> Bool {
        return false // Reader mode not implemented
    }

    public func isSelected(for context: WKWebExtensionContext) -> Bool {
        return true // Assume tab is selected for simplicity
    }

    public func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            self.webView?.load(URLRequest(url: url))
            completionHandler(nil)
        }
    }

    public func parentTab(for context: WKWebExtensionContext) -> WKWebExtensionTab? {
        return parentTabRef
    }

    public func pendingURL(for context: WKWebExtensionContext) -> URL? {
        return currentURL
    }

    public func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            if fromOrigin {
                self.webView?.reloadFromOrigin()
            } else {
                self.webView?.reload()
            }
            completionHandler(nil)
        }
    }

    public func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            // Audio muting not implemented
            completionHandler(nil)
        }
    }

    public func setParentTab(_ parentTab: WKWebExtensionTab?, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            self.parentTabRef = parentTab
            completionHandler(nil)
        }
    }

    public func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            // Tab pinning not implemented
            completionHandler(nil)
        }
    }

    public func setReaderModeActive(_ active: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            // Reader mode not implemented
            completionHandler(nil)
        }
    }

    public func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            // Tab selection handling would be implemented here
            completionHandler(nil)
        }
    }

    public func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            self.webView?.pageZoom = zoomFactor
            completionHandler(nil)
        }
    }

    public func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool {
        return false // Use standard permission checks
    }

    public func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        return true // Allow permission grants on user gesture
    }

    public func size(for context: WKWebExtensionContext) -> CGSize {
        return webView?.frame.size ?? CGSize.zero
    }

    public func title(for context: WKWebExtensionContext) -> String? {
        return webView?.title
    }

    public func url(for context: WKWebExtensionContext) -> URL? {
        return currentURL ?? webView?.url
    }

    public func webView(for context: WKWebExtensionContext) -> WKWebView? {
        return webView
    }

    public func window(for context: WKWebExtensionContext) -> WKWebExtensionWindow? {
        return extensionWindow
    }

    public func zoomFactor(for context: WKWebExtensionContext) -> Double {
        return Double(webView?.pageZoom ?? 1.0)
    }
}
