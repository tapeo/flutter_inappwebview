//
//  InAppWebView.swift
//  flutter_inappwebview
//
//  Created by Lorenzo on 21/10/18.
//

import FlutterMacOS
import Foundation
@preconcurrency import WebKit
import UniformTypeIdentifiers

public class ExtensionManager: NSObject, ObservableObject, WKWebExtensionControllerDelegate, NSPopoverDelegate {

    // Shared instance for app-wide access
    public static let shared = ExtensionManager()

    // Static shared state for global extension preparation
    private static var globalExtensionController: WKWebExtensionController?
    private static var globalExtensionContexts: [WKWebExtensionContext] = []
    private static var isGloballyPrepared = false

    public var extensionContext: WKWebExtensionContext?
    public var extensionController: WKWebExtensionController?

    // Instance state (uses global state when available)
    private var isPrepared = false

    // Track active WebViews for tab support - now with URL tracking
    private var activeWebViews: [WeakWebViewWrapper] = []
    
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
    
    // Callback to be called when initialization completes
    public typealias InitializationCallback = (Bool) -> Void
    private var initializationCallback: InitializationCallback?
    
    // Track initialization state
    public private(set) var isInitialized = false
    
    // Action anchor views for popup positioning (similar to Nook)
    private var actionAnchors: [String: NSView] = [:]

    // Track whether delegate was called for each extension
    private var delegateCallTracker: [String: Bool] = [:]

    public func openExtensionPopup(for extensionId: String) -> Bool {
        guard let controller = extensionController else {
            print("❌ Extension controller not available")
            return false
        }

        // Ensure any existing popover is closed before attempting to open a new one
        ExtensionPopupWindowManager.shared.closeExistingPopoverForExtension(extensionId)

        // Find the specific extension context by ID
        guard let targetContext = Self.globalExtensionContexts.first(where: { $0.uniqueIdentifier == extensionId }) else {
            print("❌ Extension context not found for ID: \(extensionId)")
            return false
        }

        print("🎯 Opening extension popup for: \(extensionId)")
        print("   Extension name: \(targetContext.webExtension.displayName ?? "Unknown")")

        // Reset delegate call tracker for this extension
        delegateCallTracker[extensionId] = false
        print("   🔄 Reset delegate tracker for extension: \(extensionId)")

        // IMPROVED: Use a more reliable approach to trigger the popup
        Task { @MainActor in
            // Find the most appropriate tab for this context
            var suitableTab: WKWebExtensionTab? = nil
            if #available(macOS 15.4, *) {
                suitableTab = findSuitableTab(for: targetContext, controller: controller)
            }

            // Perform the action immediately without artificial delays
            if let tab = suitableTab {
                targetContext.performAction(for: tab)
                print("✅ Extension action performed with matched tab")
            } else {
                print("ℹ️ No suitable tabs available for context, performing action without tab context")
                targetContext.performAction(for: nil)
                print("✅ Extension action performed without tab context")
            }

            // BACKUP APPROACH: If delegate isn't called within 150ms, create popup directly
            try? await Task.sleep(nanoseconds: 150_000_000) // 150ms timeout (increased from 100ms)

            if delegateCallTracker[extensionId] == false {
                print("⚠️ Delegate not called within timeout - creating popup directly")
                await createPopupDirectly(for: targetContext, extensionId: extensionId, tab: suitableTab)
            } else {
                print("✅ Delegate was called successfully - popup should be displayed")
            }
        }

