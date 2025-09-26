//
//  ExtensionPopup.swift
//  Pods
//
//  Created by Matteo Ricupero on 26/09/25.
//
import FlutterMacOS
import Foundation
@preconcurrency import WebKit
import UniformTypeIdentifiers

/// Manager class to handle extension popup windows and popovers
class ExtensionPopupWindowManager: NSObject, NSWindowDelegate, NSPopoverDelegate {
    static let shared = ExtensionPopupWindowManager()
    private var popupWindows = Set<NSWindow>()
    private var popupPopovers = Set<NSPopover>()
    private var extensionPopovers = [String: NSPopover]() // Track popovers by extension ID

    // Callback for when a popover closes, to notify ExtensionManager
    var onPopoverClosed: ((String) -> Void)?

    private override init() {
        super.init()
    }

    func addWindow(_ window: NSWindow) {
        popupWindows.insert(window)
    }

    func removeWindow(_ window: NSWindow) {
        popupWindows.remove(window)
    }

    func addPopover(_ popover: NSPopover) {
        popover.delegate = self
        popupPopovers.insert(popover)
    }

    func addPopover(_ popover: NSPopover, forExtension extensionId: String) {
        popover.delegate = self
        popupPopovers.insert(popover)
        extensionPopovers[extensionId] = popover
        print("📌 Tracking popover for extension: \(extensionId)")
    }

    func removePopover(_ popover: NSPopover) {
        popupPopovers.remove(popover)
        // Remove from extension tracking
        extensionPopovers = extensionPopovers.filter { $0.value !== popover }
    }

    func closeExistingPopoverForExtension(_ extensionId: String) {
        if let existingPopover = extensionPopovers[extensionId] {
            print("🗑️ Closing existing popover for extension: \(extensionId)")

            // Ensure complete cleanup
            if let contentViewController = existingPopover.contentViewController,
               let webView = contentViewController.view as? WKWebView {
                print("🧹 Cleaning up WebView in existing popover")
                webView.stopLoading()
                webView.loadHTMLString("", baseURL: nil) // Clear any existing content

                // FIXED: Don't remove user scripts and handlers as this can break extension functionality
                // The WebView should retain its extension-related configuration for proper reuse
                print("✅ WebView cleaned up while preserving extension configuration")
            }

            existingPopover.close()
            extensionPopovers.removeValue(forKey: extensionId)
            popupPopovers.remove(existingPopover)

            print("✅ Existing popover cleanup complete for extension: \(extensionId)")
        }
    }

    func getExtensionId(for popover: NSPopover) -> String? {
        return extensionPopovers.first { $0.value === popover }?.key
    }
    
    // NSWindowDelegate methods
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            removeWindow(window)
            print("🗑️ Extension popup window closed and removed from manager")
        }
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
    
    // NSPopoverDelegate methods
    func popoverDidClose(_ notification: Notification) {
        if let popover = notification.object as? NSPopover {
            // Find which extension this popover belongs to
            let extensionId = extensionPopovers.first { $0.value === popover }?.key
            if let extensionId = extensionId {
                print("🗑️ Extension popup popover for \(extensionId) closed and removed from manager")
                extensionPopovers.removeValue(forKey: extensionId)

                // Notify ExtensionManager to clean up state
                onPopoverClosed?(extensionId)
            }
            removePopover(popover)
        }
    }
}

enum ExtensionError: LocalizedError {
    case unsupportedOS
    case invalidManifest(String)
    case installationFailed(String)
    case permissionDenied
    case timeout(String)
    
    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            return "Extensions require iOS 18.5+ or macOS 15.5+"
        case .invalidManifest(let reason):
            return "Invalid manifest.json: \(reason)"
        case .installationFailed(let reason):
            return "Installation failed: \(reason)"
        case .permissionDenied:
            return "Permission denied"
        case .timeout(let reason):
            return reason
        }
    }
}

