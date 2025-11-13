//
//  InAppWebViewContextMenuHandler.swift
//  flutter_inappwebview
//
//  Created by Codex on 18/03/25.
//

import AppKit
@preconcurrency import WebKit

final class InAppWebViewContextMenuHandler {
    private weak var webView: InAppWebView?
    private var cachedImageUrl: String?
    private var cachedLinkUrl: String?
    
    init(webView: InAppWebView) {
        self.webView = webView
    }

    func shouldUseDefaultRightClickHandling(for webView: InAppWebView,
                                            with event: NSEvent) -> Bool {
        let clickLocation = webView.convert(event.locationInWindow, from: nil)
        fetchContextUrlsAtLocation(clickLocation, in: webView)
        
        guard event.modifierFlags.contains(.option) else {
            return true
        }

        webView.channelDelegate?.onRightClick(x: Double(clickLocation.x),
                                              y: Double(clickLocation.y))
        return false
    }

    func handleWillOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            interceptDownloadImageMenuItem(in: menu)
            interceptDownloadLinkedFileMenuItem(in: menu)
            return
        }

        menu.removeAllItems()
        menu.cancelTracking()
    }
    
    private func interceptDownloadImageMenuItem(in menu: NSMenu) {
        for item in menu.items {
            // Check if this is the Download Image menu item by title
            let title = item.title.lowercased()
            if title.contains("download") && title.contains("image") {
                item.target = self
                item.action = #selector(handleDownloadImage(_:))
            }
            
            // Also check by identifier if available
            if #available(macOS 10.12.2, *) {
                if let identifier = item.identifier?.rawValue,
                   identifier.contains("Download") && identifier.contains("Image") {
                    item.target = self
                    item.action = #selector(handleDownloadImage(_:))
                }
            }
            
            // Check submenu items recursively
            if let submenu = item.submenu {
                interceptDownloadImageMenuItem(in: submenu)
            }
        }
    }
    
    private func interceptDownloadLinkedFileMenuItem(in menu: NSMenu) {
        for item in menu.items {
            let title = item.title.lowercased()
            if title.contains("download") && (title.contains("linked") || title.contains("link")) {
                item.target = self
                item.action = #selector(handleDownloadLinkedFile(_:))
            }
            if #available(macOS 10.12.2, *) {
                if let identifier = item.identifier?.rawValue,
                   identifier.contains("Download"),
                   identifier.contains("Linked") || identifier.contains("Link") {
                    item.target = self
                    item.action = #selector(handleDownloadLinkedFile(_:))
                }
            }
            if let submenu = item.submenu {
                interceptDownloadLinkedFileMenuItem(in: submenu)
            }
        }
    }
    
    @objc private func handleDownloadImage(_ sender: NSMenuItem) {
        guard let webView = webView,
              let imageUrl = cachedImageUrl,
              !imageUrl.isEmpty,
              let url = URL(string: imageUrl) else {
            return
        }
        startDownload(url: url, webView: webView)
    }
    
    @objc private func handleDownloadLinkedFile(_ sender: NSMenuItem) {
        guard let webView = webView,
              let linkUrl = cachedLinkUrl,
              !linkUrl.isEmpty,
              let url = URL(string: linkUrl) else {
            return
        }
        startDownload(url: url, webView: webView)
    }
    
    private func fetchContextUrlsAtLocation(_ location: NSPoint, in webView: InAppWebView) {
        cachedImageUrl = nil
        cachedLinkUrl = nil
        
        let viewHeight = webView.bounds.height
        let jsX = location.x
        let jsY = viewHeight - location.y
        
        let script = """
        (function() {
            var findFunc = window.findElementsAtPoint || (window.flutter_inappwebview && window.flutter_inappwebview._findElementsAtPoint);
            var urls = { image: null, link: null };
            if (findFunc) {
                var result = findFunc(\(jsX), \(jsY));
                if (result) {
                    if (result.imageUrl) urls.image = result.imageUrl;
                    if (result.linkUrl) urls.link = result.linkUrl;
                }
            }
            if (!urls.image || !urls.link) {
                var element = document.elementFromPoint(\(jsX), \(jsY));
                var el = element;
                while (el) {
                    if (!urls.image && el.tagName === 'IMG' && el.src) {
                        urls.image = el.src;
                    }
                    if (!urls.link && el.closest) {
                        var a = el.closest('a[href]');
                        if (a && a.href) {
                            urls.link = a.href;
                        }
                    }
                    if (urls.image && urls.link) break;
                    el = el.parentElement;
                }
            }
            return urls;
        })();
        """
        
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let dict = result as? [String: Any] {
                if let img = dict["image"] as? String, !img.isEmpty {
                    self?.cachedImageUrl = img
                }
                if let link = dict["link"] as? String, !link.isEmpty {
                    self?.cachedLinkUrl = link
                }
            }
        }
    }
    
    private func startDownload(url: URL, webView: InAppWebView) {
        var request = URLRequest(url: url)
        
        if let userAgent = webView.customUserAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        
        if #available(macOS 11.3, *) {
            webView.startDownload(using: request) { download in
                download.delegate = webView.downloadManager
            }
        }
    }
}
