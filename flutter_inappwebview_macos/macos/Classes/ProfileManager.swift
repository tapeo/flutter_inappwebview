//
//  ProfileManager.swift
//  flutter_inappwebview
//
//  Created for profile management support.
//

import Foundation
import WebKit
import FlutterMacOS

@available(macOS 14.0, *)
public class ProfileManager: ChannelDelegate {
    static let METHOD_CHANNEL_NAME = "com.pichillilorenzo/flutter_inappwebview_profile_manager"
    
    private var plugin: InAppWebViewFlutterPlugin?
    
    // Helper function to convert string profileId to UUID
    private func uuidFromProfileId(_ profileId: String) -> UUID {
        if let parsedUuid = UUID(uuidString: profileId) {
            return parsedUuid
        } else {
            // Create a deterministic UUID from the string hash
            return UUID(uuidString: String(format: "%08x-%04x-%04x-%04x-%012x", 
                                         profileId.hashValue,
                                         0x1000 | (profileId.hashValue & 0x0fff),
                                         0x8000 | (profileId.hashValue & 0x3fff),
                                         profileId.hashValue & 0xffff,
                                         profileId.hashValue)) ?? UUID()
        }
    }
    
    init(plugin: InAppWebViewFlutterPlugin) {
        super.init(channel: FlutterMethodChannel(name: ProfileManager.METHOD_CHANNEL_NAME, binaryMessenger: plugin.registrar.messenger))
        self.plugin = plugin
    }
    
    public override func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? [String: Any]
        
        switch call.method {
        case "createProfile":
            if let profileId = arguments?["profileId"] as? String {
                createProfile(profileId: profileId, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "profileId is required", details: nil))
            }
            break
        case "deleteProfile":
            if let profileId = arguments?["profileId"] as? String {
                deleteProfile(profileId: profileId, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "profileId is required", details: nil))
            }
            break
        case "listProfiles":
            listProfiles(result: result)
            break
        case "profileExists":
            if let profileId = arguments?["profileId"] as? String {
                profileExists(profileId: profileId, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "profileId is required", details: nil))
            }
            break
        case "deleteAllProfiles":
            deleteAllProfiles(result: result)
            break
        default:
            result(FlutterMethodNotImplemented)
            break
        }
    }
    
    private func createProfile(profileId: String, result: @escaping FlutterResult) {
        let uuid = uuidFromProfileId(profileId)
        
        // Create the data store (creation is lazy when first accessed)
        _ = WKWebsiteDataStore(forIdentifier: uuid)
        result(true)
    }
    
    private func deleteProfile(profileId: String, result: @escaping FlutterResult) {
        let uuid = uuidFromProfileId(profileId)
        
        WKWebsiteDataStore.remove(forIdentifier: uuid) { error in
            DispatchQueue.main.async {
                if let error = error {
                    result(FlutterError(code: "PROFILE_DELETION_FAILED", message: error.localizedDescription, details: nil))
                } else {
                    result(true)
                }
            }
        }
    }
    
    private func listProfiles(result: @escaping FlutterResult) {
        Task {
            let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
            let profileIds = identifiers.map { $0.uuidString }
            await MainActor.run {
                result(profileIds)
            }
        }
    }
    
    private func profileExists(profileId: String, result: @escaping FlutterResult) {
        let uuid = uuidFromProfileId(profileId)
        
        Task {
            let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
            let exists = identifiers.contains(uuid)
            await MainActor.run {
                result(exists)
            }
        }
    }
    
    private func deleteAllProfiles(result: @escaping FlutterResult) {
        Task {
            let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
            let dispatchGroup = DispatchGroup()
            var errors: [Error] = []
            
            for identifier in identifiers {
                dispatchGroup.enter()
                await WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                    if let error = error {
                        errors.append(error)
                    }
                    dispatchGroup.leave()
                }
            }
            
            dispatchGroup.notify(queue: .main) {
                if errors.isEmpty {
                    result(true)
                } else {
                    let errorMessages = errors.map { $0.localizedDescription }.joined(separator: ", ")
                    result(FlutterError(code: "PROFILE_DELETION_FAILED", message: "Some profiles could not be deleted: \(errorMessages)", details: nil))
                }
            }
        }
    }
    
    public override func dispose() {
        super.dispose()
        plugin = nil
    }
    
    deinit {
        debugPrint("ProfileManager - dealloc")
        dispose()
    }
} 