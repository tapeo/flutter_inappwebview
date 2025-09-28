//
//  ExtensionWindow.swift
//  Pods
//
//  Created by Matteo Ricupero on 28/09/25.
//
import FlutterMacOS
import Foundation
@preconcurrency import WebKit
import UniformTypeIdentifiers

// Implementation of WKWebExtensionWindow protocol to represent a window to web extensions
@available(macOS 15.4, *)
public class ExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var windowController: NSWindowController?
    private var extensionTabs: [ExtensionTab] = []
    private weak var currentActiveTab: ExtensionTab?

    init(windowController: NSWindowController? = nil) {
        self.windowController = windowController
        super.init()
    }

    // MARK: - WKWebExtensionWindow Protocol Implementation

    public func tabs(for context: WKWebExtensionContext) -> [WKWebExtensionTab] {
        return extensionTabs
    }

    public func activeTab(for context: WKWebExtensionContext) -> WKWebExtensionTab? {
        return currentActiveTab
    }

    public func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        return .normal
    }

    public func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window = windowController?.window else { return .normal }

        if window.isKeyWindow && !window.isMiniaturized {
            return .normal
        } else if window.isMiniaturized {
            return .minimized
        } else if window.styleMask.contains(.fullScreen) {
            return .fullscreen
        } else {
            return .normal
        }
    }

    public func setWindowState(_ state: WKWebExtension.WindowState, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            guard let window = self.windowController?.window else {
                completionHandler(ExtensionError.installationFailed("No window available"))
                return
            }

            switch state {
            case .minimized:
                window.miniaturize(nil)
            case .maximized:
                window.zoom(nil)
            case .fullscreen:
                window.toggleFullScreen(nil)
            case .normal:
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                if window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            @unknown default:
                break
            }
            completionHandler(nil)
        }
    }

    public func isPrivate(for context: WKWebExtensionContext) -> Bool {
        return false // Not implementing private browsing mode
    }

    public func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        guard let window = windowController?.window,
              let screen = window.screen else {
            return NSScreen.main?.frame ?? CGRect.zero
        }
        return screen.frame
    }

    public func frame(for context: WKWebExtensionContext) -> CGRect {
        return windowController?.window?.frame ?? CGRect.zero
    }

    public func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            self.windowController?.window?.setFrame(frame, display: true)
            completionHandler(nil)
        }
    }

    public func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            self.windowController?.window?.makeKeyAndOrderFront(nil)
            completionHandler(nil)
        }
    }

    public func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            self.windowController?.window?.close()
            completionHandler(nil)
        }
    }

    // MARK: - Internal Management Methods

    func addTab(_ tab: ExtensionTab) {
        if !extensionTabs.contains(where: { $0.id == tab.id }) {
            extensionTabs.append(tab)
        }
    }

    func removeTab(_ tab: ExtensionTab) {
        extensionTabs.removeAll { $0.id == tab.id }
        if currentActiveTab?.id == tab.id {
            currentActiveTab = extensionTabs.first
        }
    }

    func setActiveTab(_ tab: ExtensionTab?) {
        currentActiveTab = tab
    }
}
