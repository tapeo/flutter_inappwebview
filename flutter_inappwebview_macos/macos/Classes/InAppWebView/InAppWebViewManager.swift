//
//  InAppWebViewManager.swift
//  flutter_inappwebview
//
//  Created by Lorenzo Pichilli on 08/12/2019.
//

import Foundation
import WebKit
import FlutterMacOS

public class InAppWebViewManager: ChannelDelegate {
    static let METHOD_CHANNEL_NAME = "com.pichillilorenzo/flutter_inappwebview_manager"
    var plugin: InAppWebViewFlutterPlugin?
    var webViewForUserAgent: WKWebView?
    var defaultUserAgent: String?
    
    var keepAliveWebViews: [String:FlutterWebViewController?] = [:]
    var windowWebViews: [Int64:WebViewTransport] = [:]
    var windowAutoincrementId: Int64 = 0
    
    init(plugin: InAppWebViewFlutterPlugin) {
        super.init(channel: FlutterMethodChannel(name: InAppWebViewManager.METHOD_CHANNEL_NAME, binaryMessenger: plugin.registrar.messenger))
        self.plugin = plugin
    }
    
    public override func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let arguments = call.arguments as? NSDictionary
        
        switch call.method {
            case "getDefaultUserAgent":
                getDefaultUserAgent(completionHandler: { (value) in
                    result(value)
                })
                break
            case "handlesURLScheme":
                let urlScheme = arguments!["urlScheme"] as! String
                if #available(macOS 10.13, *) {
                    result(WKWebView.handlesURLScheme(urlScheme))
                } else {
                    result(false)
                }
                break
            case "disposeKeepAlive":
                let keepAliveId = arguments!["keepAliveId"] as! String
                disposeKeepAlive(keepAliveId: keepAliveId)
                result(true)
                break
            case "clearAllCache":
                let includeDiskFiles = arguments!["includeDiskFiles"] as! Bool
                clearAllCache(includeDiskFiles: includeDiskFiles, completionHandler: {
                    result(true)
                })
            case "clearCacheByDomain":
                let domain = arguments!["domain"] as! String
                let includeDiskFiles = arguments!["includeDiskFiles"] as! Bool
                clearCacheByDomain(domain: domain, includeDiskFiles: includeDiskFiles, completionHandler: {
                    result(true)
                })
            case "clearContentBlockerCache":
                if #available(macOS 10.13, *) {
                    ContentBlockerManager.shared.clearCache()
                }
                result(true)
            case "precompileContentBlockersFromUrls":
                if #available(macOS 10.13, *) {
                    let urls = arguments!["urls"] as! [String]
                    ContentBlockerManager.shared.precompileContentBlockersFromUrls(urls: urls) { (success, error) in
                        if let error = error {
                            result(FlutterError(code: "CONTENT_BLOCKER_ERROR", message: error.localizedDescription, details: nil))
                        } else {
                            result(success)
                        }
                    }
                } else {
                    result(false)
                }
            case "setJavaScriptBridgeName":
                let bridgeName = arguments!["bridgeName"] as! String
                JavaScriptBridgeJS.set_JAVASCRIPT_BRIDGE_NAME(bridgeName: bridgeName)
                result(true)
                break
            case "getJavaScriptBridgeName":
                result(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME())
                break
            default:
                result(FlutterMethodNotImplemented)
                break
        }
    }
    
    public func getDefaultUserAgent(completionHandler: @escaping (_ value: String?) -> Void) {
        if defaultUserAgent == nil {
            webViewForUserAgent = WKWebView()
            webViewForUserAgent?.evaluateJavaScript("navigator.userAgent") { (value, error) in

                if error != nil {
                    print("Error occurred to get userAgent")
                    self.webViewForUserAgent = nil
                    completionHandler(nil)
                    return
                }

                if let unwrappedUserAgent = value as? String {
                    self.defaultUserAgent = unwrappedUserAgent
                    completionHandler(self.defaultUserAgent)
                } else {
                    print("Failed to get userAgent")
                }
                self.webViewForUserAgent = nil
            }
        } else {
            completionHandler(defaultUserAgent)
        }
    }
    
    public func disposeKeepAlive(keepAliveId: String) {
        if let flutterWebView = keepAliveWebViews[keepAliveId] as? FlutterWebViewController {
            flutterWebView.keepAliveId = nil
            flutterWebView.dispose(removeFromSuperview: true)
            keepAliveWebViews[keepAliveId] = nil
        }
    }
    
    public func clearAllCache(includeDiskFiles: Bool, completionHandler: @escaping () -> Void) {
        var websiteDataTypes = Set([WKWebsiteDataTypeMemoryCache])
        if includeDiskFiles {
            websiteDataTypes.insert(WKWebsiteDataTypeDiskCache)
            if #available(macOS 10.13.4, *) {
                websiteDataTypes.insert(WKWebsiteDataTypeFetchCache)
            }
            websiteDataTypes.insert(WKWebsiteDataTypeOfflineWebApplicationCache)
        }
        let date = NSDate(timeIntervalSince1970: 0)
        WKWebsiteDataStore.default().removeData(ofTypes: websiteDataTypes, modifiedSince: date as Date, completionHandler: completionHandler)
    }
    
    public func clearCacheByDomain(domain: String, includeDiskFiles: Bool, completionHandler: @escaping () -> Void) {
        var websiteDataTypes = Set([WKWebsiteDataTypeMemoryCache])
        if includeDiskFiles {
            websiteDataTypes.insert(WKWebsiteDataTypeDiskCache)
            if #available(macOS 10.13.4, *) {
                websiteDataTypes.insert(WKWebsiteDataTypeFetchCache)
            }
            websiteDataTypes.insert(WKWebsiteDataTypeOfflineWebApplicationCache)
        }
        
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: websiteDataTypes) { (dataRecords) in
            let matchingRecords = dataRecords.filter { record in
                return record.displayName == domain || record.displayName.hasSuffix("." + domain)
            }
            
            if matchingRecords.isEmpty {
                completionHandler()
                return
            }
            
            WKWebsiteDataStore.default().removeData(ofTypes: websiteDataTypes, for: matchingRecords) {
                completionHandler()
            }
        }
    }
    
    public override func dispose() {
        super.dispose()
        let keepAliveWebViewValues = keepAliveWebViews.values
        keepAliveWebViewValues.forEach {(keepAliveWebView: FlutterWebViewController?) in
            if let keepAliveId = keepAliveWebView?.keepAliveId {
                disposeKeepAlive(keepAliveId: keepAliveId)
            }
        }
        keepAliveWebViews.removeAll()
        windowWebViews.removeAll()
        webViewForUserAgent = nil
        defaultUserAgent = nil
        plugin = nil
    }
    
    deinit {
        dispose()
    }
}
