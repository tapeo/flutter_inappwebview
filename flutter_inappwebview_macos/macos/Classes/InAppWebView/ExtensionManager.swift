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

// 1. extension manager should be an instance, each webview need to have its own extension manager
// 2. the only static method is the performInstallation, that create a static context to be used by the extension manager

public class ExtensionManager: NSObject, ObservableObject, WKWebExtensionControllerDelegate {

    public var extensionContext: WKWebExtensionContext?
    public var extensionController: WKWebExtensionController?

    // Static shared components for reuse
    private static var sharedExtensionController: WKWebExtensionController?
    private static var sharedExtensionContexts: [WKWebExtensionContext] = []
    private static var isPrepared = false

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

    public func openExtensionPopup(for extensionId: String) {
        guard let context = extensionContext,
              let controller = extensionController else {
            print("❌ Extension context or controller not available")
            return
        }

        print("🎯 Opening extension popup for: \(extensionId)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")

        Task { @MainActor in
            do {
                // Get the first available tab from the extension controller
                guard let firstTab = controller.extensionContexts.first?.openTabs.first else {
                    print("❌ No tabs available in extension context")
                    try await context.performAction(for: nil)
                    print("✅ Extension action performed without tab context")
                    return
                }

                try await context.performAction(for: firstTab as! WKWebExtensionTab)
                print("✅ Extension action performed successfully with tab context")
            } catch {
                print("❌ Failed to perform extension action: \(error)")
                // If performAction fails, it might mean no popup is defined
                print("   This extension may not have a popup defined")
            }
        }
    }

    /// Set action anchor view for better popup positioning (following Nook pattern)
    public func setActionAnchor(for extensionId: String, anchorView: NSView) {
        actionAnchors[extensionId] = anchorView
        print("📍 Set action anchor for extension: \(extensionId)")
    }

    /// Remove action anchor for extension
    public func removeActionAnchor(for extensionId: String) {
        actionAnchors.removeValue(forKey: extensionId)
        print("📍 Removed action anchor for extension: \(extensionId)")
    }

