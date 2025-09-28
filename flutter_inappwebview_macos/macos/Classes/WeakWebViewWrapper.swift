//
//  WeakWebViewWrapper.swift
//  Pods
//
//  Created by Matteo Ricupero on 28/09/25.
//
import FlutterMacOS
import Foundation
@preconcurrency import WebKit
import UniformTypeIdentifiers

// Weak wrapper to track WebViews without creating strong references
public class WeakWebViewWrapper: NSObject {
    weak var webView: WKWebView?
    let id: String
    var currentURL: URL? // Track current URL for better tab matching
    var extensionTab: ExtensionTab?

    init(webView: WKWebView, id: String, window: ExtensionWindow? = nil) {
        self.webView = webView
        self.id = id
        super.init()
        // Observe URL changes for dynamic tracking
        webView.addObserver(self, forKeyPath: "URL", options: [.new], context: nil)

        // Create extension tab representation if available
        if #available(macOS 15.4, *) {
            self.extensionTab = ExtensionTab(webView: webView, id: id, window: window)
        }
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "URL", let url = change?[.newKey] as? URL {
            currentURL = url
            extensionTab?.currentURL = url
            print("🔄 URL updated for WebView \(id): \(url.absoluteString)") // Optional: Log for debugging
        }
    }

    deinit {
        if let webView = webView {
            webView.removeObserver(self, forKeyPath: "URL")
        }
    }
}