        return true
    }

    /// Create popup directly when WebKit delegate is not called
    @MainActor
    private func createPopupDirectly(for context: WKWebExtensionContext, extensionId: String, tab: WKWebExtensionTab?) async {
        print("🛠️ Creating popup directly for extension: \(extensionId)")

        // Get the extension's action and check for existing popup WebView
        guard let action = context.action(for: tab) else {
            print("   ❌ Could not get extension action for direct creation")
            return
        }

        let webView: WKWebView
        let popupURL: URL

        // Prefer using the action's existing popupWebView if available
        if let existingPopupWebView = action.popupWebView,
           let existingURL = existingPopupWebView.url {
            webView = existingPopupWebView
            popupURL = existingURL
            print("   📱 Using existing action popup WebView with URL: \(popupURL.absoluteString)")
        } else if let fallbackURL = getPopupURL(for: context) {
            // Fallback: create a new WebView
            webView = WKWebView()
            webView.configuration.webExtensionController = self.extensionController
            webView.isInspectable = true
            popupURL = fallbackURL
            print("   📱 Creating new popup WebView with URL: \(popupURL.absoluteString)")

            // Load the popup URL for new WebView
            webView.load(URLRequest(url: popupURL))
        } else {
            print("   ❌ Could not determine popup URL for direct creation")
            return
        }

        // Create and show the popover
        await showPopoverWithWebView(webView, for: extensionId)
    }

    /// Get popup URL for an extension context
    private func getPopupURL(for context: WKWebExtensionContext) -> URL? {
        // Try to get popup URL from the extension's action
        if let action = context.action(for: nil),
           let popupWebView = action.popupWebView,
           let url = popupWebView.url {
            return url
        }

        // Fallback: construct popup URL from base URL
        let baseURL = context.baseURL
        let popupURL = baseURL.appendingPathComponent("popup.html")
        print("   🔧 Constructed popup URL: \(popupURL.absoluteString)")
        return popupURL
    }

    /// Show popover with given WebView
    @MainActor
    private func showPopoverWithWebView(_ webView: WKWebView, for extensionId: String) async {
        print("   🎯 Showing popover for extension: \(extensionId)")

        // Create popover with transient behavior
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 600)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        // Create view controller
        let viewController = NSViewController()
        webView.removeFromSuperview()
        viewController.view = webView
        popover.contentViewController = viewController

        // Find anchor view
        var anchorView: NSView?
        var anchorRect: NSRect

        if let registeredAnchor = self.actionAnchors[extensionId] {
            anchorView = registeredAnchor
            anchorRect = registeredAnchor.bounds
            print("   📍 Using registered anchor for extension: \(extensionId)")
        } else if let mainWindow = NSApplication.shared.mainWindow,
                  let contentView = mainWindow.contentView {
            anchorView = contentView
            anchorRect = NSRect(
                x: contentView.bounds.midX,
                y: contentView.bounds.midY,
                width: 1,
                height: 1
            )
            print("   📍 Using fallback center anchor")
        } else {
            print("   ❌ No suitable anchor view available")
            return
        }

        guard let finalAnchorView = anchorView else {
            print("   ❌ No anchor view available")
            return
        }

        // Show the popover
        popover.show(relativeTo: anchorRect, of: finalAnchorView, preferredEdge: .minY)
        ExtensionPopupWindowManager.shared.addPopover(popover, forExtension: extensionId)

        print("   ✅ Direct popup displayed successfully")
    }
    
    /// Find a suitable tab for the target context by matching with active WebViews
    /// Prioritizes: exact URL match, then any available registered tab
    @available(macOS 15.4, *)  // Ensure API availability
    public func findSuitableTab(for context: WKWebExtensionContext, controller: WKWebExtensionController) -> WKWebExtensionTab? {
        // Clean up any deallocated WebViews
        self.activeWebViews.removeAll { $0.webView == nil }

        print("🔍 Searching for suitable tab in context: \(context.uniqueIdentifier)")
        print("   Available active WebViews: \(activeWebViews.count)")
        print("   Available open tabs in context: \(context.openTabs.count)")

        // First, try to find a tab from our active WebViews
        for wrapper in activeWebViews {
            if let extensionTab = wrapper.extensionTab {
                print("   ✅ Using ExtensionTab from active WebViews: \(wrapper.id)")
                return extensionTab
            }
        }

        // Fallback: check context's open tabs
        let castedTabs: [WKWebExtensionTab] = context.openTabs.compactMap { $0 as? WKWebExtensionTab }
        print("   Available context tabs (casted): \(castedTabs.count)")

        if let firstTab = castedTabs.first {
            print("   ✅ Using first available context tab")
            return firstTab
        }

        print("   ❌ No suitable tabs found in context or registry")
        return nil
    }
    
    public func activateExtensionsOnWebView(_ webView: WKWebView) {
        guard let controller = Self.globalExtensionController else {
            print("❌ No controller to activate extensions")
            return
        }
        webView.configuration.webExtensionController = controller
        print("🔄 Activated extensions on WebView (contexts: \(controller.extensionContexts.count))")
        // Reload to trigger injection if already loaded
        if let currentURL = webView.url {
            webView.reloadFromOrigin() // Or webView.load(URLRequest(url: currentURL))
        }
    }
    
    private var extensionWindow: ExtensionWindow?

    /// Register a WebView as an active tab for extension support - enhanced to sync with extension tabs
    public func registerWebView(_ webView: WKWebView, id: String) {
        print("📝 Registering WebView as active tab: \(id)")

        // Check if extension system is prepared, and try to load global state if available
        if !isPrepared || extensionController == nil {
            // Try to load from global state if available
            if Self.isGloballyPrepared, let globalController = Self.globalExtensionController {
                print("🔄 Loading globally prepared extensions into instance")
                extensionController = globalController
                extensionContext = Self.globalExtensionContexts.first
                isPrepared = true
                isInitialized = true
            } else {
                print("⚠️ Extension system not prepared yet - registering WebView but skipping extension integration")

                // Still register the WebView for basic tracking
                activeWebViews.removeAll { $0.webView == nil }
                if !activeWebViews.contains(where: { $0.id == id }) {
                    let wrapper = WeakWebViewWrapper(webView: webView, id: id, window: nil)
                    activeWebViews.append(wrapper)
                    print("✅ WebView registered (without extension integration). Total active tabs: \(activeWebViews.count)")
                }
                return
            }
        }

        // Clean up any deallocated WebViews first
        activeWebViews.removeAll { $0.webView == nil }

        // Create or get the extension window
        if extensionWindow == nil {
            if #available(macOS 15.4, *) {
                extensionWindow = ExtensionWindow()
                print("✅ Created ExtensionWindow instance")
            }
        }

        // Add new WebView if not already registered
        if !activeWebViews.contains(where: { $0.id == id }) {
            let wrapper = WeakWebViewWrapper(webView: webView, id: id, window: extensionWindow)
            activeWebViews.append(wrapper)
            print("✅ WebView registered. Total active tabs: \(activeWebViews.count)")
        } else {
            // Update existing wrapper's URL if already registered
            if let existing = activeWebViews.first(where: { $0.id == id }) {
                existing.currentURL = webView.url
            }
        }
        
        // Ensure the WebView is configured with the extension controller
        // This allows WebKit to automatically discover it as a tab
        if let controller = extensionController {
            
            webView.configuration.webExtensionController = controller

            print("✅ Configured WebView \(id) with extension controller")

            // Get the extension tab from the wrapper
            if let tabWrapper = activeWebViews.first(where: { $0.id == id }),
               let extensionTab = tabWrapper.extensionTab,
               let context = extensionContext,
               let window = extensionWindow {

                print("📋 Using proper ExtensionTab implementation for \(id)")

                extensionWindow?.addTab(extensionTab)

                // Update the extension tab's window reference
                extensionTab.extensionWindow = extensionWindow
                if let extWindow = extensionWindow {
                    extWindow.setActiveTab(extensionTab)
                }

                let wkTab = extensionTab as WKWebExtensionTab
                print("extensionWindow \(extensionWindow)")
                
                let activated = extensionWindow?.activeTab(for: context)
                print("win active: \(activated)")
            } else {
                print("⚠️ Could not find extension tab wrapper for \(id)")
            }
        }


        // let hasURLAccess = extensionContext?.hasAccess(to: URL(string: "https://google.com")!) ?? false
        // print("Has URL access: \(hasURLAccess)")
       
        
        // print("📋 Extension tab created and WebView configured for discovery")
        // self.activateExtensionsOnWebView(webView)
        // print("\n--- Status for Context: \(extensionContext?.uniqueIdentifier) ---")
        // extensionContext?.printStatusInfo()
        
        self.loadExtension()
    }
    
    /// Unregister a WebView when it's disposed
    public func unregisterWebView(id: String) {
        print("🗑️ Unregistering WebView: \(id)")
        activeWebViews.removeAll { $0.id == id }

        print("✅ WebView unregistered. Total active tabs: \(activeWebViews.count)")
    }
    
    /// Static method to prepare extension system at app startup
    /// Call this once when the app starts, before creating any WebViews
    /// Returns true if preparation was successful, false otherwise
    @MainActor
    public static func prepareExtensionSystem() async -> Bool {
        print("🚀 Preparing extension system...")
        
        guard !isGloballyPrepared else {
            print("✅ Extension system already prepared")
            return true
        }
        
        do {
            // Create controller configuration
            let config: WKWebExtensionController.Configuration
            if let idString = UserDefaults.standard.string(forKey: "Pola.WKWebExtensionController.Identifier"),
               let uuid = UUID(uuidString: idString) {
                config = WKWebExtensionController.Configuration(identifier: uuid)
            } else {
                let uuid = UUID()
                UserDefaults.standard.set(uuid.uuidString, forKey: "Pola.WKWebExtensionController.Identifier")
                config = WKWebExtensionController.Configuration(identifier: uuid)
            }
            
            // Create shared controller
            globalExtensionController = WKWebExtensionController(configuration: config)
            globalExtensionContexts = []
            
            // Try to load from bundled resources first
            var extensionsLoaded = 0
            
            // Load ZIP extensions from a specific app folder (e.g., in Documents)
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let extensionsURL = documentsURL.appendingPathComponent("Extensions")

            print("🔍 Extensions folder path: \(extensionsURL.path)")

            // Create the Extensions directory if it doesn't exist
            do {
                try FileManager.default.createDirectory(at: extensionsURL, withIntermediateDirectories: true, attributes: nil)
                print("📁 Created Extensions directory")
            } catch {
                print("⚠️ Could not create Extensions directory: \(error)")
                // If creation fails, it might already exist, so proceed
            }

            // Now check if the directory exists and is accessible
            do {
                let resourceValues = try extensionsURL.resourceValues(forKeys: [.isDirectoryKey])
                
                print("🔍 Extensions path confirmed to be a directory")
                
                do {
                    // Read contents (use .skipsHiddenFiles if you want to ignore hidden files)
                    let contents = try FileManager.default.contentsOfDirectory(at: extensionsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                    print("🔍 Found \(contents.count) items in Extensions directory:")
                    for item in contents {
                        print("   - \(item.lastPathComponent)")
                    }
                    let zipFiles = contents.filter { $0.pathExtension.lowercased() == "zip" }
                    
                    for zipFile in zipFiles {
                        print("📦 Found extension: \(zipFile.lastPathComponent)")
                        do {
                            let context = try await installBundledExtension(from: zipFile)
                            globalExtensionContexts.append(context)
                            extensionsLoaded += 1
                            print("✅ Extension '\(zipFile.lastPathComponent)' loaded and ready")
                        } catch {
                            print("⚠️ Failed to load extension '\(zipFile.lastPathComponent)': \(error)")
                            continue
                        }
                    }
                    
                    if zipFiles.isEmpty {
                        print("📦 No ZIP extensions found in \(extensionsURL.path)")
                        print("💡 Tip: Place your ZIP extension files in ~/Documents/Extensions/ to load them.")
                    }
                } catch {
                    // More detailed error logging
                    let nsError = error as NSError
                    print("📦 Could not read Extensions directory \(extensionsURL.path):")
                    print("   - Code: \(nsError.code)")
                    print("   - Domain: \(nsError.domain)")
                    print("   - Description: \(nsError.localizedDescription)")
                    print("   - Reason: \(nsError.localizedFailureReason ?? "None")")
                }
            } catch {
                print("❌ Could not check if Extensions is a directory: \(error)")
            }
            
            // Fallback to downloading uBlock Origin Lite if no bundled extensions loaded
            // if extensionsLoaded == 0 {
            //     print("📥 Downloading fresh uBlock Origin Lite...")
            //     let url = URL(string: "https://github.com/uBlockOrigin/uBOL-home/releases/download/2025.921.2008/uBOLite_2025.921.2008.safari.zip")!
            //     let context = try await installExtensionWithReturn(from: url)
            //     sharedExtensionContexts.append(context)
            //     extensionsLoaded += 1
            //     print("✅ Fresh extension downloaded and ready")
            // }
            
            if extensionsLoaded > 0 {
                isGloballyPrepared = true
                print("🎉 Extension system preparation complete! Loaded \(extensionsLoaded) extension(s)")
                return true
            } else {
                print("❌ Failed to load any extension")
                return false
            }
            
        } catch {
            print("❌ Extension system preparation failed: \(error)")
            return false
        }
    }
    
    /// Private helper to grant permissions
    @MainActor
    private static func grantPermissionsToContext(_ context: WKWebExtensionContext, webExtension: WKWebExtension) async {
        // Grant common permissions
        for permission in Self.commonPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        
        // Grant host permissions
        for matchPattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: matchPattern)
        }
    }
    
    /// Private helper to wait for extension loading and rules activation
    @MainActor
    private static func waitForExtensionToLoad(_ context: WKWebExtensionContext) async {
        // First wait for basic loading
        var attempts = 0
        while !context.isLoaded && attempts < 50 {
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            attempts += 1
        }
        
        // Then wait additional time for declarativeNetRequest rules to become active
        // This is crucial for uBlock Origin Lite which relies heavily on declarativeNetRequest
        if context.isLoaded {
            print("📋 Extension loaded, waiting for declarativeNetRequest rules to activate...")
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds for rules to be fully active
            print("✅ Extension rules should now be active")
            print(context.uniqueIdentifier)
        }
        
        // Log information about all loaded extensions
        for (index, context) in globalExtensionContexts.enumerated() {
            print("Extension \(index + 1): \(context.webExtension.displayName ?? "Unknown")")
            print("  ID: \(context.uniqueIdentifier)")
            print("  Options URL: \(context.optionsPageURL?.absoluteString ?? "None")")
            print("  Loaded: \(context.isLoaded)")
        }
    }
    
    /// Private helper to install bundled extensions with proper structure
    @MainActor
    private static func installBundledExtension(from url: URL) async throws -> WKWebExtensionContext {
        let extensionsDir = Self.getExtensionsDirectory()
        try FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        
        // Create extension-specific directory based on the ZIP file name
        let zipFileName = url.deletingPathExtension().lastPathComponent
        let extensionDir = extensionsDir.appendingPathComponent(zipFileName)
        
        // Remove existing extension directory if it exists
        if FileManager.default.fileExists(atPath: extensionDir.path) {
            print("🗑️ Removing existing extension directory: \(extensionDir.path)")
            try FileManager.default.removeItem(at: extensionDir)
        }
        
        print("📦 Installing bundled extension '\(zipFileName)' to: \(extensionDir.path)")
        
        // Extract with proper structure
        try Self.extractZipWithProperStructure(from: url, to: extensionDir, extensionName: zipFileName)
        
        // Validate manifest exists and is valid
        let manifestURL = extensionDir.appendingPathComponent("manifest.json")
        let manifest = try ExtensionUtils.validateManifest(at: manifestURL)
        print("✅ Validated manifest for extension: \(manifest["name"] as? String ?? "Unknown")")
        
        // Load extension
        let webExtension = try await WKWebExtension(resourceBaseURL: extensionDir)
        let extensionContext = WKWebExtensionContext(for: webExtension)

        // Grant permissions
        await grantPermissionsToContext(extensionContext, webExtension: webExtension)

        // Load into shared controller
        // try globalExtensionController?.load(extensionContext)
        
        print("🎉 Bundled extension '\(zipFileName)' successfully installed and configured")
        return extensionContext
    }
    
    /// Private helper to install extension from URL
    @MainActor
    private static func installExtension(from url: URL) async throws {
        let extensionsDir = Self.getExtensionsDirectory()
        try FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        
        // Create unique directory name based on ZIP file name + UUID
        let zipFileName = url.deletingPathExtension().lastPathComponent
        let extensionId = "\(zipFileName)_\(ExtensionUtils.generateExtensionId())"
        let destinationDir = extensionsDir.appendingPathComponent(extensionId)
        
        print("📦 Installing extension to: \(destinationDir.path)")
        
        // Handle local files vs downloads
        let sourceURL: URL
        if url.scheme == "http" || url.scheme == "https" {
            // Download and extract
            let (downloadedURL, _) = try await URLSession.shared.download(from: url)
            sourceURL = downloadedURL
        } else {
            // Use local file directly
            sourceURL = url
        }

        try Self.extractZipWithProperStructure(from: sourceURL, to: destinationDir, extensionName: zipFileName)

        // Validate manifest
        let manifestURL = destinationDir.appendingPathComponent("manifest.json")
        _ = try ExtensionUtils.validateManifest(at: manifestURL)

        // Load extension
        let webExtension = try await WKWebExtension(resourceBaseURL: destinationDir)
        let extensionContext = WKWebExtensionContext(for: webExtension)
        globalExtensionContexts = [extensionContext] // Replace existing for backwards compatibility

        // Grant permissions
        await Self.grantPermissionsToContext(extensionContext, webExtension: webExtension)
    }
    
    /// Private helper to install extension from URL with return value
    @MainActor
    private static func installExtensionWithReturn(from url: URL) async throws -> WKWebExtensionContext {
        let extensionsDir = Self.getExtensionsDirectory()
        try FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        
        // Create unique directory name based on ZIP file name + UUID
        let zipFileName = url.deletingPathExtension().lastPathComponent
        let extensionId = "\(zipFileName)_\(ExtensionUtils.generateExtensionId())"
        let destinationDir = extensionsDir.appendingPathComponent(extensionId)
        
        print("📦 Installing extension to: \(destinationDir.path)")
        
        // Handle local files vs downloads
        let sourceURL: URL
        if url.scheme == "http" || url.scheme == "https" {
            // Download and extract
            let (downloadedURL, _) = try await URLSession.shared.download(from: url)
            sourceURL = downloadedURL
        } else {
            // Use local file directly
            sourceURL = url
        }
        
        try Self.extractZipWithProperStructure(from: sourceURL, to: destinationDir, extensionName: zipFileName)

        // Validate manifest
        let manifestURL = destinationDir.appendingPathComponent("manifest.json")
        _ = try ExtensionUtils.validateManifest(at: manifestURL)

        // Load extension
        let webExtension = try await WKWebExtension(resourceBaseURL: destinationDir)
        let extensionContext = WKWebExtensionContext(for: webExtension)

        // Grant permissions
        await grantPermissionsToContext(extensionContext, webExtension: webExtension)

        // Load into shared controller
        // try globalExtensionController?.load(extensionContext)
        
        return extensionContext
    }
    
    override public init() {
        super.init()

        print("initilization!!!")

        // Set up popup cleanup callback
        ExtensionPopupWindowManager.shared.onPopoverClosed = { [weak self] extensionId in
                print("dismiss popup")
        }

        // Use globally prepared extension components if available
        if Self.isGloballyPrepared,
           let globalController = Self.globalExtensionController,
           !Self.globalExtensionContexts.isEmpty {

            print("🔌 Using globally prepared extension components (\(Self.globalExtensionContexts.count) extension(s))")
            extensionController = globalController
            // Use the first extension context for backwards compatibility
            extensionContext = Self.globalExtensionContexts.first
            isPrepared = true
            isInitialized = true
            
            globalController.delegate = self
            extensionController!.delegate = self
        } else {
            print("⚠️ Extension system not prepared! Call prepareExtensionSystem() first")

            // Fallback: create basic controller (but it won't have extensions loaded)
            let config: WKWebExtensionController.Configuration
            if let idString = UserDefaults.standard.string(forKey: "Pola.WKWebExtensionController.Identifier"),
               let uuid = UUID(uuidString: idString) {
                config = WKWebExtensionController.Configuration(identifier: uuid)
            } else {
                let uuid = UUID()
                UserDefaults.standard.set(uuid.uuidString, forKey: "Pola.WKWebExtensionController.Identifier")
                config = WKWebExtensionController.Configuration(identifier: uuid)
            }

            extensionController = WKWebExtensionController(configuration: config)
            extensionController!.delegate = self

            // Don't try to load extensions that aren't prepared yet
            print("🔄 Extension controller created but no extensions loaded yet")
            return
        }
 
    }
    
    /// Check if the extension manager is ready to be used
    public var isReady: Bool {
        return isInitialized && extensionContext?.isLoaded == true
    }
    
    /// Get all installed extensions info for Flutter
    public func getAllInstalledExtensions() -> [[String: Any]] {
        return Self.globalExtensionContexts.map { context in
            let id = context.uniqueIdentifier
            let name = context.webExtension.displayName ?? "Unknown"
            let version = context.webExtension.version ?? "Unknown"
            let isLoaded = context.isLoaded
            let hasCommands = context.webExtension.hasCommands
            let hasOptionsPage = context.webExtension.hasOptionsPage
            let hasPopup = hasCommands || hasOptionsPage
            let description = context.webExtension.displayVersion ?? ""

            return [
                "id": id,
                "name": name,
                "version": version,
                "isLoaded": isLoaded,
                "hasPopup": hasPopup,
                "description": description
            ]
        }
    }

    /// Log essential extension status
    private func logExtensionStatus() {
        guard let controller = extensionController,
              let firstContext = controller.extensionContexts.first else {
            print("Extension not available")
            return
        }
        
        let webExtension = firstContext.webExtension
        print("Extension loaded: \(webExtension.displayName ?? "Unknown") v\(webExtension.version ?? "Unknown")")
    }

    /// Ensure extension is fully ready for blocking on this WebView
    /// Call this before any navigation to ensure rules are active
    public func ensureExtensionIsReady(completion: @escaping (Bool) -> Void) {
        guard isReady else {
            print("Extension not ready")
            completion(false)
            return
        }
        
        // Check if declarativeNetRequest rules are likely active
        // We do this by checking if the extension has the permission and is loaded
        guard let context = extensionContext,
              context.isLoaded,
              context.currentPermissions.contains(.declarativeNetRequest) else {
            print("Extension missing declarativeNetRequest or not loaded")
            completion(false)
            return
        }
        
        // Add a small delay to ensure rules are fully active on this WebView instance
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            print("✅ Extension rules should be active on this WebView")
            completion(true)
        }
    }
    
    /// Check if DNR rules are ready in a specific WebView with timeout
    /// - Parameters:
    ///   - webView: The WebView to check
    ///   - timeoutSeconds: Maximum time to wait for readiness
    /// - Returns: True if rules are ready within timeout, false otherwise
    public func checkDNRRulesReady(in webView: WKWebView, timeoutSeconds: Double) async -> Bool {
        let startTime = Date()
        let pollInterval: UInt64 = 300_000_000  // 300ms intervals for responsiveness
        let enforceAfterSeconds: Double = 4.0   // Threshold: Assume ready after 4s + initial settle (tune: 3-6s based on tests)
        let maxPolls = Int(timeoutSeconds / 0.3)
        var pollCount = 0
        
        print("🔄 Checking DNR rules readiness (time-based, enforce after \(enforceAfterSeconds)s, max \(timeoutSeconds)s)...")
        
        guard let context = extensionContext,
              context.isLoaded,
              context.currentPermissions.contains(.declarativeNetRequest) else {
            print("❌ Extension context not ready or missing DNR permissions")
            return false
        }
        
        // Initial settle time (1.5s) for background startup and rule fetch/compile
        print("   Waiting initial 1.5s settle for uBlock background...")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        
        // Poll basic state + time until enforcement threshold
        while Date().timeIntervalSince(startTime) < timeoutSeconds && pollCount < maxPolls {
            pollCount += 1
            let elapsed = Date().timeIntervalSince(startTime)
            let settleElapsed = elapsed + 1.5  // Account for initial wait
            print("   Poll \(pollCount)/\(maxPolls) at \(String(format: "%.1f", elapsed))s (settled: \(String(format: "%.1f", settleElapsed))s)...")
            
            // Your original basic checks for container readiness
            if context.isLoaded && isReady {
                if let controller = extensionController,
                   controller.extensionContexts.contains(context) {
                    
                    // Time-based enforcement check: uBlock rules are active after threshold
                    if settleElapsed >= enforceAfterSeconds {
                        let totalTime = elapsed + 1.5  // Total from start
                        print("✅ DNR rules ENFORCEMENT READY (time threshold hit) after \(String(format: "%.1f", totalTime))s (\(pollCount) polls)")
                        return true
                    } else {
                        print("   Container ready, but waiting for enforcement threshold (\(String(format: "%.1f", enforceAfterSeconds - settleElapsed))s remaining)")
                    }
                } else {
                    print("   Waiting for controller context sync...")
                }
            } else {
                print("   Waiting for basic load (\(context.isLoaded ? "" : "not ")loaded, \(isReady ? "" : "not ")ready)")
            }
            
            // Wait between polls
            try? await Task.sleep(nanoseconds: pollInterval)
        }
        
        let totalTime = Date().timeIntervalSince(startTime) + 1.5  // Include settle
        print("⚠️ DNR enforcement not confirmed after \(String(format: "%.1f", totalTime))s - degraded mode (rules apply on nav/refresh)")
        return false  // Proceed degraded (will still block after wait/buffer)
    }
    
    
    @MainActor
    public func performInstallation(from sourceURL: URL) async throws {
        let extensionsDir = Self.getExtensionsDirectory()
        try FileManager.default.createDirectory(at: extensionsDir, withIntermediateDirectories: true)
        
        let extensionId = ExtensionUtils.generateExtensionId()
        let destinationDir = extensionsDir.appendingPathComponent(extensionId)
        
        // Handle remote URLs by downloading first
        let localSourceURL: URL
        if sourceURL.scheme == "http" || sourceURL.scheme == "https" {
            print("🌐 Downloading extension from remote URL: \(sourceURL.absoluteString)")
            let (downloadedURL, _) = try await URLSession.shared.download(from: sourceURL)
            localSourceURL = downloadedURL
            print("✅ Downloaded to temporary location: \(localSourceURL.path)")
        } else {
            localSourceURL = sourceURL
        }
        
        // Handle ZIP files and directories
        let extensionName = sourceURL.deletingPathExtension().lastPathComponent
        if sourceURL.pathExtension.lowercased() == "zip" {
            try Self.extractZipWithProperStructure(from: localSourceURL, to: destinationDir, extensionName: extensionName)
        } else {
            try FileManager.default.copyItem(at: localSourceURL, to: destinationDir)
        }
        
        // Validate manifest exists
        let manifestURL = destinationDir.appendingPathComponent("manifest.json")
        let manifest = try ExtensionUtils.validateManifest(at: manifestURL)
        
        // Use native WKWebExtension for loading with explicit manifest parsing
        print("🔧 [ExtensionManager] Initializing WKWebExtension...")
        print("   Resource base URL: \(destinationDir.path)")
        print("   Manifest version: \(manifest["manifest_version"] ?? "unknown")")
        
        // Try the recommended initialization method with proper manifest parsing
        let webExtension = try await WKWebExtension(resourceBaseURL: destinationDir)
        self.extensionContext = WKWebExtensionContext(for: webExtension)
        
        // Debug the loaded extension
        print("✅ WKWebExtension created successfully")
        print("ExtensionManager: Installing extension '\(webExtension.displayName ?? "Unknown")'")
        print("   Version: \(webExtension.version ?? "Unknown")")
        print("   Requested permissions: \(webExtension.requestedPermissions)")
        print("   Requested match patterns: \(webExtension.requestedPermissionMatchPatterns)")
        
        // Pre-grant common permissions for extensions that need them (like Dark Reader)
        for permission in Self.commonPermissions {
            self.extensionContext?.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        
        // MV3: Handle host permissions (formerly <all_urls>)
        for matchPattern in webExtension.requestedPermissionMatchPatterns {
            self.extensionContext?.setPermissionStatus(.grantedExplicitly, for: matchPattern)
            print("   ✅ Pre-granted match pattern: \(matchPattern)")
            print("      Pattern string: '\(matchPattern.description)'")
        }
        
        // MV3: Special handling for host permissions
        let hasAllUrls = webExtension.requestedPermissionMatchPatterns.contains(where: { $0.description.contains("all_urls") })
        let hasWildcardHosts = webExtension.requestedPermissionMatchPatterns.contains(where: { $0.description.contains("*://*/*") })
        
        if hasAllUrls || hasWildcardHosts {
            print("   🌐 MV3 extension has broad host permissions - content scripts should work!")
            // MV3: Ensure we also grant the host_permissions from manifest
            if let hostPermissions = manifest["host_permissions"] as? [String] {
                print("   📝 MV3 host_permissions found: \(hostPermissions)")
            }
        }
    }
    
    public func loadExtension() {
        guard let extensionContext = self.extensionContext else {
            print("No extension context available to load")
            return
        }
        
        do {
            // Unload if already loaded to ensure clean state
            try extensionController?.unload(extensionContext)
            print("Unloaded existing extension context")
        } catch {
            print("No existing extension context to unload: \(error)")
        }
        
        do {
            try extensionController?.load(extensionContext)
            print("Successfully loaded extension context")
        } catch {
            print("Failed to load extension context: \(error)")
            return
        }
        
        // Log status after loading
        logExtensionStatus()
    }
    
    /// Debug method to check if a WebView has the extension controller
    public func checkWebViewHasExtensions(_ webView: WKWebView) {
        let hasExtensionController = webView.configuration.webExtensionController != nil
        let extensionCount = webView.configuration.webExtensionController?.extensions.count ?? 0
        
        print("🔍 WebView Extension Debug:")
        print("   Has extension controller: \(hasExtensionController)")
        print("   Extension count: \(extensionCount)")
        
        if !hasExtensionController {
            print("   ❌ This WebView will NOT have ad-blocking or other extensions!")
            print("   💡 Solution: Use ExtensionManager.createWebViewConfiguration() when creating WebViews")
        } else {
            print("   ✅ This WebView should have extensions working")
        }
    }
    
    public static func getExtensionsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Pola").appendingPathComponent("Extensions")
    }
    
    public static func extractZip(from zipURL: URL, to destinationURL: URL) throws {
        try extractZipWithProperStructure(from: zipURL, to: destinationURL, extensionName: zipURL.deletingPathExtension().lastPathComponent)
    }
    
    public static func extractZipWithProperStructure(from zipURL: URL, to destinationURL: URL, extensionName: String) throws {
        // Ensure parent directory exists
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-q", "-o", zipURL.path, "-d", destinationURL.path]
        
        try task.run()
        task.waitUntilExit()
        
        print("📦 Extracted to: \(destinationURL.path)")
        
        if task.terminationStatus != 0 {
            throw ExtensionError.installationFailed("Failed to extract ZIP file")
        }
        
        // Check the extraction structure and organize properly
        let contents = try FileManager.default.contentsOfDirectory(at: destinationURL, includingPropertiesForKeys: [.isDirectoryKey])
        
        print("📋 Extracted contents (\(contents.count) items):")
        for item in contents {
            let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey])
            let isDir = resourceValues.isDirectory ?? false
            print("   - \(item.lastPathComponent) \(isDir ? "[DIR]" : "[FILE]")")
        }
        
        // Case 1: Single top-level directory containing the extension
        if contents.count == 1,
           let singleItem = contents.first,
           let isDirectory = try singleItem.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
           isDirectory {
            
            let manifestURL = singleItem.appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                print("📦 Found extension in subdirectory: \(singleItem.lastPathComponent)")
                print("   Moving contents to extension root level...")
                
                // Create temporary directory for the move operation
                let tempDir = destinationURL.appendingPathComponent("temp_extension_move")
                try FileManager.default.moveItem(at: singleItem, to: tempDir)
                
                // Move all extension files to the root level
                let subContents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                for item in subContents {
                    let destination = destinationURL.appendingPathComponent(item.lastPathComponent)
                    try FileManager.default.moveItem(at: item, to: destination)
                }
                
                // Clean up temporary directory
                try FileManager.default.removeItem(at: tempDir)
                print("   ✅ Extension files moved to proper structure")
            } else {
                print("   ⚠️ Directory doesn't contain manifest.json, keeping as-is")
            }
        } else {
            // Case 2: Files are already at root level or multiple items
            let manifestURL = destinationURL.appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                print("   ✅ Extension already has proper structure with manifest.json at root")
            } else {
                print("   ⚠️ No manifest.json found at root level - extension may not load properly")
                
                // Try to find manifest.json in subdirectories
                for item in contents {
                    let resourceValues = try item.resourceValues(forKeys: [.isDirectoryKey])
                    if resourceValues.isDirectory == true {
                        let possibleManifest = item.appendingPathComponent("manifest.json")
                        if FileManager.default.fileExists(atPath: possibleManifest.path) {
                            print("   📁 Found manifest.json in subdirectory: \(item.lastPathComponent)")
                        }
                    }
                }
            }
        }
        
        // Final verification
        let finalManifestURL = destinationURL.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: finalManifestURL.path) {
            print("✅ Extension '\(extensionName)' properly extracted with manifest.json")
        } else {
            print("❌ Extension '\(extensionName)' extraction completed but manifest.json not found at root")
        }
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       connectUsing messagePort: WKWebExtension.MessagePort,
                                       for context: WKWebExtensionContext,
                                       completionHandler: @escaping (Error?) -> Void) {
        print("🔌 [ExtensionManager] webExtensionController:connectUsing:for:")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        completionHandler(nil)
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       didUpdate action: WKWebExtension.Action,
                                       forExtensionContext context: WKWebExtensionContext) {
        print("🔄 [ExtensionManager] webExtensionController:didUpdate:forExtensionContext:")
        print("   Extension context: \(context)")
        print("   Extension controller: \(webExtensionController)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   Action label: \(action.label ?? "No label")")
        print("   Action icon: \(action.icon != nil ? "Has icon" : "No icon")")
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       focusedWindowFor context: WKWebExtensionContext) -> WKWebExtensionWindow? {
        print("🪟 [ExtensionManager] webExtensionController:focusedWindowFor:")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        if let window = extensionWindow {
            print("   Returning: ExtensionWindow instance")
            return window
        } else {
            print("   Returning: empty array (no windows available)")
            return nil
        }
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       openNewTabUsing configuration: WKWebExtension.TabConfiguration,
                                       for context: WKWebExtensionContext,
                                       completionHandler: @escaping (WKWebExtensionTab?, Error?) -> Void) {
        print("📂 [ExtensionManager] webExtensionController:openNewTabUsing:for:")
        print("   Tab configuration: \(configuration)")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   URL: \(configuration.url?.absoluteString ?? "No URL")")
        print("   Should be active: \(configuration.shouldBeActive)")
        print("   Returning: nil (tab creation not implemented)")
        completionHandler(nil, ExtensionError.installationFailed("Tab creation not implemented"))
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
                                       for context: WKWebExtensionContext,
                                       completionHandler: @escaping (WKWebExtensionWindow?, Error?) -> Void) {
        print("🪟 [ExtensionManager] webExtensionController:openNewWindowUsing:for:")
        print("   Window configuration: \(configuration)")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   Should be focused: \(configuration.shouldBeFocused)")
        print("   Returning: nil (window creation not implemented)")
        completionHandler(nil, ExtensionError.installationFailed("Window creation not implemented"))
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       openOptionsPageFor context: WKWebExtensionContext,
                                       completionHandler: @escaping (Error?) -> Void) {
        print("⚙️ [ExtensionManager] webExtensionController:openOptionsPageFor:")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   Not implemented - options page will not open")
        completionHandler(ExtensionError.installationFailed("Options page not implemented"))
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       openWindowsFor context: WKWebExtensionContext) -> [WKWebExtensionWindow] {
        print("🪟 [ExtensionManager] webExtensionController:openWindowsFor:")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")

        if let window = extensionWindow {
            print("   Returning: ExtensionWindow instance")
            return [window]
        } else {
            print("   Returning: empty array (no windows available)")
            return []
        }
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       presentActionPopup action: WKWebExtension.Action,
                                       for context: WKWebExtensionContext,
                                       completionHandler: @escaping (Error?) -> Void) {
        print("🎯 [ExtensionManager] webExtensionController:presentActionPopup:for:")
        print("   Action: \(action)")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   Action label: \(action.label ?? "No label")")
        print("   Popup URL: \(action.popupWebView?.url?.absoluteString ?? "No popup URL")")

        // Track the extension for cleanup
        let extensionId = context.uniqueIdentifier
        print("   📋 Delegate called for extension: \(extensionId)")

        // Mark that delegate was called for this extension
        delegateCallTracker[extensionId] = true

        guard let popupWebView = action.popupWebView else {
            print("   ❌ No popup web view available")
            completionHandler(ExtensionError.installationFailed("No popup web view available"))
            return
        }

        // Close any existing popovers for this extension to prevent conflicts
        ExtensionPopupWindowManager.shared.closeExistingPopoverForExtension(extensionId)

        // Grant essential permissions for the popup to function
        context.setPermissionStatus(.grantedExplicitly, for: .activeTab)
        context.setPermissionStatus(.grantedExplicitly, for: .scripting)

        // IMPORTANT: Configure the popup WebView properly for reuse
        // Ensure the WebView has the correct extension controller without breaking existing state
        if popupWebView.configuration.webExtensionController == nil {
            popupWebView.configuration.webExtensionController = webExtensionController
            print("   🔧 Configured popup WebView with extension controller")
        }
        popupWebView.isInspectable = true

        // Use async dispatch to avoid interfering with WebKit's current commit transaction
        // This follows Nook's approach to prevent issues with repeated popup presentation
        DispatchQueue.main.async {
            // Create popover with transient behavior (allows closing by clicking outside)
            let popover = NSPopover()
            popover.contentSize = NSSize(width: 400, height: 600)
            popover.behavior = .transient  // Allow closing by clicking outside
            popover.animates = true

            // Create a view controller to hold the web view
            let viewController = NSViewController()

            // CRITICAL FIX: Ensure the WebView is properly prepared for display
            // Remove from any existing superview to prevent reuse issues
            popupWebView.removeFromSuperview()
            viewController.view = popupWebView
            popover.contentViewController = viewController

            // Set up popover close handler to properly clean up the WebView state
            popover.delegate = self

            // Try to find action anchor for this extension (following Nook pattern)
            var anchorView: NSView?
            var anchorRect: NSRect

            if let registeredAnchor = self.actionAnchors[extensionId] {
                anchorView = registeredAnchor
                anchorRect = registeredAnchor.bounds
                print("   📍 Using registered anchor for extension: \(extensionId)")
            } else if let mainWindow = NSApplication.shared.mainWindow,
                      let contentView = mainWindow.contentView {
                // Fallback to center of main window
                anchorView = contentView
                anchorRect = NSRect(
                    x: contentView.bounds.midX,
                    y: contentView.bounds.midY,
                    width: 1,
                    height: 1
                )
                print("   📍 Using fallback center anchor")
            } else {
                print("   ❌ No suitable anchor view available")
                completionHandler(ExtensionError.installationFailed("No anchor view available"))
                return
            }

            guard let finalAnchorView = anchorView else {
                completionHandler(ExtensionError.installationFailed("No anchor view available"))
                return
            }

            // Show the popover
            popover.show(relativeTo: anchorRect, of: finalAnchorView, preferredEdge: .minY)

            // Store the popover for management
            ExtensionPopupWindowManager.shared.addPopover(popover, forExtension: extensionId)

            print("   ✅ Extension popup displayed as popover (with proper WebView cleanup)")
            completionHandler(nil)
        }
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
                                       in tab: WKWebExtensionTab?,
                                       for context: WKWebExtensionContext,
                                       completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
        print("🔐 [ExtensionManager] webExtensionController:promptForPermissionMatchPatterns:in:for:")
        print("   Match patterns: \(matchPatterns)")
        print("   Tab: \(tab?.description ?? "No tab")")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   Auto-granting all requested match patterns")
        
        // Auto-grant all requested match patterns
        completionHandler(matchPatterns, nil)
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       promptForPermissionToAccess urls: Set<URL>,
                                       in tab: WKWebExtensionTab?,
                                       for context: WKWebExtensionContext,
                                       completionHandler: @escaping (Set<URL>, Date?) -> Void) {
        print("🔓 [ExtensionManager] webExtensionController:promptForPermissionToAccess:in:for:")
        print("   URLs: \(urls)")
        print("   Tab: \(tab?.description ?? "No tab")")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   Auto-granting access to all requested URLs")
        
        // Auto-grant access to all requested URLs
        completionHandler(urls, nil)
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       promptForPermissions permissions: Set<WKWebExtension.Permission>,
                                       in tab: WKWebExtensionTab?,
                                       for context: WKWebExtensionContext,
                                       completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
        print("🛡️ [ExtensionManager] webExtensionController:promptForPermissions:in:for:")
        print("   Permissions: \(permissions)")
        print("   Tab: \(tab?.description ?? "No tab")")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   Auto-granting all requested permissions")
        
        // Auto-grant all requested permissions
        completionHandler(permissions, nil)
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                       sendMessage message: Any,
                                       toApplicationWithIdentifier identifier: String?,
                                       for context: WKWebExtensionContext,
                                       replyHandler: @escaping (Any?, Error?) -> Void) {
        print("📨 [ExtensionManager] webExtensionController:sendMessage:toApplicationWithIdentifier:for:")
        print("   Message: \(message)")
        print("   Application identifier: \(identifier ?? "No identifier")")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   Not implemented - no reply will be sent")
        replyHandler(nil, ExtensionError.installationFailed("Inter-app messaging not implemented"))
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        print("🎯 [ExtensionManager] Popover closed - cleaning up WebView and action state")

        // Get the popover from the notification
        guard let popover = notification.object as? NSPopover else {
            print("   ⚠️ Could not get popover from notification")
            return
        }

        // Clean up the WebView to ensure it can be reused properly
        if let viewController = popover.contentViewController,
           let webView = viewController.view as? WKWebView {
            print("   🧹 Cleaning up popup WebView for next use")

            // Stop any ongoing loading to prevent state conflicts
            webView.stopLoading()

            // Clear the WebView's content but keep it ready for reuse
            webView.loadHTMLString("", baseURL: nil)

            // Remove the WebView from its parent view controller
            webView.removeFromSuperview()

            // Clear the view controller's view reference
            viewController.view = NSView()

            // IMPORTANT: DO NOT modify the extension controller configuration
            // Modifying webExtensionController can break the popup functionality
            // The WebView should retain its extension controller for proper reuse
            print("   ✅ WebView cleaned up without breaking extension controller")
        }

        // Clear the popover's delegate to prevent retain cycles
        popover.delegate = nil

        // Reset delegate call tracker but don't force background reload
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Reset tracker for this specific extension
            if let extensionId = ExtensionPopupWindowManager.shared.getExtensionId(for: popover) {
                self.delegateCallTracker[extensionId] = false
                print("   🔄 Reset delegate tracker for extension: \(extensionId)")
            }

            // FIXED: Don't reload background content as it can break action state
            // Instead, let WebKit naturally reset the action state on next interaction
            print("   ✅ Popup cleanup completed - ready for next use")
        }
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        print("🎯 [ExtensionManager] Popover should close - preparing for cleanup")
        return true
    }

    public func popoverWillClose(_ notification: Notification) {
        print("🎯 [ExtensionManager] Popover will close - preparing for cleanup")

        // This is called just before the popover closes
        // Minimal preparation to avoid interfering with WebKit's action state
        guard let popover = notification.object as? NSPopover else { return }

        if let viewController = popover.contentViewController,
           let webView = viewController.view as? WKWebView {

            // Stop loading to prevent any ongoing operations
            webView.stopLoading()
            print("   🛑 Stopped WebView loading")
        }
    }
}