    /// Static method to prepare extension system at app startup
    /// Call this once when the app starts, before creating any WebViews
    /// Returns true if preparation was successful, false otherwise
    @MainActor
    public static func prepareExtensionSystem() async -> Bool {
        print("🚀 Preparing extension system...")

        guard !isPrepared else {
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
            sharedExtensionController = WKWebExtensionController(configuration: config)
            sharedExtensionContexts = []

            // Try to load from bundled resources first
            var extensionsLoaded = 0

            // First try to load from bundled resources (plugin bundle)
            let pluginBundle = Bundle(for: ExtensionManager.self)

            // Check multiple possible resource locations in framework
            let possibleResourcePaths = [
                pluginBundle.resourceURL,
                pluginBundle.bundleURL.appendingPathComponent("Versions/A/Resources"),
                pluginBundle.bundleURL.appendingPathComponent("Resources")
            ].compactMap { $0 }

            for resourcesURL in possibleResourcePaths {
                if FileManager.default.fileExists(atPath: resourcesURL.path) {
                    print("🔍 Plugin bundle path: \(pluginBundle.bundlePath)")
                    print("🔍 Resources URL: \(resourcesURL.path)")
                    do {
                        let contents = try FileManager.default.contentsOfDirectory(at: resourcesURL, includingPropertiesForKeys: nil)
                        print("🔍 Found \(contents.count) items in Resources directory:")
                        for item in contents {
                            print("   - \(item.lastPathComponent)")
                        }
                        let zipFiles = contents.filter { $0.pathExtension.lowercased() == "zip" }

                        for zipFile in zipFiles {
                            print("📦 Found bundled extension: \(zipFile.lastPathComponent)")
                            do {
                                let context = try await installBundledExtension(from: zipFile)
                                sharedExtensionContexts.append(context)
                                extensionsLoaded += 1
                                print("✅ Bundled extension '\(zipFile.lastPathComponent)' loaded and ready")
                            } catch {
                                print("⚠️ Failed to load bundled extension '\(zipFile.lastPathComponent)': \(error)")
                                continue
                            }
                        }

                        if zipFiles.isEmpty {
                            print("📦 No ZIP extensions found in \(resourcesURL.path)")
                        }
                    } catch {
                        print("📦 Could not read Resources directory \(resourcesURL.path): \(error)")
                    }
                } else {
                    print("🔍 Resources path does not exist: \(resourcesURL.path)")
                }
            }

            // Fallback to downloading uBlock Origin Lite if no bundled extensions loaded
            if extensionsLoaded == 0 {
                print("📥 Downloading fresh uBlock Origin Lite...")
                let url = URL(string: "https://github.com/uBlockOrigin/uBOL-home/releases/download/2025.921.2008/uBOLite_2025.921.2008.safari.zip")!
                let context = try await installExtensionWithReturn(from: url)
                sharedExtensionContexts.append(context)
                extensionsLoaded += 1
                print("✅ Fresh extension downloaded and ready")
            }

            if extensionsLoaded > 0 {
                isPrepared = true
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
        for permission in commonPermissions {
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
        for (index, context) in Self.sharedExtensionContexts.enumerated() {
            print("Extension \(index + 1): \(context.webExtension.displayName ?? "Unknown")")
            print("  ID: \(context.uniqueIdentifier)")
            print("  Options URL: \(context.optionsPageURL?.absoluteString ?? "None")")
            print("  Loaded: \(context.isLoaded)")
        }
    }

    /// Private helper to install bundled extensions with proper structure
    @MainActor
    private static func installBundledExtension(from url: URL) async throws -> WKWebExtensionContext {
        let extensionsDir = getExtensionsDirectory()
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
        try extractZipWithProperStructure(from: url, to: extensionDir, extensionName: zipFileName)

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
        try sharedExtensionController?.load(extensionContext)

        print("🎉 Bundled extension '\(zipFileName)' successfully installed and configured")
        return extensionContext
    }

    /// Private helper to install extension from URL
    @MainActor
    private static func installExtension(from url: URL) async throws {
        let extensionsDir = getExtensionsDirectory()
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

        try extractZipWithProperStructure(from: sourceURL, to: destinationDir, extensionName: zipFileName)

        // Validate manifest
        let manifestURL = destinationDir.appendingPathComponent("manifest.json")
        _ = try ExtensionUtils.validateManifest(at: manifestURL)

        // Load extension
        let webExtension = try await WKWebExtension(resourceBaseURL: destinationDir)
        let extensionContext = WKWebExtensionContext(for: webExtension)
        sharedExtensionContexts = [extensionContext] // Replace existing for backwards compatibility

        // Grant permissions
        await grantPermissionsToContext(extensionContext, webExtension: webExtension)
    }

    /// Private helper to install extension from URL with return value
    @MainActor
    private static func installExtensionWithReturn(from url: URL) async throws -> WKWebExtensionContext {
        let extensionsDir = getExtensionsDirectory()
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

        try extractZipWithProperStructure(from: sourceURL, to: destinationDir, extensionName: zipFileName)

        // Validate manifest
        let manifestURL = destinationDir.appendingPathComponent("manifest.json")
        _ = try ExtensionUtils.validateManifest(at: manifestURL)

        // Load extension
        let webExtension = try await WKWebExtension(resourceBaseURL: destinationDir)
        let extensionContext = WKWebExtensionContext(for: webExtension)

        // Grant permissions
        await grantPermissionsToContext(extensionContext, webExtension: webExtension)

        // Load into shared controller
        try sharedExtensionController?.load(extensionContext)

        return extensionContext
    }

    override public init() {
        super.init()
        
        print("initilization!!!")

        // Use pre-prepared shared components if available
        if Self.isPrepared,
           let sharedController = Self.sharedExtensionController,
           !Self.sharedExtensionContexts.isEmpty {

            print("🔌 Using pre-prepared extension components (\(Self.sharedExtensionContexts.count) extension(s))")
            extensionController = sharedController
            // Use the first extension context for backwards compatibility
            extensionContext = Self.sharedExtensionContexts.first
            isInitialized = true

            // Set delegate for this instance
            if #available(macOS 15.4, *) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    sharedController.delegate = self
                }
            } else {
                sharedController.delegate = self
            }
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

            if #available(macOS 15.4, *) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.extensionController?.delegate = self
                }
            } else {
                extensionController?.delegate = self
            }
        }



        // Load into controller
        try? extensionController?.load(extensionContext!)

        if extensionContext!.isLoaded {
            print("📋 Extension loaded and active")
            print("✅ Extension rules should now be active")
          
        }

