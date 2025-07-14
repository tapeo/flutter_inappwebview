//
//  ContentBlockerManager.swift
//  flutter_inappwebview
//
//  Created by AI Assistant on 01/01/2024.
//

import Foundation
import WebKit

@available(macOS 10.13, *)
public class ContentBlockerManager {
    public static let shared = ContentBlockerManager()
    
    private var compiledRuleLists: [String: WKContentRuleList] = [:]
    private var compilationQueue = DispatchQueue(label: "ContentBlockerCompilation", qos: .userInitiated)
    
    private init() {}
    
    public func getOrCompileRuleList(
        contentBlockers: [[String: [String: Any]]],
        completionHandler: @escaping (WKContentRuleList?, Error?) -> Void
    ) {
        
        // Generate hash for content blockers to use as cache key
        let cacheKey = generateCacheKey(for: contentBlockers)

        // Check if we already have a compiled rule list for this configuration
        if let cachedRuleList = compiledRuleLists[cacheKey] {
            completionHandler(cachedRuleList, nil)
            return
        }
        
        // Check if WKContentRuleListStore already has this compiled
        WKContentRuleListStore.default().lookUpContentRuleList(forIdentifier: cacheKey) { [weak self] (ruleList, error) in
            if let ruleList = ruleList {
                // Cache the retrieved rule list
                self?.compiledRuleLists[cacheKey] = ruleList
                completionHandler(ruleList, nil)
                return
            }
            
            // Need to compile new rule list
            self?.compileNewRuleList(
                contentBlockers: contentBlockers,
                identifier: cacheKey,
                completionHandler: completionHandler
            )
        }
    }
    
    private func compileNewRuleList(
        contentBlockers: [[String: [String: Any]]],
        identifier: String,
        completionHandler: @escaping (WKContentRuleList?, Error?) -> Void
    ) {
        compilationQueue.async { [weak self] in
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: contentBlockers, options: [])
                
                let blockRules = String(data: jsonData, encoding: .utf8)
                
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: blockRules
                ) { [weak self] (contentRuleList, error) in
                    DispatchQueue.main.async {
                        if let contentRuleList = contentRuleList {
                            // Cache the compiled rule list
                            self?.compiledRuleLists[identifier] = contentRuleList
                            completionHandler(contentRuleList, nil)
                        } else {
                            completionHandler(nil, error)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completionHandler(nil, error)
                }
            }
        }
    }
    
    private func generateCacheKey(for contentBlockers: [[String: [String: Any]]]) -> String {
        // Use the count of content blockers as the cache key
        let urlCount = contentBlockers.count
        return "ContentBlockingRules_\(urlCount)"
    }
    
    public func precompileContentBlockersFromUrls(
        urls: [String],
        completionHandler: @escaping (Bool, Error?) -> Void
    ) {
        // Convert URL strings to ContentBlocker format
        let contentBlockers: [[String: [String: Any]]] = urls.map { url in
            return [
                "trigger": [
                    "url-filter": url,
                    "load-type": ["third-party"],
                    "resource-type": ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup"]
                ] as [String: Any],
                "action": [
                    "type": "block"
                ] as [String: Any]
            ]
        }
        
        // Compile the rule list
        getOrCompileRuleList(contentBlockers: contentBlockers) { (ruleList, error) in
            if let error = error {
                completionHandler(false, error)
            } else {
                completionHandler(ruleList != nil, nil)
            }
        }
    }
    
    public func clearCache() {
        compiledRuleLists.removeAll()
        
        // Optionally clear the WKContentRuleListStore cache as well
        WKContentRuleListStore.default().getAvailableContentRuleListIdentifiers { identifiers in
            guard let identifiers = identifiers else { return }
            for identifier in identifiers {
                if identifier.starts(with: "ContentBlockingRules_") {
                    WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in }
                }
            }
        }
    }
} 