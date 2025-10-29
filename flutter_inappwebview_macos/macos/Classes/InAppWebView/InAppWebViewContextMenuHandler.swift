//
//  InAppWebViewContextMenuHandler.swift
//  flutter_inappwebview
//
//  Created by Codex on 18/03/25.
//

import AppKit

final class InAppWebViewContextMenuHandler {

    func shouldUseDefaultRightClickHandling(for webView: InAppWebView,
                                            with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option) else {
            return true
        }

        let clickLocation = webView.convert(event.locationInWindow, from: nil)
        webView.channelDelegate?.onRightClick(x: Double(clickLocation.x),
                                              y: Double(clickLocation.y))
        return false
    }

    func handleWillOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            return
        }

        menu.removeAllItems()
        menu.cancelTracking()
    }
}
