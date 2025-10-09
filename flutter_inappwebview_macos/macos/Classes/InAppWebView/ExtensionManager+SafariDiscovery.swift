//
//  ExtensionManager+SafariDiscovery.swift
//  flutter_inappwebview
//
//  Created by Codex.
//

import AppKit
import Foundation
@preconcurrency import WebKit

extension ExtensionManager {
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

    func grantPermissions(to context: WKWebExtensionContext, for webExtension: WKWebExtension) {
        for permission in Self.commonPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }

        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }

        if let allURLs = try? WKWebExtension.MatchPattern.allURLs() {
            context.setPermissionStatus(.grantedExplicitly, for: allURLs)
        }
    }

    func discoverInstalledSafariExtensions() -> [DiscoveredSafariExtension] {
        let fileManager = FileManager.default
        var discovered: [DiscoveredSafariExtension] = []
        var seenPaths = Set<String>()

        for directory in safariApplicationDirectories() {
            guard fileManager.fileExists(atPath: directory.path) else { continue }

            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "app" {
                for extensionInfo in safariExtensions(inAppBundle: fileURL) {
                    let path = extensionInfo.bundleURL.path
                    guard !seenPaths.contains(path) else { continue }
                    seenPaths.insert(path)
                    discovered.append(extensionInfo)
                }
            }
        }

        return discovered
    }

    func loadInstalledSafariExtensionContexts() async -> (contexts: [WKWebExtensionContext], metadata: [String: InstalledSafariExtensionMetadata], identifiers: Set<String>) {
        var contexts: [WKWebExtensionContext] = []
        var metadata: [String: InstalledSafariExtensionMetadata] = [:]
        var identifiers: Set<String> = []

        for discoveredExtension in discoverInstalledSafariExtensions() {
            do {
                guard let bundle = Bundle(url: discoveredExtension.bundleURL) else {
                    continue
                }

                let webExtension = try await WKWebExtension(appExtensionBundle: bundle)
                let context = WKWebExtensionContext(for: webExtension)

                let identifier = context.uniqueIdentifier
                if identifiers.contains(identifier) { continue }
                identifiers.insert(identifier)

                metadata[identifier] = discoveredExtension.metadata

                grantPermissions(to: context, for: webExtension)
                contexts.append(context)
            } catch {
                print("[ExtensionManager] Failed to load installed extension from \(discoveredExtension.bundleURL.path): \(error)")
            }
        }

        return (contexts, metadata, identifiers)
    }

    func loadLegacyExtensionContexts(excluding existingIdentifiers: Set<String>) async -> (contexts: [WKWebExtensionContext], metadata: [String: InstalledSafariExtensionMetadata], identifiers: Set<String>) {
        var contexts: [WKWebExtensionContext] = []
        var metadata: [String: InstalledSafariExtensionMetadata] = [:]
        var identifiers: Set<String> = []
        let fm = FileManager.default

        let userRoot = ExtensionManager.getExtensionsDirectory().appendingPathComponent("Folders")
        let bundleRoot = ExtensionManager.getExtensionsDirectory().appendingPathComponent("Bundles")

        // Load folder-based extensions (unpacked)
        if let userContents = try? fm.contentsOfDirectory(at: userRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for entry in userContents {
                let manifestURL = entry.appendingPathComponent("manifest.json")
                guard fm.fileExists(atPath: manifestURL.path) else { continue }

                do {
                    let webExtension = try await WKWebExtension(resourceBaseURL: entry)
                    let context = WKWebExtensionContext(for: webExtension)
                    let identifier = context.uniqueIdentifier
                    if existingIdentifiers.contains(identifier) || identifiers.contains(identifier) { continue }

                    identifiers.insert(identifier)
                    grantPermissions(to: context, for: webExtension)

                    let name = webExtension.displayName
                        ?? webExtension.displayShortName
                        ?? entry.lastPathComponent

                    let description = trimmedNonEmpty(webExtension.displayDescription)

                    metadata[identifier] = InstalledSafariExtensionMetadata(
                        name: name,
                        path: entry.path,
                        iconBase64: nil,
                        description: description
                    )

                    contexts.append(context)
                } catch {
                    print("[ExtensionManager] Failed to load folder extension from \(entry.path): \(error)")
                }
            }
        }

        // Load bundled extensions (.appex bundles placed by user)
        if let bundleContents = try? fm.contentsOfDirectory(at: bundleRoot, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) {
            for entry in bundleContents {
                guard entry.pathExtension == "appex" else { continue }
                do {
                    guard let bundle = Bundle(url: entry) else { continue }
                    let webExtension = try await WKWebExtension(appExtensionBundle: bundle)
                    let context = WKWebExtensionContext(for: webExtension)
                    let identifier = context.uniqueIdentifier
                    if existingIdentifiers.contains(identifier) || identifiers.contains(identifier) { continue }

                    identifiers.insert(identifier)
                    grantPermissions(to: context, for: webExtension)

                    let name = webExtension.displayName
                        ?? webExtension.displayShortName
                        ?? entry.deletingPathExtension().lastPathComponent

                    let description = trimmedNonEmpty(webExtension.displayDescription)

                    let metadataEntry = InstalledSafariExtensionMetadata(
                        name: name,
                        path: entry.path,
                        iconBase64: loadIconBase64(forExtensionAt: entry),
                        description: description
                    )

                    metadata[identifier] = metadataEntry
                    contexts.append(context)
                } catch {
                    print("[ExtensionManager] Failed to load bundle extension from \(entry.path): \(error)")
                }
            }
        }

        return (contexts, metadata, identifiers)
    }

    private func safariApplicationDirectories() -> [URL] {
        var directories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true)
        ]

        if let userApplications = FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask).first {
            directories.append(userApplications)
        }

        return directories
    }

    private func safariExtensions(inAppBundle appURL: URL) -> [DiscoveredSafariExtension] {
        let plugInsURL = appURL.appendingPathComponent("Contents/PlugIns", isDirectory: true)
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: plugInsURL.path) else { return [] }

        guard let plugInContents = try? fileManager.contentsOfDirectory(
            at: plugInsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return plugInContents.compactMap { extensionBundleURL in
            guard extensionBundleURL.pathExtension == "appex" else { return nil }
            guard let metadata = extensionMetadata(forExtensionBundleAt: extensionBundleURL) else { return nil }
            return DiscoveredSafariExtension(bundleURL: extensionBundleURL, metadata: metadata)
        }
    }

    private func extensionMetadata(forExtensionBundleAt bundleURL: URL) -> InstalledSafariExtensionMetadata? {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")

        guard
            let infoPlist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any],
            let extensionDictionary = infoPlist["NSExtension"] as? [String: Any],
            let extensionPointIdentifier = extensionDictionary["NSExtensionPointIdentifier"] as? String,
            extensionPointIdentifier.hasPrefix("com.apple.Safari")
        else {
            return nil
        }

        let name = (infoPlist["CFBundleDisplayName"] as? String)
            ?? (infoPlist["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent

        let iconBase64 = loadIconBase64(forExtensionAt: bundleURL)

        let descriptionFromPlist = infoPlist["NSHumanReadableDescription"] as? String
        let description = trimmedNonEmpty(descriptionFromPlist)
            ?? loadManifestDescription(forExtensionAt: bundleURL)

        return InstalledSafariExtensionMetadata(
            name: name,
            path: bundleURL.path,
            iconBase64: iconBase64,
            description: description
        )
    }

    private func loadIconBase64(forExtensionAt bundleURL: URL) -> String? {
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icon.size = NSSize(width: 64, height: 64)

        guard
            let tiffData = icon.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        return pngData.base64EncodedString()
    }

    private func loadManifestDescription(forExtensionAt bundleURL: URL) -> String? {
        let manifestURL = bundleURL.appendingPathComponent("Contents/Resources/manifest.json")

        guard
            let data = try? Data(contentsOf: manifestURL),
            let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
            let manifest = jsonObject as? [String: Any],
            let description = manifest["description"] as? String
        else {
            return nil
        }

        return trimmedNonEmpty(description)
    }

    func trimmedNonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