        print(extensionContext!.webExtension.displayName)
        print(extensionContext!.uniqueIdentifier)
        print(extensionContext!.optionsPageURL)
        print(extensionContext!.isLoaded)
    }
    
    /// Initialize the extension manager with a completion callback
    /// - Parameter callback: Called when initialization completes with success/failure status
    public func initialize(completion: @escaping InitializationCallback) {
        if isInitialized {
            print("ExtensionManager already initialized")
            completion(true)
            return
        }

        if Self.isPrepared {
            print("Extension system was pre-prepared but not attached to this instance")
            completion(false)
        } else {
            print("Extension system not prepared - call prepareExtensionSystem() first")
            completion(false)
        }
    }
    
    /// Re-initialize the extension manager (useful for retrying after failure)
    /// - Parameter callback: Called when re-initialization completes with success/failure status
    public func reinitialize(completion: @escaping InitializationCallback) {
        isInitialized = false
        initialize(completion: completion)
    }
    
    /// Check if the extension manager is ready to be used
    public var isReady: Bool {
        return isInitialized && extensionContext?.isLoaded == true
    }

    /// Get the count of loaded extensions for debugging
    public var extensionCount: Int {
        return extensionController?.extensions.count ?? 0
    }

    /// Get the count of extension contexts for debugging
    public var extensionContextCount: Int {
        return extensionController?.extensionContexts.count ?? 0
    }

    /// Get all loaded extension contexts
    public var allExtensionContexts: [WKWebExtensionContext] {
        return Self.sharedExtensionContexts
    }

    /// Get all installed extensions info for Flutter
    public static func getAllInstalledExtensions() -> [[String: Any]] {
        return sharedExtensionContexts.map { context in
            return [
                "id": context.uniqueIdentifier,
                "name": context.webExtension.displayName ?? "Unknown",
                "version": context.webExtension.version ?? "Unknown",
                "isLoaded": context.isLoaded,
                "hasPopup": context.webExtension.hasCommands || context.webExtension.hasOptionsPage,
                "description": context.webExtension.displayVersion ?? ""
            ]
        }
    }

    /// Static method to open extension popup programmatically by extension ID
    public static func openExtensionPopup(extensionId: String) -> Bool {
        guard let context = sharedExtensionContexts.first(where: { $0.uniqueIdentifier == extensionId }),
              let controller = sharedExtensionController else {
            print("❌ Extension not found or controller not available: \(extensionId)")
            return false
        }

        print("🎯 Opening extension popup programmatically for: \(extensionId)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")

        Task { @MainActor in
            do {
                // Get the first available tab from the extension controller
                guard let firstTab = controller.extensionContexts.first?.openTabs.first else {
                    print("❌ No tabs available in extension context")
                    try await context.performAction(for: nil)
                    print("✅ Extension action performed without tab context")
                    return
                }

                try await context.performAction(for: firstTab as! WKWebExtensionTab)
                print("✅ Extension action performed successfully with tab context")
            } catch {
                print("❌ Failed to perform extension action: \(error)")
                // If performAction fails, it might mean no popup is defined
                print("   This extension may not have a popup defined")
            }
        }

        return true
    }

    /// Get extension info for debugging
    public var extensionInfo: [String] {
        return Self.sharedExtensionContexts.map { context in
            let name = context.webExtension.displayName ?? "Unknown"
            let version = context.webExtension.version ?? "Unknown"
            let loaded = context.isLoaded ? "✅" : "❌"
            return "\(loaded) \(name) v\(version)"
        }
    }
    
    /// Get initialization status information for debugging
    public var statusInfo: String {
        var info = """
        ExtensionManager Status:
        - Initialized: \(isInitialized)
        - Primary Extension Context Loaded: \(extensionContext?.isLoaded ?? false)
        - Extension Controller: \(extensionController != nil ? "Available" : "Not Available")
        - Extension Count: \(extensionController?.extensions.count ?? 0)
        - Context Count: \(Self.sharedExtensionContexts.count)
        - Ready: \(isReady)

        Loaded Extensions:
        """

        for (index, context) in Self.sharedExtensionContexts.enumerated() {
            let name = context.webExtension.displayName ?? "Unknown"
            let version = context.webExtension.version ?? "Unknown"
            let loaded = context.isLoaded ? "✅" : "❌"
            info += "\n  \(index + 1). \(loaded) \(name) v\(version)"
        }

        if Self.sharedExtensionContexts.isEmpty {
            info += "\n  (No extensions loaded)"
        }

        return info
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

    /// Check if extension has access to a specific URL
    public func checkURLAccess(_ url: URL) -> Bool {
        guard let firstContext = extensionController?.extensionContexts.first else {
            return false
        }
        return firstContext.hasAccess(to: url)
    }
    
    /// Helper to run a Promise with timeout
    private func withTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ExtensionError.timeout("DNR check timed out after \(seconds)s")
            }
            let firstResult = try await group.next()!
            group.cancelAll()
            return firstResult
        }
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
        let extensionsDir = ExtensionManager.getExtensionsDirectory()
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
            try ExtensionManager.extractZipWithProperStructure(from: localSourceURL, to: destinationDir, extensionName: extensionName)
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
        for permission in ExtensionManager.commonPermissions {
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
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   Action label: \(action.label ?? "No label")")
        print("   Action icon: \(action.icon != nil ? "Has icon" : "No icon")")
    }
    
    public func webExtensionController(_ webExtensionController: WKWebExtensionController,
                                     focusedWindowFor context: WKWebExtensionContext) -> WKWebExtensionWindow? {
        print("🪟 [ExtensionManager] webExtensionController:focusedWindowFor:")
        print("   Extension context: \(context)")
        print("   Extension name: \(context.webExtension.displayName ?? "Unknown")")
        print("   Returning: nil (no focused window available)")
        return nil
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
        print("   Returning: empty array (no windows available)")
        return []
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

        guard let popupWebView = action.popupWebView else {
            print("   ❌ No popup web view available")
            completionHandler(ExtensionError.installationFailed("No popup web view available"))
            return
        }

        // Grant essential permissions for the popup to function
        context.setPermissionStatus(.grantedExplicitly, for: .activeTab)
        context.setPermissionStatus(.grantedExplicitly, for: .scripting)

        // Configure the popup WebView
        popupWebView.configuration.webExtensionController = webExtensionController
        popupWebView.isInspectable = true

        // Create popover for better UX (similar to browser extension popups)
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 600)
        popover.behavior = .transient
        popover.animates = true

        // Create a view controller to hold the web view
        let viewController = NSViewController()
        viewController.view = popupWebView
        popover.contentViewController = viewController

        // Try to find action anchor for this extension (following Nook pattern)
        let extensionId = context.uniqueIdentifier
        var anchorView: NSView?
        var anchorRect: NSRect

        if let registeredAnchor = actionAnchors[extensionId] {
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

        popover.show(relativeTo: anchorRect, of: finalAnchorView, preferredEdge: .minY)

        // Keep reference to prevent deallocation
        ExtensionPopupWindowManager.shared.addPopover(popover)

        print("   ✅ Extension popup displayed as popover")
        completionHandler(nil)
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
}

