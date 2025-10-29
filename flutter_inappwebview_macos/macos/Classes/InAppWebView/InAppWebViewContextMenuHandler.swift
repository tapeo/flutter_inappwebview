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
    
    init(webView: InAppWebView) {
        self.webView = webView
    }

    func shouldUseDefaultRightClickHandling(for webView: InAppWebView,
                                            with event: NSEvent) -> Bool {
        // Fetch and cache the image URL at click time
        let clickLocation = webView.convert(event.locationInWindow, from: nil)
        fetchImageUrlAtLocation(clickLocation, in: webView)
        
        guard event.modifierFlags.contains(.option) else {
            return true
        }

        webView.channelDelegate?.onRightClick(x: Double(clickLocation.x),
                                              y: Double(clickLocation.y))
        return false
    }

    func handleWillOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            // Intercept "Download Image" menu item
            interceptDownloadImageMenuItem(in: menu)
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
    
    @objc private func handleDownloadImage(_ sender: NSMenuItem) {
        guard let webView = webView,
              let imageUrl = cachedImageUrl,
              !imageUrl.isEmpty,
              let url = URL(string: imageUrl) else {
            return
        }
        
        startImageDownload(url: url, webView: webView)
    }
    
    private func fetchImageUrlAtLocation(_ location: NSPoint, in webView: InAppWebView) {
        cachedImageUrl = nil
        
        let viewHeight = webView.bounds.height
        let jsX = location.x
        let jsY = viewHeight - location.y
        
        let script = """
        (function() {
            var findFunc = window.findElementsAtPoint || (window.flutter_inappwebview && window.flutter_inappwebview._findElementsAtPoint);
            if (findFunc) {
                var result = findFunc(\(jsX), \(jsY));
                if (result && result.imageUrl) {
                    return result.imageUrl;
                }
            }
            // Fallback: try direct element lookup
            var element = document.elementFromPoint(\(jsX), \(jsY));
            while (element) {
                if (element.tagName === 'IMG' && element.src) {
                    return element.src;
                }
                element = element.parentElement;
                if (element && element.tagName === 'IMG' && element.src) {
                    return element.src;
                }
                break;
            }
            return null;
        })();
        """
        
        webView.evaluateJavaScript(script) { [weak self] result, error in
            if let imageUrl = result as? String, !imageUrl.isEmpty {
                self?.cachedImageUrl = imageUrl
            }
        }
    }
    
    private func startImageDownload(url: URL, webView: InAppWebView) {
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