struct ExtensionUtils {
    /// Check if the current OS supports WKWebExtension APIs we rely on
    /// We target the newest OS that includes `world` support for scripting/content scripts.
    /// Requires iOS/iPadOS 18.5+ or macOS 15.5+.
    static var isExtensionSupportAvailable: Bool {
        if #available(iOS 18.5, macOS 15.5, *) { return true }
        return false
    }
    
    /// Whether MAIN/ISOLATED execution worlds are supported for `chrome.scripting` and content scripts.
    /// Newer WebKit builds honor `world: 'MAIN'|'ISOLATED'` and `content_scripts[].world`.
    static var isWorldInjectionSupported: Bool {
        if #available(iOS 18.5, macOS 15.5, *) { return true }
        return false
    }
    
    /// Show an alert when extensions are not available on older OS versions
    static func showUnsupportedOSAlert() {
        // This will be implemented when we add alert functionality
        print("Extensions require iOS 18.5+ or macOS 15.5+")
    }
    
    /// Validate a manifest.json file structure
    static func validateManifest(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtensionError.invalidManifest("Invalid JSON structure")
        }
        
        // Basic manifest validation
        guard let _ = manifest["manifest_version"] as? Int else {
            throw ExtensionError.invalidManifest("Missing manifest_version")
        }
        
        guard let _ = manifest["name"] as? String else {
            throw ExtensionError.invalidManifest("Missing name")
        }
        
        guard let _ = manifest["version"] as? String else {
            throw ExtensionError.invalidManifest("Missing version")
        }
        
        return manifest
    }
    
    /// Generate a unique extension identifier
    static func generateExtensionId() -> String {
        return UUID().uuidString.lowercased()
    }
}

/// Manager class to handle extension popup windows and popovers
class ExtensionPopupWindowManager: NSObject, NSWindowDelegate, NSPopoverDelegate {
    static let shared = ExtensionPopupWindowManager()
    private var popupWindows = Set<NSWindow>()
    private var popupPopovers = Set<NSPopover>()

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

    func removePopover(_ popover: NSPopover) {
        popupPopovers.remove(popover)
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
    func popoverWillClose(_ notification: Notification) {
        if let popover = notification.object as? NSPopover {
            removePopover(popover)
            print("🗑️ Extension popup popover closed and removed from manager")
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
