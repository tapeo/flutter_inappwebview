//
//  InAppWebView.swift
//  flutter_inappwebview
//
//  Created by Lorenzo on 21/10/18.
//

import FlutterMacOS
import Foundation
@preconcurrency import WebKit

public class InAppWebView: WKWebView, WKUIDelegate,
                            WKNavigationDelegate, WKScriptMessageHandler,
                            WKDownloadDelegate,
                            Disposable {
    static var METHOD_CHANNEL_NAME_PREFIX = "com.pichillilorenzo/flutter_inappwebview_"

    var id: Any? // viewId
    var plugin: InAppWebViewFlutterPlugin?
    var windowId: Int64?
    var windowCreated = false
    var windowBeforeCreatedCallbacks: [() -> ()] = []
    var inAppBrowserDelegate: InAppBrowserDelegate?
    var channelDelegate: WebViewChannelDelegate?
    var settings: InAppWebViewSettings?
    var findInteractionController: FindInteractionController?
    var webMessageChannels: [String:WebMessageChannel] = [:]
    var webMessageListeners: [WebMessageListener] = []
    var currentOriginalUrl: URL?
    var inFullscreen = false
    private var printJobCompletionHandler: PrintJobController.CompletionHandler?
    private var filePathDestination: URL?
    
    static var sslCertificatesMap: [String: SslCertificate] = [:] // [URL host name : SslCertificate]
    static var credentialsProposed: [URLCredential] = []
    
    var lastScrollX: CGFloat = 0
    var lastScrollY: CGFloat = 0
    
    // Used to manage pauseTimers() and resumeTimers()
    var isPausedTimers = false
    var isPausedTimersCompletionHandler: (() -> Void)?

    var initialUserScripts: [UserScript] = []
    
    var customIMPs: [IMP] = []
    
    var callAsyncJavaScriptBelowMacOS11Results: [String:((Any?) -> Void)] = [:]
    
    var currentOpenPanel: NSOpenPanel?
    
    fileprivate var interceptOnlyAsyncAjaxRequestsPluginScript: PluginScript?
    
    private var exceptedBridgeSecret = NSUUID().uuidString
    private var javaScriptBridgeEnabled = true
    
    // 1. Add URLSession and download tracking properties to InAppWebView
    private var urlSession: URLSession?
    private var activeDownloadTasks: [URL: URLSessionDownloadTask] = [:]
    private var activeDownloadProgress: [URL: Double] = [:]
    
    public override var acceptsFirstResponder: Bool { return true }
    
    init(id: Any?, plugin: InAppWebViewFlutterPlugin?, frame: CGRect, configuration: WKWebViewConfiguration,
         userScripts: [UserScript] = []) {
        super.init(frame: frame, configuration: configuration)
        self.id = id
        self.plugin = plugin
        if let id = id, let registrar = plugin?.registrar {
            let channel = FlutterMethodChannel(name: InAppWebView.METHOD_CHANNEL_NAME_PREFIX + String(describing: id),
                                           binaryMessenger: registrar.messenger)
            self.channelDelegate = WebViewChannelDelegate(webView: self, channel: channel)
        }
        self.initialUserScripts = userScripts
        uiDelegate = self
        navigationDelegate = self
    }
    
    required public init(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)!
    }

    public func prepare() {
        addObserver(self,
                    forKeyPath: #keyPath(WKWebView.estimatedProgress),
                    options: .new,
                    context: nil)
        
        addObserver(self,
                    forKeyPath: #keyPath(WKWebView.url),
                    options: [.new, .old],
                    context: nil)
        
        addObserver(self,
            forKeyPath: #keyPath(WKWebView.title),
            options: [.new, .old],
            context: nil)
        
        if #available(macOS 12.0, *) {
            addObserver(self,
                forKeyPath: #keyPath(WKWebView.cameraCaptureState),
                options: [.new, .old],
                context: nil)
            
            addObserver(self,
                forKeyPath: #keyPath(WKWebView.microphoneCaptureState),
                options: [.new, .old],
                context: nil)
        }
        
        // TODO: Still not working on iOS 16.0!
//        if #available(iOS 16.0, *) {
//            addObserver(self,
//                        forKeyPath: #keyPath(WKWebView.fullscreenState),
//                        options: .new,
//                context: nil)
//        } else {
            // listen for videos playing in fullscreen
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(onEnterFullscreen(_:)),
                                                   name: NSWindow.didEnterFullScreenNotification,
                                                   object: window)
        
            // listen for videos stopping to play in fullscreen
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(onExitFullscreen(_:)),
                                                   name: NSWindow.didExitFullScreenNotification,
                                                   object: window)
//        }
        
        if let settings = settings {
            if let viewAlpha = settings.alpha {
                alphaValue = CGFloat(viewAlpha)
            }
            
            javaScriptBridgeEnabled = settings.javaScriptBridgeEnabled
            if let javaScriptBridgeOriginAllowList = settings.javaScriptBridgeOriginAllowList, javaScriptBridgeOriginAllowList.isEmpty {
                // an empty list means that the JavaScript Bridge is not allowed for any origin.
                javaScriptBridgeEnabled = false
            }
            
            if #available(macOS 12.0, *), settings.transparentBackground {
                underPageBackgroundColor = .clear
            }
        
            allowsBackForwardNavigationGestures = settings.allowsBackForwardNavigationGestures
            allowsLinkPreview = settings.allowsLinkPreview
            if !settings.userAgent.isEmpty {
                customUserAgent = settings.userAgent
            }

            if #available(macOS 11.0, *) {
                mediaType = settings.mediaType
                pageZoom = CGFloat(settings.pageZoom)
            }
            
            if #available(macOS 12.0, *) {
                if let underPageBackgroundColor = settings.underPageBackgroundColor, !underPageBackgroundColor.isEmpty {
                    self.underPageBackgroundColor = NSColor(hexString: underPageBackgroundColor)
                }
            }
            
            if #available(macOS 13.3, *) {
                isInspectable = settings.isInspectable
            }
            
            if settings.clearCache {
                clearCache()
            }
        }
        
        prepareAndAddUserScripts()
        
        if windowId != nil {
            // The new created window webview has the same WKWebViewConfiguration variable reference.
            // So, we cannot set another WKWebViewConfiguration for it unfortunately!
            // This is a limitation of the official WebKit API.
            return
        }
        
        configuration.preferences = WKPreferences()
        if let settings = settings {
            configuration.allowsAirPlayForMediaPlayback = settings.allowsAirPlayForMediaPlayback
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = settings.javaScriptCanOpenWindowsAutomatically
            configuration.preferences.minimumFontSize = CGFloat(settings.minimumFontSize)
            
            if #available(macOS 10.15, *) {
                configuration.preferences.isFraudulentWebsiteWarningEnabled = settings.isFraudulentWebsiteWarningEnabled
                configuration.defaultWebpagePreferences.preferredContentMode = WKWebpagePreferences.ContentMode(rawValue: settings.preferredContentMode)!
            }
            
            configuration.preferences.javaScriptEnabled = settings.javaScriptEnabled
            if #available(macOS 11.0, *) {
                configuration.defaultWebpagePreferences.allowsContentJavaScript = settings.javaScriptEnabled
            }
            if #available(macOS 11.3, *) {
                configuration.preferences.isTextInteractionEnabled = settings.isTextInteractionEnabled
            }
            if #available(macOS 12.3, *) {
                configuration.preferences.isSiteSpecificQuirksModeEnabled = settings.isSiteSpecificQuirksModeEnabled
                configuration.preferences.isElementFullscreenEnabled = settings.isElementFullscreenEnabled
            }
            if #available(macOS 13.3, *) {
                configuration.preferences.shouldPrintBackgrounds = settings.shouldPrintBackgrounds
            }
        }
    }
    
    public func prepareAndAddUserScripts() -> Void {
        if windowId != nil {
            // The new created window webview has the same WKWebViewConfiguration variable reference.
            // So, we cannot set another WKWebViewConfiguration for it unfortunately!
            // This is a limitation of the official WebKit API.
            return
        }
        configuration.userContentController.initialize()
        
        if let applePayAPIEnabled = settings?.applePayAPIEnabled, applePayAPIEnabled {
            return
        }
        
        if javaScriptBridgeEnabled {
            let pluginScriptsOriginAllowList = settings?.pluginScriptsOriginAllowList
            let pluginScriptsForMainFrameOnly = settings?.pluginScriptsForMainFrameOnly ?? true
            
            let javaScriptBridgeOriginAllowList = settings?.javaScriptBridgeOriginAllowList ?? pluginScriptsOriginAllowList
            let javaScriptBridgeForMainFrameOnly = settings?.javaScriptBridgeForMainFrameOnly ?? pluginScriptsForMainFrameOnly
            
            configuration.userContentController.addPluginScript(PromisePolyfillJS.PROMISE_POLYFILL_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList, forMainFrameOnly: pluginScriptsForMainFrameOnly))
            configuration.userContentController.addPluginScript(JavaScriptBridgeJS.JAVASCRIPT_BRIDGE_JS_PLUGIN_SCRIPT(expectedBridgeSecret: exceptedBridgeSecret, allowedOriginRules: javaScriptBridgeOriginAllowList, forMainFrameOnly: javaScriptBridgeForMainFrameOnly))
            configuration.userContentController.addPluginScript(ConsoleLogJS.CONSOLE_LOG_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList))
            configuration.userContentController.addPluginScript(PrintJS.PRINT_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList, forMainFrameOnly: pluginScriptsForMainFrameOnly))
            configuration.userContentController.addPluginScript(OnWindowBlurEventJS.ON_WINDOW_BLUR_EVENT_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList))
            configuration.userContentController.addPluginScript(OnWindowFocusEventJS.ON_WINDOW_FOCUS_EVENT_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList))
            configuration.userContentController.addPluginScript(FindElementsAtPointJS.FIND_ELEMENTS_AT_POINT_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList))
            configuration.userContentController.addPluginScript(FindTextHighlightJS.FIND_TEXT_HIGHLIGHT_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList))
            configuration.userContentController.addPluginScript(OriginalViewPortMetaTagContentJS.ORIGINAL_VIEWPORT_METATAG_CONTENT_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList))
            configuration.userContentController.addPluginScript(OnScrollChangedJS.ON_SCROLL_CHANGED_EVENT_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList))
            if let settings = settings {
                interceptOnlyAsyncAjaxRequestsPluginScript = InterceptAjaxRequestJS.createInterceptOnlyAsyncAjaxRequestsPluginScript(onlyAsync: settings.interceptOnlyAsyncAjaxRequests,
                                                                                                                                     allowedOriginRules: pluginScriptsOriginAllowList, forMainFrameOnly: pluginScriptsForMainFrameOnly)
                if settings.useShouldInterceptAjaxRequest {
                    if let interceptOnlyAsyncAjaxRequestsPluginScript = interceptOnlyAsyncAjaxRequestsPluginScript {
                        configuration.userContentController.addPluginScript(interceptOnlyAsyncAjaxRequestsPluginScript)
                    }
                    configuration.userContentController.addPluginScript(InterceptAjaxRequestJS.INTERCEPT_AJAX_REQUEST_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList,
                                                                                                                                       forMainFrameOnly: pluginScriptsForMainFrameOnly,
                                                                                                                                       initialUseOnAjaxReadyStateChange: settings.useOnAjaxReadyStateChange,
                                                                                                                                       initialUseOnAjaxProgress: settings.useOnAjaxProgress))
                }
                if settings.useShouldInterceptFetchRequest {
                    configuration.userContentController.addPluginScript(InterceptFetchRequestJS.INTERCEPT_FETCH_REQUEST_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList, forMainFrameOnly: pluginScriptsForMainFrameOnly))
                }
                if settings.useOnLoadResource {
                    configuration.userContentController.addPluginScript(OnLoadResourceJS.ON_LOAD_RESOURCE_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList, forMainFrameOnly: pluginScriptsForMainFrameOnly))
                }
                if !settings.supportZoom {
                    configuration.userContentController.addPluginScript(SupportZoomJS.NOT_SUPPORT_ZOOM_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList))
                } else if settings.enableViewportScale {
                    configuration.userContentController.addPluginScript(EnableViewportScaleJS.ENABLE_VIEWPORT_SCALE_JS_PLUGIN_SCRIPT(allowedOriginRules: pluginScriptsOriginAllowList))
                }
            }
        }
        configuration.userContentController.addUserOnlyScripts(initialUserScripts)
        configuration.userContentController.sync(scriptMessageHandler: self)
    }
    
    public static func preWKWebViewConfiguration(settings: InAppWebViewSettings?) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        // initialzie WKUserContentController here to fix possible "undefined is not an object (evaluating 'window.webkit.messageHandlers')" javascript error
        configuration.userContentController = WKUserContentController()
        configuration.processPool = WKProcessPoolManager.sharedProcessPool
        
        if let settings = settings {
            configuration.suppressesIncrementalRendering = settings.suppressesIncrementalRendering
            
            if settings.allowUniversalAccessFromFileURLs {
                configuration.setValue(settings.allowUniversalAccessFromFileURLs, forKey: "allowUniversalAccessFromFileURLs")
            }
            
            if settings.allowFileAccessFromFileURLs {
                configuration.preferences.setValue(settings.allowFileAccessFromFileURLs, forKey: "allowFileAccessFromFileURLs")
            }
            
            if settings.incognito {
                configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
            } else if let profileId = settings.profileId, !profileId.isEmpty {
                // Use profile-specific data store (iOS 17.0+/macOS 14.0+)
                if #available(macOS 14.0, *) {
                    // Try to parse as UUID, if that fails, create a UUID from the string hash
                    let uuid: UUID
                    if let parsedUuid = UUID(uuidString: profileId) {
                        uuid = parsedUuid
                    } else {
                        // Create a deterministic UUID from the string
                        uuid = UUID(uuidString: String(format: "%08x-%04x-%04x-%04x-%012x", 
                                                     profileId.hashValue,
                                                     0x1000 | (profileId.hashValue & 0x0fff),
                                                     0x8000 | (profileId.hashValue & 0x3fff),
                                                     profileId.hashValue & 0xffff,
                                                     profileId.hashValue)) ?? UUID()
                    }
                    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: uuid)
                } else {
                    // Fallback to default behavior for older versions
                    if settings.cacheEnabled {
                        configuration.websiteDataStore = WKWebsiteDataStore.default()
                    }
                }
            } else if settings.cacheEnabled {
                configuration.websiteDataStore = WKWebsiteDataStore.default()
            }
            if !settings.applicationNameForUserAgent.isEmpty {
                if let applicationNameForUserAgent = configuration.applicationNameForUserAgent {
                    configuration.applicationNameForUserAgent = applicationNameForUserAgent + " " + settings.applicationNameForUserAgent
                }
            }
            
            if #available(macOS 10.12, *) {
                configuration.mediaTypesRequiringUserActionForPlayback = settings.mediaPlaybackRequiresUserGesture ? .all : []
            }
            
            if #available(macOS 10.13, *) {
                for scheme in settings.resourceCustomSchemes {
                    configuration.setURLSchemeHandler(CustomSchemeHandler(), forURLScheme: scheme)
                }
                if settings.sharedCookiesEnabled {
                    // More info to sending cookies with WKWebView
                    // https://stackoverflow.com/questions/26573137/can-i-set-the-cookies-to-be-used-by-a-wkwebview/26577303#26577303
                    // Set Cookies in iOS 11 and above, initialize websiteDataStore before setting cookies
                    // See also https://forums.developer.apple.com/thread/97194
                    // check if websiteDataStore has not been initialized before (exclude profile and incognito cases)
                    if(!settings.incognito && !settings.cacheEnabled && (settings.profileId?.isEmpty ?? true)) {
                        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
                    }
                    for cookie in HTTPCookieStorage.shared.cookies ?? [] {
                        configuration.websiteDataStore.httpCookieStore.setCookie(cookie, completionHandler: nil)
                    }
                }
            }
            
            if #available(macOS 11.0, *) {
                configuration.limitsNavigationsToAppBoundDomains = settings.limitsNavigationsToAppBoundDomains
            }
            
            if #available(macOS 11.3, *) {
                configuration.upgradeKnownHostsToHTTPS = settings.upgradeKnownHostsToHTTPS
            }
        }
        
        return configuration
    }
    
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == #keyPath(WKWebView.estimatedProgress) {
            initializeWindowIdJS()
            let progress = Int(estimatedProgress * 100)
            channelDelegate?.onProgressChanged(progress: progress)
            inAppBrowserDelegate?.didChangeProgress(progress: estimatedProgress)
        } else if keyPath == #keyPath(WKWebView.url) && change?[.newKey] is URL {
            initializeWindowIdJS()
            let newUrl = change?[NSKeyValueChangeKey.newKey] as? URL
            channelDelegate?.onUpdateVisitedHistory(url: newUrl?.absoluteString, isReload: nil)
            inAppBrowserDelegate?.didUpdateVisitedHistory(url: newUrl)
        } else if keyPath == #keyPath(WKWebView.title) && change?[.newKey] is String {
            let newTitle = change?[.newKey] as? String
            channelDelegate?.onTitleChanged(title: newTitle)
            inAppBrowserDelegate?.didChangeTitle(title: newTitle)
        }
        else if #available(macOS 12.0, *) {
            if keyPath == #keyPath(WKWebView.cameraCaptureState) || keyPath == #keyPath(WKWebView.microphoneCaptureState) {
                var oldState: WKMediaCaptureState? = nil
                if let oldValue = change?[.oldKey] as? Int {
                    oldState = WKMediaCaptureState.init(rawValue: oldValue)
                }
                var newState: WKMediaCaptureState? = nil
                if let newValue = change?[.newKey] as? Int {
                    newState = WKMediaCaptureState.init(rawValue: newValue)
                }
                if oldState != newState {
                    if keyPath == #keyPath(WKWebView.cameraCaptureState) {
                        channelDelegate?.onCameraCaptureStateChanged(oldState: oldState, newState: newState)
                    } else {
                        channelDelegate?.onMicrophoneCaptureStateChanged(oldState: oldState, newState: newState)
                    }
                }
            }
        } else if #available(iOS 16.0, *) {
            // TODO: Still not working on iOS 16.0!
//            if keyPath == #keyPath(WKWebView.fullscreenState) {
//                if fullscreenState == .enteringFullscreen {
//                    channelDelegate?.onEnterFullscreen()
//                } else if fullscreenState == .exitingFullscreen {
//                    channelDelegate?.onExitFullscreen()
//                }
//            }
        }
    }
    
    public func initializeWindowIdJS() {
        if let windowId = windowId {
            if #available(macOS 11.0, *) {
                let contentWorlds = configuration.userContentController.getContentWorlds(with: windowId)
                for contentWorld in contentWorlds {
                    let source = WindowIdJS.WINDOW_ID_INITIALIZE_JS_SOURCE().replacingOccurrences(of: PluginScriptsUtil.VAR_PLACEHOLDER_VALUE, with: String(windowId))
                    evaluateJavascript(source: source, contentWorld: contentWorld)
                }
            } else {
                let source = WindowIdJS.WINDOW_ID_INITIALIZE_JS_SOURCE().replacingOccurrences(of: PluginScriptsUtil.VAR_PLACEHOLDER_VALUE, with: String(windowId))
                evaluateJavascript(source: source)
            }
        }
    }
    
    public func goBackOrForward(steps: Int) {
        if canGoBackOrForward(steps: steps) {
            if (steps > 0) {
                let index = steps - 1
                go(to: self.backForwardList.forwardList[index])
            }
            else if (steps < 0){
                let backListLength = self.backForwardList.backList.count
                let index = backListLength + steps
                go(to: self.backForwardList.backList[index])
            }
        }
    }
    
    public func canGoBackOrForward(steps: Int) -> Bool {
        let currentIndex = self.backForwardList.backList.count
        return (steps >= 0)
            ? steps <= self.backForwardList.forwardList.count
            : currentIndex + steps >= 0
    }
    
    @available(macOS 10.13, *)
    public func takeScreenshot (with: [String: Any?]?, completionHandler: @escaping (_ screenshot: Data?) -> Void) {
        var snapshotConfiguration: WKSnapshotConfiguration? = nil
        if let with = with {
            snapshotConfiguration = WKSnapshotConfiguration()
            if let rect = with["rect"] as? [String: Double] {
                snapshotConfiguration!.rect = CGRect.fromMap(map: rect)
            }
            if let snapshotWidth = with["snapshotWidth"] as? Double {
                snapshotConfiguration!.snapshotWidth = NSNumber(value: snapshotWidth)
            }
            if #available(macOS 10.15, *), let afterScreenUpdates = with["afterScreenUpdates"] as? Bool {
                snapshotConfiguration!.afterScreenUpdates = afterScreenUpdates
            }
        }
        takeSnapshot(with: snapshotConfiguration, completionHandler: {(image, error) -> Void in
            var imageData: Data? = nil
            if let screenshot = image, let cgImage = screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let newRep = NSBitmapImageRep(cgImage: cgImage)
                if let with = with {
                    switch with["compressFormat"] as! String {
                    case "JPEG":
                        let quality = Float(with["quality"] as! Int) / 100
                        imageData = newRep.representation(using: .jpeg, properties: [
                            NSBitmapImageRep.PropertyKey.compressionFactor:quality])
                        break
                    case "PNG":
                        imageData = newRep.representation(using: .png, properties: [:])
                        break
                    default:
                        imageData = newRep.representation(using: .png, properties: [:])
                    }
                }
                else {
                    imageData = newRep.representation(using: .png, properties: [:])
                }
            }
            completionHandler(imageData)
        })
    }
    
    @available(macOS 11.0, *)
    public func createPdf (configuration: [String: Any?]?, completionHandler: @escaping (_ pdf: Data?) -> Void) {
        let pdfConfiguration: WKPDFConfiguration = .init()
        if let configuration = configuration {
            if let rect = configuration["rect"] as? [String: Double] {
                pdfConfiguration.rect = CGRect.fromMap(map: rect)
            }
        }
        createPDF(configuration: pdfConfiguration) { (result) in
            switch (result) {
            case .success(let data):
                completionHandler(data)
                return
            case .failure(let error):
                print(error.localizedDescription)
                completionHandler(nil)
                return
            }
        }
    }
    
    @available(macOS 11.0, *)
    public func createWebArchiveData (dataCompletionHandler: @escaping (_ webArchiveData: Data?) -> Void) {
        createWebArchiveData(completionHandler: { (result) in
            switch (result) {
            case .success(let data):
                dataCompletionHandler(data)
                return
            case .failure(let error):
                print(error.localizedDescription)
                dataCompletionHandler(nil)
                return
            }
        })
    }
    
    @available(macOS 11.0, *)
    public func saveWebArchive (filePath: String, autoname: Bool, completionHandler: @escaping (_ path: String?) -> Void) {
        createWebArchiveData(dataCompletionHandler: { (webArchiveData) in
            if let webArchiveData = webArchiveData {
                var localUrl = URL(fileURLWithPath: filePath)
                if autoname {
                    if let url = self.url {
                        // tries to mimic Android saveWebArchive method
                        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
                                    .union(.newlines)
                                    .union(.illegalCharacters)
                                    .union(.controlCharacters)
                                
                        let currentPageUrlFileName = url.path
                            .components(separatedBy: invalidCharacters)
                            .joined(separator: "")
                        
                        let fullPath = filePath + "/" + currentPageUrlFileName + ".webarchive"
                        localUrl = URL(fileURLWithPath: fullPath)
                    } else {
                        completionHandler(nil)
                        return
                    }
                }
                do {
                    try webArchiveData.write(to: localUrl)
                    completionHandler(localUrl.path)
                } catch {
                    // Catch any errors
                    print(error.localizedDescription)
                    completionHandler(nil)
                }
            } else {
                completionHandler(nil)
            }
        })
    }
    
    public func loadUrl(urlRequest: URLRequest, allowingReadAccessTo: URL?) {
        let url = urlRequest.url!
        
        if let allowingReadAccessTo = allowingReadAccessTo, url.scheme == "file", allowingReadAccessTo.scheme == "file" {
            loadFileURL(url, allowingReadAccessTo: allowingReadAccessTo)
        } else {
            load(urlRequest)
        }
    }
    
    public func postUrl(url: URL, postData: Data) {
        var request = URLRequest(url: url)
        
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        request.httpBody = postData
        load(request)
    }
    
    public func loadData(data: String, mimeType: String, encoding: String, baseUrl: URL, allowingReadAccessTo: URL?) {
        if let allowingReadAccessTo = allowingReadAccessTo, baseUrl.scheme == "file", allowingReadAccessTo.scheme == "file" {
            loadFileURL(baseUrl, allowingReadAccessTo: allowingReadAccessTo)
        }
        load(data.data(using: .utf8)!, mimeType: mimeType, characterEncodingName: encoding, baseURL: baseUrl)
    }
    
    public func loadFile(assetFilePath: String) throws {
        let assetURL = try Util.getUrlAsset(assetFilePath: assetFilePath)
        let urlRequest = URLRequest(url: assetURL)
        loadUrl(urlRequest: urlRequest, allowingReadAccessTo: nil)
    }
    
    func setSettings(newSettings: InAppWebViewSettings, newSettingsMap: [String: Any]) {
        
        // MUST be the first! In this way, all the settings that uses evaluateJavaScript can be applied/blocked!
        if newSettingsMap["applePayAPIEnabled"] != nil && settings?.applePayAPIEnabled != newSettings.applePayAPIEnabled {
            if let settings = settings {
                settings.applePayAPIEnabled = newSettings.applePayAPIEnabled
            }
            if !newSettings.applePayAPIEnabled {
                // re-add WKUserScripts for the next page load
                prepareAndAddUserScripts()
            } else {
                configuration.userContentController.removeAllUserScripts()
            }
        }
        
        if newSettingsMap["alpha"] != nil, settings?.alpha != newSettings.alpha, let viewAlpha = newSettings.alpha {
            alphaValue = CGFloat(viewAlpha)
        }
        
        if (newSettingsMap["incognito"] != nil && settings?.incognito != newSettings.incognito && newSettings.incognito) {
            configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        } else if (newSettingsMap["cacheEnabled"] != nil && settings?.cacheEnabled != newSettings.cacheEnabled && newSettings.cacheEnabled) {
            configuration.websiteDataStore = WKWebsiteDataStore.default()
        }
        
        // Handle profile changes
        if newSettingsMap["profileId"] != nil && settings?.profileId != newSettings.profileId {
            if let profileId = newSettings.profileId, !profileId.isEmpty && !newSettings.incognito {
                if #available(macOS 14.0, *) {
                    // Try to parse as UUID, if that fails, create a UUID from the string hash
                    let uuid: UUID
                    if let parsedUuid = UUID(uuidString: profileId) {
                        uuid = parsedUuid
                    } else {
                        // Create a deterministic UUID from the string
                        uuid = UUID(uuidString: String(format: "%08x-%04x-%04x-%04x-%012x", 
                                                     profileId.hashValue,
                                                     0x1000 | (profileId.hashValue & 0x0fff),
                                                     0x8000 | (profileId.hashValue & 0x3fff),
                                                     profileId.hashValue & 0xffff,
                                                     profileId.hashValue)) ?? UUID()
                    }
                    configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: uuid)
                } else {
                    // Fallback to default behavior for older versions when profile not available
                    if newSettings.cacheEnabled {
                        configuration.websiteDataStore = WKWebsiteDataStore.default()
                    }
                }
            } else if !newSettings.incognito {
                // When profileId is null/empty, use default cache behavior
                if newSettings.cacheEnabled {
                    configuration.websiteDataStore = WKWebsiteDataStore.default()
                }
                // If cacheEnabled is false and not incognito, we don't set a data store (uses default)
            }
        }
        
        if #available(macOS 10.13, *) {
            if (newSettingsMap["sharedCookiesEnabled"] != nil && settings?.sharedCookiesEnabled != newSettings.sharedCookiesEnabled && newSettings.sharedCookiesEnabled) {
                if(!newSettings.incognito && !newSettings.cacheEnabled && (newSettings.profileId?.isEmpty ?? true)) {
                    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
                }
                for cookie in HTTPCookieStorage.shared.cookies ?? [] {
                    configuration.websiteDataStore.httpCookieStore.setCookie(cookie, completionHandler: nil)
                }
            }
        }
        
        if newSettingsMap["enableViewportScale"] != nil && settings?.enableViewportScale != newSettings.enableViewportScale {
            if !newSettings.enableViewportScale {
                if configuration.userContentController.containsPluginScript(with: EnableViewportScaleJS.ENABLE_VIEWPORT_SCALE_JS_PLUGIN_SCRIPT_GROUP_NAME) {
                    configuration.userContentController.removePluginScripts(with: EnableViewportScaleJS.ENABLE_VIEWPORT_SCALE_JS_PLUGIN_SCRIPT_GROUP_NAME, shouldAddPreviousScripts: false)
                    evaluateJavaScript(EnableViewportScaleJS.NOT_ENABLE_VIEWPORT_SCALE_JS_SOURCE())
                }
            } else {
                evaluateJavaScript(EnableViewportScaleJS.ENABLE_VIEWPORT_SCALE_JS_SOURCE)
                if javaScriptBridgeEnabled {
                    configuration.userContentController.addPluginScript(EnableViewportScaleJS.ENABLE_VIEWPORT_SCALE_JS_PLUGIN_SCRIPT(allowedOriginRules: newSettings.pluginScriptsOriginAllowList))
                }
            }
        }
        
        if newSettingsMap["supportZoom"] != nil && settings?.supportZoom != newSettings.supportZoom {
            if newSettings.supportZoom {
                if configuration.userContentController.containsPluginScript(with: SupportZoomJS.NOT_SUPPORT_ZOOM_JS_PLUGIN_SCRIPT_GROUP_NAME) {
                    configuration.userContentController.removePluginScripts(with: SupportZoomJS.NOT_SUPPORT_ZOOM_JS_PLUGIN_SCRIPT_GROUP_NAME, shouldAddPreviousScripts: false)
                    evaluateJavaScript(SupportZoomJS.SUPPORT_ZOOM_JS_SOURCE())
                }
            } else {
                evaluateJavaScript(SupportZoomJS.NOT_SUPPORT_ZOOM_JS_SOURCE)
                if javaScriptBridgeEnabled {
                    configuration.userContentController.addPluginScript(SupportZoomJS.NOT_SUPPORT_ZOOM_JS_PLUGIN_SCRIPT(allowedOriginRules: newSettings.pluginScriptsOriginAllowList))
                }
            }
        }
        
        if newSettingsMap["useOnLoadResource"] != nil && settings?.useOnLoadResource != newSettings.useOnLoadResource {
            if let applePayAPIEnabled = settings?.applePayAPIEnabled, !applePayAPIEnabled {
                if javaScriptBridgeEnabled {
                    enablePluginScriptAtRuntime(flagVariable: OnLoadResourceJS.FLAG_VARIABLE_FOR_ON_LOAD_RESOURCE_JS_SOURCE(),
                                                enable: newSettings.useOnLoadResource,
                                                pluginScript: OnLoadResourceJS.ON_LOAD_RESOURCE_JS_PLUGIN_SCRIPT(allowedOriginRules: newSettings.pluginScriptsOriginAllowList,
                                                                                                                 forMainFrameOnly: newSettings.pluginScriptsForMainFrameOnly))
                }
            } else {
                newSettings.useOnLoadResource = false
            }
        }
        
        if newSettingsMap["useShouldInterceptAjaxRequest"] != nil && settings?.useShouldInterceptAjaxRequest != newSettings.useShouldInterceptAjaxRequest {
            if let applePayAPIEnabled = settings?.applePayAPIEnabled, !applePayAPIEnabled {
                if javaScriptBridgeEnabled {
                    enablePluginScriptAtRuntime(flagVariable: InterceptAjaxRequestJS.FLAG_VARIABLE_FOR_SHOULD_INTERCEPT_AJAX_REQUEST_JS_SOURCE(),
                                                enable: newSettings.useShouldInterceptAjaxRequest,
                                                pluginScript: InterceptAjaxRequestJS.INTERCEPT_AJAX_REQUEST_JS_PLUGIN_SCRIPT(allowedOriginRules: newSettings.pluginScriptsOriginAllowList,
                                                                                                                             forMainFrameOnly: newSettings.pluginScriptsForMainFrameOnly,
                                                                                                                             initialUseOnAjaxReadyStateChange: newSettings.useOnAjaxReadyStateChange,
                                                                                                                             initialUseOnAjaxProgress: newSettings.useOnAjaxProgress))
                }
            } else {
                newSettings.useShouldInterceptAjaxRequest = false
            }
        }
        
        if newSettingsMap["useOnAjaxReadyStateChange"] != nil && settings?.useOnAjaxReadyStateChange != newSettings.useOnAjaxReadyStateChange {
            if let applePayAPIEnabled = settings?.applePayAPIEnabled, !applePayAPIEnabled {
                if javaScriptBridgeEnabled {
                    evaluateJavaScript("\(InterceptAjaxRequestJS.FLAG_VARIABLE_FOR_ON_AJAX_READY_STATE_CHANGE()) = \(newSettings.useOnAjaxReadyStateChange);")
                }
            } else {
                newSettings.useOnAjaxReadyStateChange = false
            }
        }
        
        if newSettingsMap["useOnAjaxProgress"] != nil && settings?.useOnAjaxProgress != newSettings.useOnAjaxProgress {
            if let applePayAPIEnabled = settings?.applePayAPIEnabled, !applePayAPIEnabled {
                if javaScriptBridgeEnabled {
                    evaluateJavaScript("\(InterceptAjaxRequestJS.FLAG_VARIABLE_FOR_ON_AJAX_PROGRESS()) = \(newSettings.useOnAjaxProgress);")
                }
            } else {
                newSettings.useOnAjaxProgress = false
            }
        }
        
        if newSettingsMap["interceptOnlyAsyncAjaxRequests"] != nil && settings?.interceptOnlyAsyncAjaxRequests != newSettings.interceptOnlyAsyncAjaxRequests {
            if let applePayAPIEnabled = settings?.applePayAPIEnabled, !applePayAPIEnabled,
               let interceptOnlyAsyncAjaxRequestsPluginScript = interceptOnlyAsyncAjaxRequestsPluginScript {
                if javaScriptBridgeEnabled {
                    enablePluginScriptAtRuntime(flagVariable: InterceptAjaxRequestJS.FLAG_VARIABLE_FOR_INTERCEPT_ONLY_ASYNC_AJAX_REQUESTS_JS_SOURCE(),
                                                enable: newSettings.interceptOnlyAsyncAjaxRequests,
                                                pluginScript: interceptOnlyAsyncAjaxRequestsPluginScript)
                }
            }
        }
        
        if newSettingsMap["useShouldInterceptFetchRequest"] != nil && settings?.useShouldInterceptFetchRequest != newSettings.useShouldInterceptFetchRequest {
            if let applePayAPIEnabled = settings?.applePayAPIEnabled, !applePayAPIEnabled {
                if javaScriptBridgeEnabled {
                    enablePluginScriptAtRuntime(flagVariable: InterceptFetchRequestJS.FLAG_VARIABLE_FOR_SHOULD_INTERCEPT_FETCH_REQUEST_JS_SOURCE(),
                                                enable: newSettings.useShouldInterceptFetchRequest,
                                                pluginScript: InterceptFetchRequestJS.INTERCEPT_FETCH_REQUEST_JS_PLUGIN_SCRIPT(allowedOriginRules: newSettings.pluginScriptsOriginAllowList,
                                                                                                                               forMainFrameOnly: newSettings.pluginScriptsForMainFrameOnly))
                }
            } else {
                newSettings.useShouldInterceptFetchRequest = false
            }
        }
        
        if newSettingsMap["mediaPlaybackRequiresUserGesture"] != nil && settings?.mediaPlaybackRequiresUserGesture != newSettings.mediaPlaybackRequiresUserGesture {
            if #available(macOS 10.12, *) {
                configuration.mediaTypesRequiringUserActionForPlayback = (newSettings.mediaPlaybackRequiresUserGesture) ? .all : []
            }
        }
        
        if newSettingsMap["suppressesIncrementalRendering"] != nil && settings?.suppressesIncrementalRendering != newSettings.suppressesIncrementalRendering {
            configuration.suppressesIncrementalRendering = newSettings.suppressesIncrementalRendering
        }
        
        if newSettingsMap["allowsBackForwardNavigationGestures"] != nil && settings?.allowsBackForwardNavigationGestures != newSettings.allowsBackForwardNavigationGestures {
            allowsBackForwardNavigationGestures = newSettings.allowsBackForwardNavigationGestures
        }
        
        if newSettingsMap["javaScriptCanOpenWindowsAutomatically"] != nil && settings?.javaScriptCanOpenWindowsAutomatically != newSettings.javaScriptCanOpenWindowsAutomatically {
            configuration.preferences.javaScriptCanOpenWindowsAutomatically = newSettings.javaScriptCanOpenWindowsAutomatically
        }
        
        if newSettingsMap["minimumFontSize"] != nil && settings?.minimumFontSize != newSettings.minimumFontSize {
            configuration.preferences.minimumFontSize = CGFloat(newSettings.minimumFontSize)
        }
        
        if #available(macOS 10.15, *) {
            if newSettingsMap["isFraudulentWebsiteWarningEnabled"] != nil && settings?.isFraudulentWebsiteWarningEnabled != newSettings.isFraudulentWebsiteWarningEnabled {
                configuration.preferences.isFraudulentWebsiteWarningEnabled = newSettings.isFraudulentWebsiteWarningEnabled
            }
            if newSettingsMap["preferredContentMode"] != nil && settings?.preferredContentMode != newSettings.preferredContentMode {
                configuration.defaultWebpagePreferences.preferredContentMode = WKWebpagePreferences.ContentMode(rawValue: newSettings.preferredContentMode)!
            }
        }
        
        if newSettingsMap["allowsLinkPreview"] != nil && settings?.allowsLinkPreview != newSettings.allowsLinkPreview {
            allowsLinkPreview = newSettings.allowsLinkPreview
        }
        if newSettingsMap["allowsAirPlayForMediaPlayback"] != nil && settings?.allowsAirPlayForMediaPlayback != newSettings.allowsAirPlayForMediaPlayback {
            configuration.allowsAirPlayForMediaPlayback = newSettings.allowsAirPlayForMediaPlayback
        }
        if newSettingsMap["applicationNameForUserAgent"] != nil && settings?.applicationNameForUserAgent != newSettings.applicationNameForUserAgent && newSettings.applicationNameForUserAgent != "" {
            configuration.applicationNameForUserAgent = newSettings.applicationNameForUserAgent
        }
        if newSettingsMap["userAgent"] != nil && settings?.userAgent != newSettings.userAgent && newSettings.userAgent != "" {
            customUserAgent = newSettings.userAgent
        }
        
        if newSettingsMap["allowUniversalAccessFromFileURLs"] != nil && settings?.allowUniversalAccessFromFileURLs != newSettings.allowUniversalAccessFromFileURLs {
            configuration.setValue(newSettings.allowUniversalAccessFromFileURLs, forKey: "allowUniversalAccessFromFileURLs")
        }
        
        if newSettingsMap["allowFileAccessFromFileURLs"] != nil && settings?.allowFileAccessFromFileURLs != newSettings.allowFileAccessFromFileURLs {
            configuration.preferences.setValue(newSettings.allowFileAccessFromFileURLs, forKey: "allowFileAccessFromFileURLs")
        }
        
        if newSettingsMap["clearCache"] != nil && newSettings.clearCache {
            clearCache()
        }
        
        if newSettingsMap["javaScriptEnabled"] != nil && settings?.javaScriptEnabled != newSettings.javaScriptEnabled {
            configuration.preferences.javaScriptEnabled = newSettings.javaScriptEnabled
        }
        
        if #available(macOS 11.0, *) {
            if settings?.mediaType != newSettings.mediaType {
                mediaType = newSettings.mediaType
            }
            
            if newSettingsMap["pageZoom"] != nil && settings?.pageZoom != newSettings.pageZoom {
                pageZoom = CGFloat(newSettings.pageZoom)
            }
            
            if newSettingsMap["limitsNavigationsToAppBoundDomains"] != nil && settings?.limitsNavigationsToAppBoundDomains != newSettings.limitsNavigationsToAppBoundDomains {
                configuration.limitsNavigationsToAppBoundDomains = newSettings.limitsNavigationsToAppBoundDomains
            }
            
            if newSettingsMap["javaScriptEnabled"] != nil && settings?.javaScriptEnabled != newSettings.javaScriptEnabled {
                configuration.defaultWebpagePreferences.allowsContentJavaScript = newSettings.javaScriptEnabled
            }
        }
        
        if #available(macOS 10.13, *), newSettingsMap["contentBlockers"] != nil {
            configuration.userContentController.removeAllContentRuleLists()
            let contentBlockers = newSettings.contentBlockers
            if contentBlockers.count > 0 {
                ContentBlockerManager.shared.getOrCompileRuleList(contentBlockers: contentBlockers) { (contentRuleList, error) in
                    if let error = error {
                        print("ContentBlocker compilation error: \(error.localizedDescription)")
                        return
                    }
                    
                    if let contentRuleList = contentRuleList {
                        self.configuration.userContentController.add(contentRuleList)
                    }
                }
            }
        }
        
        if #available(macOS 11.3, *) {
            if newSettingsMap["upgradeKnownHostsToHTTPS"] != nil && settings?.upgradeKnownHostsToHTTPS != newSettings.upgradeKnownHostsToHTTPS {
                configuration.upgradeKnownHostsToHTTPS = newSettings.upgradeKnownHostsToHTTPS
            }
            if newSettingsMap["isTextInteractionEnabled"] != nil && settings?.isTextInteractionEnabled != newSettings.isTextInteractionEnabled {
                configuration.preferences.isTextInteractionEnabled = newSettings.isTextInteractionEnabled
            }
        }
        
        if #available(macOS 12.0, *) {
            if newSettingsMap["underPageBackgroundColor"] != nil, settings?.underPageBackgroundColor != newSettings.underPageBackgroundColor,
               let underPageBackgroundColor = newSettings.underPageBackgroundColor, !underPageBackgroundColor.isEmpty {
                self.underPageBackgroundColor = NSColor(hexString: underPageBackgroundColor)
            }
        }
        if #available(macOS 12.3, *) {
            if newSettingsMap["isSiteSpecificQuirksModeEnabled"] != nil, settings?.isSiteSpecificQuirksModeEnabled != newSettings.isSiteSpecificQuirksModeEnabled {
                configuration.preferences.isSiteSpecificQuirksModeEnabled = newSettings.isSiteSpecificQuirksModeEnabled
            }
        }
        if #available(macOS 13.3, *) {
            if newSettingsMap["isInspectable"] != nil, settings?.isInspectable != newSettings.isInspectable {
                isInspectable = newSettings.isInspectable
            }
            if newSettingsMap["shouldPrintBackgrounds"] != nil, settings?.shouldPrintBackgrounds != newSettings.shouldPrintBackgrounds {
                configuration.preferences.shouldPrintBackgrounds = newSettings.shouldPrintBackgrounds
            }
        }

        self.settings = newSettings
    }
    
    func getSettings() -> [String: Any?]? {
        if (self.settings == nil) {
            return nil
        }
        return self.settings!.getRealSettings(obj: self)
    }
    
    public func enablePluginScriptAtRuntime(flagVariable: String, enable: Bool, pluginScript: PluginScript) {
        evaluateJavascript(source: flagVariable) { (alreadyLoaded) in
            if let alreadyLoaded = alreadyLoaded as? Bool, alreadyLoaded {
                let enableSource = "\(flagVariable) = \(enable);"
                if #available(macOS 11.0, *), pluginScript.requiredInAllContentWorlds {
                    for contentWorld in self.configuration.userContentController.contentWorlds {
                        self.evaluateJavaScript(enableSource, frame: nil, contentWorld: contentWorld, completionHandler: nil)
                    }
                } else {
                    self.evaluateJavaScript(enableSource, completionHandler: nil)
                }
                if !enable {
                    self.configuration.userContentController.removePluginScripts(with: pluginScript.groupName!)
                }
            }
            else if enable {
                if #available(macOS 11.0, *), pluginScript.requiredInAllContentWorlds {
                    for contentWorld in self.configuration.userContentController.contentWorlds {
                        self.evaluateJavaScript(pluginScript.source, frame: nil, contentWorld: contentWorld, completionHandler: nil)
                        self.configuration.userContentController.addPluginScript(pluginScript)
                    }
                } else {
                    self.evaluateJavaScript(pluginScript.source, completionHandler: nil)
                    self.configuration.userContentController.addPluginScript(pluginScript)
                }
                self.configuration.userContentController.sync(scriptMessageHandler: self)
            }
        }
    }
    
    @available(*, deprecated, message: "Use InAppWebViewManager.clearAllCache instead.")
    public func clearCache() {
        let date = NSDate(timeIntervalSince1970: 0)
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: date as Date, completionHandler:{ })
    }
    
    public func injectDeferredObject(source: String, withWrapper jsWrapper: String?, completionHandler: ((Any?) -> Void)? = nil) {
        var jsToInject = source
        if let wrapper = jsWrapper {
            let jsonData: Data? = try? JSONSerialization.data(withJSONObject: [source], options: [])
            let sourceArrayString = String(data: jsonData!, encoding: .utf8)
            let sourceString: String? = (sourceArrayString! as NSString).substring(with: NSRange(location: 1, length: (sourceArrayString?.count ?? 0) - 2))
            jsToInject = String(format: wrapper, sourceString!)
        }
        
        evaluateJavaScript(jsToInject) { (value, error) in
            guard let completionHandler = completionHandler else {
                return
            }
            
            if let error = error {
                let userInfo = (error as NSError).userInfo
                let errorMessage = userInfo["WKJavaScriptExceptionMessage"] ??
                                   userInfo["NSLocalizedDescription"] as? String ??
                                   error.localizedDescription
                self.channelDelegate?.onConsoleMessage(message: String(describing: errorMessage), messageLevel: 3)
            }
            
            if value == nil {
                completionHandler(nil)
                return
            }
            
            completionHandler(value)
        }
    }
    
    @available(macOS 11.0, *)
    public func injectDeferredObject(source: String, contentWorld: WKContentWorld, withWrapper jsWrapper: String?, completionHandler: ((Any?) -> Void)? = nil) {
        var jsToInject = source
        if let wrapper = jsWrapper {
            let jsonData: Data? = try? JSONSerialization.data(withJSONObject: [source], options: [])
            let sourceArrayString = String(data: jsonData!, encoding: .utf8)
            let sourceString: String? = (sourceArrayString! as NSString).substring(with: NSRange(location: 1, length: (sourceArrayString?.count ?? 0) - 2))
            jsToInject = String(format: wrapper, sourceString!)
        }
        
        jsToInject = configuration.userContentController.generateCodeForScriptEvaluation(scriptMessageHandler: self, source: jsToInject, contentWorld: contentWorld)
        
        evaluateJavaScript(jsToInject, frame: nil, contentWorld: contentWorld) { (evalResult) in
            guard let completionHandler = completionHandler else {
                return
            }
            
            switch (evalResult) {
            case .success(let value):
                completionHandler(value)
                return
            case .failure(let error):
                let userInfo = (error as NSError).userInfo
                let errorMessage = userInfo["WKJavaScriptExceptionMessage"] ??
                                   userInfo["NSLocalizedDescription"] as? String ??
                                   error.localizedDescription
                self.channelDelegate?.onConsoleMessage(message: String(describing: errorMessage), messageLevel: 3)
                break
            }
            
            completionHandler(nil)
        }
    }
    
#if compiler(>=6.0)
    public override func evaluateJavaScript(_ javaScriptString: String, completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil) {
        if let applePayAPIEnabled = settings?.applePayAPIEnabled, applePayAPIEnabled {
            if let completionHandler = completionHandler {
                completionHandler(nil, nil)
            }
            return
        }
        super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
    }
#else
    public override func evaluateJavaScript(_ javaScriptString: String, completionHandler: ((Any?, Error?) -> Void)? = nil) {
        if let applePayAPIEnabled = settings?.applePayAPIEnabled, applePayAPIEnabled {
            if let completionHandler = completionHandler {
                completionHandler(nil, nil)
            }
            return
        }
        super.evaluateJavaScript(javaScriptString, completionHandler: completionHandler)
    }
#endif
    
    @available(macOS 11.0, *)
    public func evaluateJavaScript(_ javaScript: String, frame: WKFrameInfo? = nil, contentWorld: WKContentWorld, completionHandler: ((Result<Any, Error>) -> Void)? = nil) {
        if let applePayAPIEnabled = settings?.applePayAPIEnabled, applePayAPIEnabled {
            return
        }
        super.evaluateJavaScript(javaScript, in: frame, in: contentWorld, completionHandler: completionHandler)
    }
    
    public func evaluateJavascript(source: String, completionHandler: ((Any?) -> Void)? = nil) {
        injectDeferredObject(source: source, withWrapper: nil, completionHandler: completionHandler)
    }
    
    @available(macOS 11.0, *)
    public func evaluateJavascript(source: String, contentWorld: WKContentWorld, completionHandler: ((Any?) -> Void)? = nil) {
        injectDeferredObject(source: source, contentWorld: contentWorld, withWrapper: nil, completionHandler: completionHandler)
    }
    
    @available(macOS 11.0, *)
    public func callAsyncJavaScript(_ functionBody: String, arguments: [String : Any] = [:], frame: WKFrameInfo? = nil, contentWorld: WKContentWorld, completionHandler: ((Result<Any, Error>) -> Void)? = nil) {
        if let applePayAPIEnabled = settings?.applePayAPIEnabled, applePayAPIEnabled {
            return
        }
        super.callAsyncJavaScript(functionBody, arguments: arguments, in: frame, in: contentWorld, completionHandler: completionHandler)
    }
    
    @available(macOS 11.0, *)
    public func callAsyncJavaScript(functionBody: String, arguments: [String:Any], contentWorld: WKContentWorld, completionHandler: ((Any?) -> Void)? = nil) {
        let jsToInject = configuration.userContentController.generateCodeForScriptEvaluation(scriptMessageHandler: self, source: functionBody, contentWorld: contentWorld)
        
        callAsyncJavaScript(jsToInject, arguments: arguments, frame: nil, contentWorld: contentWorld) { (evalResult) in
            guard let completionHandler = completionHandler else {
                return
            }
            
            var body: [String: Any?] = [
                "value": nil,
                "error": nil
            ]
            
            switch (evalResult) {
            case .success(let value):
                body["value"] = value
                break
            case .failure(let error):
                let userInfo = (error as NSError).userInfo
                body["error"] = userInfo["WKJavaScriptExceptionMessage"] ??
                                userInfo["NSLocalizedDescription"] as? String ??
                                error.localizedDescription
                self.channelDelegate?.onConsoleMessage(message: String(describing: body["error"]), messageLevel: 3)
                break
            }
            
            completionHandler(body)
        }
    }
    
    public func callAsyncJavaScript(functionBody: String, arguments: [String:Any], completionHandler: ((Any?) -> Void)? = nil) {
        if let applePayAPIEnabled = settings?.applePayAPIEnabled, applePayAPIEnabled {
            completionHandler?(nil)
        }
        
        var jsToInject = functionBody
        
        let resultUuid = NSUUID().uuidString
        if let completionHandler = completionHandler {
            callAsyncJavaScriptBelowMacOS11Results[resultUuid] = completionHandler
        }
        
        var functionArgumentNamesList: [String] = []
        var functionArgumentValuesList: [String] = []
        let keys = arguments.keys
        keys.forEach { (key) in
            functionArgumentNamesList.append(key)
            functionArgumentValuesList.append("obj.\(key)")
        }
        
        let functionArgumentNames = functionArgumentNamesList.joined(separator: ", ")
        let functionArgumentValues = functionArgumentValuesList.joined(separator: ", ")
        
        jsToInject = CallAsyncJavaScriptBelowIOS14WrapperJS.CALL_ASYNC_JAVASCRIPT_BELOW_IOS_14_WRAPPER_JS()
            .replacingOccurrences(of: PluginScriptsUtil.VAR_FUNCTION_ARGUMENT_NAMES, with: functionArgumentNames)
            .replacingOccurrences(of: PluginScriptsUtil.VAR_FUNCTION_ARGUMENT_VALUES, with: functionArgumentValues)
            .replacingOccurrences(of: PluginScriptsUtil.VAR_FUNCTION_ARGUMENTS_OBJ, with: Util.JSONStringify(value: arguments))
            .replacingOccurrences(of: PluginScriptsUtil.VAR_FUNCTION_BODY, with: jsToInject)
            .replacingOccurrences(of: PluginScriptsUtil.VAR_RESULT_UUID, with: resultUuid)
        
        evaluateJavaScript(jsToInject) { (value, error) in
            if let error = error {
                let userInfo = (error as NSError).userInfo
                let errorMessage = userInfo["WKJavaScriptExceptionMessage"] ??
                                   userInfo["NSLocalizedDescription"] as? String ??
                                   error.localizedDescription
                self.channelDelegate?.onConsoleMessage(message: String(describing: errorMessage), messageLevel: 3)
                completionHandler?(nil)
                self.callAsyncJavaScriptBelowMacOS11Results.removeValue(forKey: resultUuid)
            }
        }
    }
    
    public func injectJavascriptFileFromUrl(urlFile: String, scriptHtmlTagAttributes: [String:Any?]?) {
        var scriptAttributes = ""
        if let scriptHtmlTagAttributes = scriptHtmlTagAttributes {
            if let typeAttr = scriptHtmlTagAttributes["type"] as? String {
                scriptAttributes += " script.type = '\(typeAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
            if let idAttr = scriptHtmlTagAttributes["id"] as? String {
                let scriptIdEscaped = idAttr.replacingOccurrences(of: "\'", with: "\\'")
                scriptAttributes += " script.id = '\(scriptIdEscaped)'; "
                scriptAttributes += """
                script.onload = function() {
                    if (window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME()) != null) {
                        window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME()).callHandler('onInjectedScriptLoaded', '\(scriptIdEscaped)');
                    }
                };
                """
                scriptAttributes += """
                script.onerror = function() {
                    if (window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME()) != null) {
                        window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME()).callHandler('onInjectedScriptError', '\(scriptIdEscaped)');
                    }
                };
                """
            }
            if let asyncAttr = scriptHtmlTagAttributes["async"] as? Bool, asyncAttr {
                scriptAttributes += " script.async = true; "
            }
            if let deferAttr = scriptHtmlTagAttributes["defer"] as? Bool, deferAttr {
                scriptAttributes += " script.defer = true; "
            }
            if let crossOriginAttr = scriptHtmlTagAttributes["crossOrigin"] as? String {
                scriptAttributes += " script.crossOrigin = '\(crossOriginAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
            if let integrityAttr = scriptHtmlTagAttributes["integrity"] as? String {
                scriptAttributes += " script.integrity = '\(integrityAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
            if let noModuleAttr = scriptHtmlTagAttributes["noModule"] as? Bool, noModuleAttr {
                scriptAttributes += " script.noModule = true; "
            }
            if let nonceAttr = scriptHtmlTagAttributes["nonce"] as? String {
                scriptAttributes += " script.nonce = '\(nonceAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
            if let referrerPolicyAttr = scriptHtmlTagAttributes["referrerPolicy"] as? String {
                scriptAttributes += " script.referrerPolicy = '\(referrerPolicyAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
        }
        let jsWrapper = "(function(d) { var script = d.createElement('script'); \(scriptAttributes) script.src = %@; d.body.appendChild(script); })(document);"
        injectDeferredObject(source: urlFile, withWrapper: jsWrapper, completionHandler: nil)
    }
    
    public func injectCSSCode(source: String) {
        let jsWrapper = "(function(d) { var style = d.createElement('style'); style.innerHTML = %@; d.head.appendChild(style); })(document);"
        injectDeferredObject(source: source, withWrapper: jsWrapper, completionHandler: nil)
    }
    
    public func injectCSSFileFromUrl(urlFile: String, cssLinkHtmlTagAttributes: [String:Any?]?) {
        var cssLinkAttributes = ""
        var alternateStylesheet = ""
        if let cssLinkHtmlTagAttributes = cssLinkHtmlTagAttributes {
            if let idAttr = cssLinkHtmlTagAttributes["id"] as? String {
                cssLinkAttributes += " link.id = '\(idAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
            if let mediaAttr = cssLinkHtmlTagAttributes["media"] as? String {
                cssLinkAttributes += " link.media = '\(mediaAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
            if let crossOriginAttr = cssLinkHtmlTagAttributes["crossOrigin"] as? String {
                cssLinkAttributes += " link.crossOrigin = '\(crossOriginAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
            if let integrityAttr = cssLinkHtmlTagAttributes["integrity"] as? String {
                cssLinkAttributes += " link.integrity = '\(integrityAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
            if let referrerPolicyAttr = cssLinkHtmlTagAttributes["referrerPolicy"] as? String {
                cssLinkAttributes += " link.referrerPolicy = '\(referrerPolicyAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
            if let disabledAttr = cssLinkHtmlTagAttributes["disabled"] as? Bool, disabledAttr {
                cssLinkAttributes += " link.disabled = true; "
            }
            if let alternateAttr = cssLinkHtmlTagAttributes["alternate"] as? Bool, alternateAttr {
                alternateStylesheet = "alternate "
            }
            if let titleAttr = cssLinkHtmlTagAttributes["title"] as? String {
                cssLinkAttributes += " link.title = '\(titleAttr.replacingOccurrences(of: "\'", with: "\\'"))'; "
            }
        }
        let jsWrapper = "(function(d) { var link = d.createElement('link'); link.rel='\(alternateStylesheet)stylesheet', link.type='text/css'; \(cssLinkAttributes) link.href = %@; d.head.appendChild(link); })(document);"
        injectDeferredObject(source: urlFile, withWrapper: jsWrapper, completionHandler: nil)
    }
    
    public func getCopyBackForwardList() -> [String: Any] {
        let currentList = backForwardList
        let currentIndex = currentList.backList.count
        var completeList = currentList.backList
        if currentList.currentItem != nil {
            completeList.append(currentList.currentItem!)
        }
        completeList.append(contentsOf: currentList.forwardList)
        
        var history: [[String: String]] = []
        
        for historyItem in completeList {
            var historyItemMap: [String: String] = [:]
            historyItemMap["originalUrl"] = historyItem.initialURL.absoluteString
            historyItemMap["title"] = historyItem.title
            historyItemMap["url"] = historyItem.url.absoluteString
            history.append(historyItemMap)
        }
        
        var result: [String: Any] = [:]
        result["list"] = history
        result["currentIndex"] = currentIndex
        
        return result;
    }

    @available(macOS 12.0, *)
    public func webView(_ webView: WKWebView,
                        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                        initiatedByFrame frame: WKFrameInfo,
                        type: WKMediaCaptureType,
                        decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let origin = "\(origin.protocol)://\(origin.host)\(origin.port != 0 ? ":" + String(origin.port) : "")"
        let permissionRequest = PermissionRequest(origin: origin, resources: [type.rawValue], frame: frame)
        
        var decisionHandlerCalled = false
        let callback = WebViewChannelDelegate.PermissionRequestCallback()
        callback.nonNullSuccess = { (response: PermissionResponse) in
            if let action = response.action {
                decisionHandlerCalled = true
                switch action {
                    case 1:
                        decisionHandler(.grant)
                        break
                    case 2:
                        decisionHandler(.prompt)
                        break
                    default:
                        decisionHandler(.deny)
                }
                return false
            }
            return true
        }
        callback.defaultBehaviour = { (response: PermissionResponse?) in
            if !decisionHandlerCalled {
                decisionHandlerCalled = true
                decisionHandler(.deny)
            }
        }
        callback.error = { [weak callback] (code: String, message: String?, details: Any?) in
            callback?.defaultBehaviour(nil)
        }
        
        if let channelDelegate = channelDelegate {
            channelDelegate.onPermissionRequest(request: permissionRequest, callback: callback)
        } else {
            callback.defaultBehaviour(nil)
        }
    }
    
    @available(macOS 10.15, *)
    public func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        // Check if this should be a download (for blob URLs and other downloadable content)
        if #available(macOS 11.3, *) {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download, preferences)
                return
            }
        }
        
        self.webView(webView, decidePolicyFor: navigationAction, decisionHandler: {(navigationActionPolicy) -> Void in
            decisionHandler(navigationActionPolicy, preferences)
        })
    }
    
    @available(macOS 11.3, *)
    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        if let url = response.url, url.absoluteString.hasPrefix("blob:") {
            filePathDestination = generateDownloadDestination(with: suggestedFilename)
            completionHandler(filePathDestination)
            return
        }

        if let url = response.url {
            startTrackedDownload(url: url, suggestedFilename: suggestedFilename)
            completionHandler(nil) // Cancel WKDownload, we handle it ourselves
            return
        }
        completionHandler(nil)
    }

    private func generateDownloadDestination(with suggestedFilename: String) -> URL? {
        // Use configured download path or default to Downloads folder
        let downloadDirectory: URL
        if let downloadPath = settings?.downloadPath, !downloadPath.isEmpty {
            downloadDirectory = URL(fileURLWithPath: downloadPath)
        } else {
            downloadDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        }
        
        // Create download directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create download directory: \(error.localizedDescription)")
            return nil
        }
        
        let fileName = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let fileURL = downloadDirectory.appendingPathComponent(fileName)
        
        // If file already exists, append a number to make it unique
        var counter = 1
        var uniqueFileURL = fileURL
        let fileExtension = fileURL.pathExtension
        let fileNameWithoutExtension = fileURL.deletingPathExtension().lastPathComponent
        
        while FileManager.default.fileExists(atPath: uniqueFileURL.path) {
            let newFileName = "\(fileNameWithoutExtension)_\(counter).\(fileExtension)"
            uniqueFileURL = downloadDirectory.appendingPathComponent(newFileName)
            counter += 1
        }
        
        return uniqueFileURL
    }
    
    @available(macOS 11.3, *)
    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }
    
    @available(macOS 11.3, *)
    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self       
    }
    
    @available(macOS 11.3, *)
    public func downloadDidFinish(_ download: WKDownload) {
        // Handle completion for blob downloads that use filePathDestination
        if let destination = filePathDestination {
            let suggestedFilename = destination.lastPathComponent
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
                let totalBytes = (attributes[.size] as? NSNumber)?.int64Value
                DispatchQueue.main.async {
                    self.channelDelegate?.onDownloadCompleted(
                        originalUrl: nil,
                        suggestedFilename: suggestedFilename,
                        filePath: destination.path,
                        mimeType: nil,
                        totalBytes: totalBytes,
                        isSuccessful: true,
                        error: nil
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.channelDelegate?.onDownloadCompleted(
                        originalUrl: nil,
                        suggestedFilename: suggestedFilename,
                        filePath: destination.path,
                        mimeType: nil,
                        totalBytes: nil,
                        isSuccessful: false,
                        error: error.localizedDescription
                    )
                }
            }
            filePathDestination = nil
        }
    }
    
    @available(macOS 11.3, *)
    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        // This method is called when WKDownload fails, but we handle errors in URLSession delegate
        // No need to do anything here as our startTrackedDownload handles everything
    }
    
    public func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        var decisionHandlerCalled = false
        let callback = WebViewChannelDelegate.ShouldOverrideUrlLoadingCallback()
        callback.nonNullSuccess = { (response: WKNavigationActionPolicy) in
            decisionHandlerCalled = true
            decisionHandler(response)
            return false
        }
        callback.defaultBehaviour = { (response: WKNavigationActionPolicy?) in
            if !decisionHandlerCalled {
                decisionHandlerCalled = true
                decisionHandler(.allow)
            }
        }
        callback.error = { [weak callback] (code: String, message: String?, details: Any?) in
            callback?.defaultBehaviour(nil)
        }
        
        let runCallback = {
            if let useShouldOverrideUrlLoading = self.settings?.useShouldOverrideUrlLoading, useShouldOverrideUrlLoading, let channelDelegate = self.channelDelegate {
                channelDelegate.shouldOverrideUrlLoading(navigationAction: navigationAction, callback: callback)
            } else {
                callback.defaultBehaviour(nil)
            }
        }
        
        if windowId != nil, !windowCreated {
            windowBeforeCreatedCallbacks.append(runCallback)
        } else {
            runCallback()
        }
    }
    
    public func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
            let request = WebResourceRequest.init(fromWKNavigationResponse: navigationResponse)
            let errorResponse = WebResourceResponse.init(fromWKNavigationResponse: navigationResponse)
            channelDelegate?.onReceivedHttpError(request: request, errorResponse: errorResponse)
        }
        
        let useOnNavigationResponse = settings?.useOnNavigationResponse
  
        if useOnNavigationResponse != nil, useOnNavigationResponse! {
            var decisionHandlerCalled = false
            let callback = WebViewChannelDelegate.NavigationResponseCallback()
            callback.nonNullSuccess = { (response: WKNavigationResponsePolicy) in
                decisionHandlerCalled = true
                decisionHandler(response)
                return false
            }
            callback.defaultBehaviour = { (response: WKNavigationResponsePolicy?) in
                if !decisionHandlerCalled {
                    decisionHandlerCalled = true
                    decisionHandler(.allow)
                }
            }
            callback.error = { [weak callback] (code: String, message: String?, details: Any?) in
                callback?.defaultBehaviour(nil)
            }
            
            if let channelDelegate = channelDelegate {
                channelDelegate.onNavigationResponse(navigationResponse: navigationResponse, callback: callback)
            } else {
                callback.defaultBehaviour(nil)
            }
        }
        
        // Handle automatic downloads based on MIME type
        if #available(macOS 11.3, *) {
            // Check if content can be shown, if not, trigger download
            if !navigationResponse.canShowMIMEType {
                decisionHandler(.download)
                return
            }
            
            let mimeType = navigationResponse.response.mimeType
            if let url = navigationResponse.response.url, navigationResponse.isForMainFrame {
                if url.scheme != "file", mimeType != nil, !mimeType!.starts(with: "text/") {
                    decisionHandler(.download)
                    return
                }
            }
        }
        
        decisionHandler(.allow)
    }
    
    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        currentOriginalUrl = url
        
        disposeWebMessageChannels()
        initializeWindowIdJS()
        
        if #available(macOS 11.0, *) {
            configuration.userContentController.resetContentWorlds(windowId: windowId)
        }
        
        channelDelegate?.onLoadStart(url: url?.absoluteString)
        
        inAppBrowserDelegate?.didStartNavigation(url: url)
    }
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        initializeWindowIdJS()
        
        InAppWebView.credentialsProposed = []
        evaluateJavaScript(JavaScriptBridgeJS.PLATFORM_READY_JS_SOURCE, completionHandler: nil)

        channelDelegate?.onLoadStop(url: url?.absoluteString)
        
        inAppBrowserDelegate?.didFinishNavigation(url: url)
    }
    
    public func webView(_ view: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        webView(view, didFail: navigation, withError: error)
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        InAppWebView.credentialsProposed = []
        
        var urlError: URL = url ?? URL(string: "about:blank")!
        var errorCode = -1
        var errorDescription = "domain=\(error._domain), code=\(error._code), \(error.localizedDescription)"
        
        if let info = error as? URLError {
            if let failingURL = info.failingURL {
                urlError = failingURL
            }
            errorCode = info.code.rawValue
            errorDescription = info.localizedDescription
        }
        else if let info = error._userInfo as? [String: Any] {
            if let failingUrl = info[NSURLErrorFailingURLErrorKey] as? URL {
                urlError = failingUrl
            }
            if let failingUrlString = info[NSURLErrorFailingURLStringErrorKey] as? String,
               let failingUrl = URL(string: failingUrlString) {
                urlError = failingUrl
            }
        }
        
        let webResourceRequest = WebResourceRequest(url: urlError, headers: nil)
        let webResourceError = WebResourceError(type: errorCode, errorDescription: errorDescription)
        
        channelDelegate?.onReceivedError(request: webResourceRequest, error: webResourceError)
        
        inAppBrowserDelegate?.didFailNavigation(url: url, error: error)
    }
    
    public func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        var completionHandlerCalled = false
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodDefault ||
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest ||
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodNegotiate ||
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodNTLM {
            let host = challenge.protectionSpace.host
            let prot = challenge.protectionSpace.protocol
            let realm = challenge.protectionSpace.realm
            let port = challenge.protectionSpace.port
            
            let callback = WebViewChannelDelegate.ReceivedHttpAuthRequestCallback()
            callback.nonNullSuccess = { (response: HttpAuthResponse) in
                if let action = response.action {
                    completionHandlerCalled = true
                    switch action {
                        case 0:
                            InAppWebView.credentialsProposed = []
                            // used .performDefaultHandling to maintain consistency with Android
                            // because .cancelAuthenticationChallenge will call webView(_:didFail:withError:)
                            completionHandler(.performDefaultHandling, nil)
                            //completionHandler(.cancelAuthenticationChallenge, nil)
                            break
                        case 1:
                            let username = response.username
                            let password = response.password
                            let permanentPersistence = response.permanentPersistence
                            let persistence = (permanentPersistence) ? URLCredential.Persistence.permanent : URLCredential.Persistence.forSession
                            let credential = URLCredential(user: username, password: password, persistence: persistence)
                            completionHandler(.useCredential, credential)
                            break
                        case 2:
                            if InAppWebView.credentialsProposed.count == 0 {
                                for (protectionSpace, credentials) in CredentialDatabase.credentialStore.allCredentials {
                                    if protectionSpace.host == host && protectionSpace.realm == realm &&
                                    protectionSpace.protocol == prot && protectionSpace.port == port {
                                        for credential in credentials {
                                            InAppWebView.credentialsProposed.append(credential.value)
                                        }
                                        break
                                    }
                                }
                            }
                            if InAppWebView.credentialsProposed.count == 0, let credential = challenge.proposedCredential {
                                InAppWebView.credentialsProposed.append(credential)
                            }
                            
                            if let credential = InAppWebView.credentialsProposed.popLast() {
                                completionHandler(.useCredential, credential)
                            }
                            else {
                                completionHandler(.performDefaultHandling, nil)
                            }
                            break
                        default:
                            InAppWebView.credentialsProposed = []
                            completionHandler(.performDefaultHandling, nil)
                    }
                    return false
                }
                return true
            }
            callback.defaultBehaviour = { (response: HttpAuthResponse?) in
                if !completionHandlerCalled {
                    completionHandlerCalled = true
                    completionHandler(.performDefaultHandling, nil)
                }
            }
            callback.error = { [weak callback] (code: String, message: String?, details: Any?) in
                callback?.defaultBehaviour(nil)
            }
            
            let runCallback = {
                if let channelDelegate = self.channelDelegate {
                    channelDelegate.onReceivedHttpAuthRequest(challenge: HttpAuthenticationChallenge(fromChallenge: challenge), callback: callback)
                } else {
                    callback.defaultBehaviour(nil)
                }
            }
            
            if windowId != nil, !windowCreated {
                windowBeforeCreatedCallbacks.append(runCallback)
            } else {
                runCallback()
            }
        }
        else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            guard let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            
            if let scheme = challenge.protectionSpace.protocol, scheme == "https" {
                // workaround for ProtectionSpace SSL Certificate
                // https://github.com/pichillilorenzo/flutter_inappwebview/issues/1678
                DispatchQueue.global().async {
                    if let sslCertificate = challenge.protectionSpace.sslCertificate {
                        DispatchQueue.main.async {
                            InAppWebView.sslCertificatesMap[challenge.protectionSpace.host] = sslCertificate
                        }
                    }
                }
            }
            
            let callback = WebViewChannelDelegate.ReceivedServerTrustAuthRequestCallback()
            callback.nonNullSuccess = { (response: ServerTrustAuthResponse) in
                if let action = response.action {
                    completionHandlerCalled = true
                    switch action {
                        case 0:
                            InAppWebView.credentialsProposed = []
                            completionHandler(.cancelAuthenticationChallenge, nil)
                            break
                        case 1:
                            // workaround for https://github.com/pichillilorenzo/flutter_inappwebview/issues/1924
                            DispatchQueue.global().async {
                                let exceptions = SecTrustCopyExceptions(serverTrust)
                                SecTrustSetExceptions(serverTrust, exceptions)
                                let credential = URLCredential(trust: serverTrust)
                                completionHandler(.useCredential, credential)
                            }
                            break
                        default:
                            InAppWebView.credentialsProposed = []
                            completionHandler(.performDefaultHandling, nil)
                    }
                    return false
                }
                return true
            }
            callback.defaultBehaviour = { (response: ServerTrustAuthResponse?) in
                if !completionHandlerCalled {
                    completionHandlerCalled = true
                    completionHandler(.performDefaultHandling, nil)
                }
            }
            callback.error = { [weak callback] (code: String, message: String?, details: Any?) in
                callback?.defaultBehaviour(nil)
            }
            
            let runCallback = {
                if let channelDelegate = self.channelDelegate {
                    channelDelegate.onReceivedServerTrustAuthRequest(challenge: ServerTrustChallenge(fromChallenge: challenge), callback: callback)
                } else {
                    callback.defaultBehaviour(nil)
                }
            }
            
            if windowId != nil, !windowCreated {
                windowBeforeCreatedCallbacks.append(runCallback)
            } else {
                runCallback()
            }
        }
        else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            let callback = WebViewChannelDelegate.ReceivedClientCertRequestCallback()
            callback.nonNullSuccess = { (response: ClientCertResponse) in
                if let action = response.action {
                    completionHandlerCalled = true
                    switch action {
                        case 0:
                            completionHandler(.cancelAuthenticationChallenge, nil)
                            break
                        case 1:
                            let certificatePath = response.certificatePath
                            let certificatePassword = response.certificatePassword ?? "";
                            
                            var path: String = certificatePath
                            do {
                                path = try Util.getAbsPathAsset(assetFilePath: certificatePath)
                            } catch {}
                            
                            if let PKCS12Data = NSData(contentsOfFile: path),
                               let identityAndTrust: IdentityAndTrust = self.extractIdentity(PKCS12Data: PKCS12Data, password: certificatePassword) {
                                let urlCredential: URLCredential = URLCredential(
                                    identity: identityAndTrust.identityRef,
                                    certificates: identityAndTrust.certArray as? [AnyObject],
                                    persistence: URLCredential.Persistence.forSession);
                                completionHandler(.useCredential, urlCredential)
                            } else {
                                completionHandler(.performDefaultHandling, nil)
                            }
                            
                            break
                        case 2:
                            completionHandler(.cancelAuthenticationChallenge, nil)
                            break
                        default:
                            completionHandler(.performDefaultHandling, nil)
                    }
                    return false
                }
                return true
            }
            callback.defaultBehaviour = { (response: ClientCertResponse?) in
                if !completionHandlerCalled {
                    completionHandlerCalled = true
                    completionHandler(.performDefaultHandling, nil)
                }
            }
            callback.error = { [weak callback] (code: String, message: String?, details: Any?) in
                callback?.defaultBehaviour(nil)
            }
            
            let runCallback = {
                if let channelDelegate = self.channelDelegate {
                    channelDelegate.onReceivedClientCertRequest(challenge: ClientCertChallenge(fromChallenge: challenge), callback: callback)
                } else {
                    callback.defaultBehaviour(nil)
                }
            }
            
            if windowId != nil, !windowCreated {
                windowBeforeCreatedCallbacks.append(runCallback)
            } else {
                runCallback()
            }
        }
        else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    struct IdentityAndTrust {
        var identityRef: SecIdentity
        var trust: SecTrust
        var certArray: AnyObject
    }

    func extractIdentity(PKCS12Data: NSData, password: String) -> IdentityAndTrust? {
        var identityAndTrust: IdentityAndTrust?
        var securityError: OSStatus = errSecSuccess

        var importResult: CFArray? = nil
        securityError = SecPKCS12Import(
            PKCS12Data as NSData,
            [kSecImportExportPassphrase as String: password] as NSDictionary,
            &importResult
        )

        if securityError == errSecSuccess {
            let certItems: CFArray = importResult! as CFArray;
            let certItemsArray: Array = certItems as Array
            let dict: AnyObject? = certItemsArray.first;
            if let certEntry: Dictionary = dict as? Dictionary<String, AnyObject> {
                // grab the identity
                let identityPointer: AnyObject? = certEntry["identity"]
                let secIdentityRef:SecIdentity = (identityPointer as! SecIdentity?)!
                // grab the trust
                let trustPointer: AnyObject? = certEntry["trust"]
                let trustRef:SecTrust = trustPointer as! SecTrust
                // grab the cert
                let chainPointer: AnyObject? = certEntry["chain"]
                identityAndTrust = IdentityAndTrust(identityRef: secIdentityRef, trust: trustRef, certArray:  chainPointer!)
            }
        } else {
            print("Security Error: " + securityError.description)
            print(SecCopyErrorMessageString(securityError,nil) ?? "")
        }
        return identityAndTrust;
    }
    
    @available(macOS 10.12, *)
    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let openPanel = NSOpenPanel()
        currentOpenPanel = openPanel
        openPanel.canChooseFiles = true
        if #available(macOS 10.13.4, *) {
            openPanel.canChooseDirectories = parameters.allowsDirectories
        }
        openPanel.allowsMultipleSelection = parameters.allowsMultipleSelection
        openPanel.begin { (result) in
            if result == .OK {
                completionHandler(openPanel.urls)
            } else {
                completionHandler([])
            }
            self.currentOpenPanel = nil
        }
    }
    
    func createAlertDialog(message: String?, responseMessage: String?, confirmButtonTitle: String?, completionHandler: @escaping () -> Void) {
        let title = responseMessage != nil && !responseMessage!.isEmpty ? responseMessage : message
        let okButton = confirmButtonTitle != nil && !confirmButtonTitle!.isEmpty ? confirmButtonTitle : NSLocalizedString("Ok", comment: "")
        
        let alert = NSAlert()
        alert.messageText = title ?? ""
        alert.alertStyle = .informational
        alert.addButton(withTitle: okButton ?? "")
        alert.runModal()
        completionHandler()
    }
    
    public func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        
        if (isPausedTimers) {
            isPausedTimersCompletionHandler = completionHandler
            return
        }
        
        var completionHandlerCalled = false
        
        let callback = WebViewChannelDelegate.JsAlertCallback()
        callback.nonNullSuccess = { (response: JsAlertResponse) in
            if response.handledByClient {
                completionHandlerCalled = true
                let action = response.action ?? 1
                switch action {
                    case 0:
                        completionHandler()
                        break
                    default:
                        completionHandler()
                }
                return false
            }
            return true
        }
        callback.defaultBehaviour = { [weak self] (response: JsAlertResponse?) in
            if !completionHandlerCalled {
                completionHandlerCalled = true
                let responseMessage = response?.message
                let confirmButtonTitle = response?.confirmButtonTitle
                self?.createAlertDialog(message: message, responseMessage: responseMessage,
                                       confirmButtonTitle: confirmButtonTitle, completionHandler: completionHandler)
            }
        }
        callback.error = { (code: String, message: String?, details: Any?) in
            if !completionHandlerCalled {
                completionHandlerCalled = true
                print(code + ", " + (message ?? ""))
                completionHandler()
            }
        }
        
        if let channelDelegate = channelDelegate {
            channelDelegate.onJsAlert(url: frame.request.url, message: message, isMainFrame: frame.isMainFrame, callback: callback)
        } else {
            callback.defaultBehaviour(nil)
        }
    }
    
    func createConfirmDialog(message: String?, responseMessage: String?, confirmButtonTitle: String?, cancelButtonTitle: String?, completionHandler: @escaping (Bool) -> Void) {
        let dialogMessage = responseMessage != nil && !responseMessage!.isEmpty ? responseMessage : message
        let okButton = confirmButtonTitle != nil && !confirmButtonTitle!.isEmpty ? confirmButtonTitle : NSLocalizedString("Ok", comment: "")
        let cancelButton = cancelButtonTitle != nil && !cancelButtonTitle!.isEmpty ? cancelButtonTitle : NSLocalizedString("Cancel", comment: "")
        
        let alert = NSAlert()
        alert.messageText = dialogMessage ?? ""
        alert.alertStyle = .informational
        alert.addButton(withTitle: okButton ?? "")
        alert.addButton(withTitle: cancelButton ?? "")
        let res = alert.runModal()
        completionHandler(res == .alertFirstButtonReturn)
    }
    
    public func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        var completionHandlerCalled = false
        
        let callback = WebViewChannelDelegate.JsConfirmCallback()
        callback.nonNullSuccess = { (response: JsConfirmResponse) in
            if response.handledByClient {
                completionHandlerCalled = true
                let action = response.action ?? 1
                switch action {
                    case 0:
                        completionHandler(true)
                        break
                    case 1:
                        completionHandler(false)
                        break
                    default:
                        completionHandler(false)
                }
                return false
            }
            return true
        }
        callback.defaultBehaviour = { [weak self] (response: JsConfirmResponse?) in
            if !completionHandlerCalled {
                completionHandlerCalled = true
                let responseMessage = response?.message
                let confirmButtonTitle = response?.confirmButtonTitle
                let cancelButtonTitle = response?.cancelButtonTitle
                self?.createConfirmDialog(message: message, responseMessage: responseMessage, confirmButtonTitle: confirmButtonTitle, cancelButtonTitle: cancelButtonTitle, completionHandler: completionHandler)
            }
        }
        callback.error = { (code: String, message: String?, details: Any?) in
            if !completionHandlerCalled {
                completionHandlerCalled = true
                print(code + ", " + (message ?? ""))
                completionHandler(false)
            }
        }
        
        if let channelDelegate = channelDelegate {
            channelDelegate.onJsConfirm(url: frame.request.url, message: message, isMainFrame: frame.isMainFrame, callback: callback)
        } else {
            callback.defaultBehaviour(nil)
        }
    }

    func createPromptDialog(message: String, defaultValue: String?, responseMessage: String?, confirmButtonTitle: String?, cancelButtonTitle: String?, value: String?, completionHandler: @escaping (String?) -> Void) {
        let dialogMessage = responseMessage != nil && !responseMessage!.isEmpty ? responseMessage : message
        let okButton = confirmButtonTitle != nil && !confirmButtonTitle!.isEmpty ? confirmButtonTitle : NSLocalizedString("Ok", comment: "")
        let cancelButton = cancelButtonTitle != nil && !cancelButtonTitle!.isEmpty ? cancelButtonTitle : NSLocalizedString("Cancel", comment: "")
        
        let alert = NSAlert()
        alert.messageText = dialogMessage ?? ""
        alert.alertStyle = .informational
        alert.addButton(withTitle: okButton ?? "")
        alert.addButton(withTitle: cancelButton ?? "")
        let txt = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        txt.stringValue = defaultValue ?? ""
        alert.accessoryView = txt
        let res = alert.runModal()
        
        completionHandler(value != nil ? value : (res == .alertFirstButtonReturn ? txt.stringValue : nil))
    }
    
    public func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt message: String, defaultText defaultValue: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        
        var completionHandlerCalled = false
        
        let callback = WebViewChannelDelegate.JsPromptCallback()
        callback.nonNullSuccess = { (response: JsPromptResponse) in
            if response.handledByClient {
                completionHandlerCalled = true
                let action = response.action ?? 1
                switch action {
                    case 0:
                        completionHandler(response.value)
                        break
                    case 1:
                        completionHandler(nil)
                        break
                    default:
                        completionHandler(nil)
                }
                return false
            }
            return true
        }
        callback.defaultBehaviour = { [weak self] (response: JsPromptResponse?) in
            if !completionHandlerCalled {
                completionHandlerCalled = true
                let responseMessage = response?.message
                let confirmButtonTitle = response?.confirmButtonTitle
                let cancelButtonTitle = response?.cancelButtonTitle
                let value = response?.value
                self?.createPromptDialog(message: message, defaultValue: defaultValue, responseMessage: responseMessage, confirmButtonTitle: confirmButtonTitle,
                                        cancelButtonTitle: cancelButtonTitle, value: value, completionHandler: completionHandler)
            }
        }
        callback.error = { (code: String, message: String?, details: Any?) in
            if !completionHandlerCalled {
                completionHandlerCalled = true
                print(code + ", " + (message ?? ""))
                completionHandler(nil)
            }
        }
        
        if let channelDelegate = channelDelegate {
            channelDelegate.onJsPrompt(url: frame.request.url, message: message, defaultValue: defaultValue, isMainFrame: frame.isMainFrame, callback: callback)
        } else {
            callback.defaultBehaviour(nil)
        }
    }
    
    public func webView(_ webView: WKWebView,
                        createWebViewWith configuration: WKWebViewConfiguration,
                  for navigationAction: WKNavigationAction,
                  windowFeatures: WKWindowFeatures) -> WKWebView? {
        var windowId: Int64 = 0
        let inAppWebViewManager = plugin?.inAppWebViewManager
        if let inAppWebViewManager = inAppWebViewManager {
            inAppWebViewManager.windowAutoincrementId += 1
            windowId = inAppWebViewManager.windowAutoincrementId
        }
        
        let windowWebView = InAppWebView(id: nil, plugin: nil, frame: CGRect.zero, configuration: configuration)
        windowWebView.windowId = windowId
        
        let webViewTransport = WebViewTransport(
            webView: windowWebView,
            request: navigationAction.request
        )

        inAppWebViewManager?.windowWebViews[windowId] = webViewTransport
        
        let createWindowAction = CreateWindowAction(navigationAction: navigationAction, windowId: windowId, windowFeatures: windowFeatures, isDialog: nil)
        
        let callback = WebViewChannelDelegate.CreateWindowCallback()
        callback.nonNullSuccess = { (handledByClient: Bool) in
            return !handledByClient
        }
        callback.defaultBehaviour = { [weak self] (handledByClient: Bool?) in
            if inAppWebViewManager?.windowWebViews[windowId] != nil {
                inAppWebViewManager?.windowWebViews.removeValue(forKey: windowId)
            }
            self?.loadUrl(urlRequest: navigationAction.request, allowingReadAccessTo: nil)
        }
        callback.error = { [weak callback] (code: String, message: String?, details: Any?) in
            print(code + ", " + (message ?? ""))
            callback?.defaultBehaviour(nil)
        }
        
        if let channelDelegate = channelDelegate {
            channelDelegate.onCreateWindow(createWindowAction: createWindowAction, callback: callback)
        } else {
            callback.defaultBehaviour(nil)
        }
        
        return windowWebView
    }
    
    public func webView(_ webView: WKWebView,
                        authenticationChallenge challenge: URLAuthenticationChallenge,
                        shouldAllowDeprecatedTLS decisionHandler: @escaping (Bool) -> Void) {
        var decisionHandlerCalled = false
        let callback = WebViewChannelDelegate.ShouldAllowDeprecatedTLSCallback()
        callback.nonNullSuccess = { (action: Bool) in
            decisionHandlerCalled = true
            decisionHandler(action)
            return false
        }
        callback.defaultBehaviour = { (action: Bool?) in
            if !decisionHandlerCalled {
                decisionHandlerCalled = true
                decisionHandler(false)
            }
        }
        callback.error = { [weak callback] (code: String, message: String?, details: Any?) in
            print(code + ", " + (message ?? ""))
            callback?.defaultBehaviour(nil)
        }
        
        let runCallback = {
            if let channelDelegate = self.channelDelegate {
                channelDelegate.shouldAllowDeprecatedTLS(challenge: challenge, callback: callback)
            } else {
                callback.defaultBehaviour(nil)
            }
        }
        
        if windowId != nil, !windowCreated {
            windowBeforeCreatedCallbacks.append(runCallback)
        } else {
            runCallback()
        }
    }
    
    public func webViewDidClose(_ webView: WKWebView) {
        channelDelegate?.onCloseWindow()
    }
    
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        channelDelegate?.onWebContentProcessDidTerminate()
    }
    
    public func webView(_ webView: WKWebView,
                        didCommit navigation: WKNavigation!) {
        channelDelegate?.onPageCommitVisible(url: url?.absoluteString)
    }
    
    public func webView(_ webView: WKWebView,
                        didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        channelDelegate?.onDidReceiveServerRedirectForProvisionalNavigation()
    }
    
    // https://stackoverflow.com/a/42840541/4637638
    public func isVideoPlayerWindow(_ notificationObject: AnyObject?) -> Bool {
        if let obj = notificationObject, let clazz = NSClassFromString("WebCoreFullScreenWindow") {
            return obj.isKind(of: clazz)
        }
        return false
    }
    
    @objc func onEnterFullscreen(_ notification: Notification) {
        // TODO: Still not working on iOS 16.0!
//        if #available(iOS 16.0, *) {
//            channelDelegate?.onEnterFullscreen()
//            inFullscreen = true
//        }
//        else
        if (isVideoPlayerWindow(notification.object as AnyObject?)) {
            channelDelegate?.onEnterFullscreen()
            inFullscreen = true
        }
    }
    
    @objc func onExitFullscreen(_ notification: Notification) {
        // TODO: Still not working on iOS 16.0!
//        if #available(iOS 16.0, *) {
//            channelDelegate?.onExitFullscreen()
//            inFullscreen = false
//        }
//        else
        if (isVideoPlayerWindow(notification.object as AnyObject?)) {
            channelDelegate?.onExitFullscreen()
            inFullscreen = false
        }
    }
    
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard javaScriptBridgeEnabled else {
            return
        }
        
        guard let body = message.body as? [String: Any?] else {
            return
        }
        
        guard let bridgeSecret = body["_bridgeSecret"] as? String, bridgeSecret == exceptedBridgeSecret else {
            print("Bridge access attempt with wrong secret token, possibly from malicious code from origin \(message.frameInfo.securityOrigin)")
            return
        }
        
        var sourceOrigin: URL? = nil
        let securityOrigin = message.frameInfo.securityOrigin
        let scheme = securityOrigin.protocol
        let host = securityOrigin.host
        let port = securityOrigin.port
        if !scheme.isEmpty, !host.isEmpty {
            sourceOrigin = URL(string: "\(scheme)://\(host)\(port != 0 ? ":" + String(port) : "")")
        }
        let requestUrl = message.frameInfo.request.url
        
        var isOriginAllowed = false
        if let javaScriptHandlersOriginAllowList = settings?.javaScriptHandlersOriginAllowList {
            if let origin = sourceOrigin?.absoluteString {
                for allowedOrigin in javaScriptHandlersOriginAllowList {
                    if origin.range(of: allowedOrigin, options: .regularExpression, range: nil, locale: nil) != nil {
                        isOriginAllowed = true
                        break
                    }
                }
            }
        } else {
            // origin is by default allowed if the allow list is null
            isOriginAllowed = true
        }
        
        if !isOriginAllowed {
          print("Bridge access attempt from an origin not allowed: \(message.frameInfo.securityOrigin)")
          return
        }
        
        if message.name == "callHandler" {
            guard let handlerName = body["handlerName"] as? String else {
                print("handlerName is null or undefined")
                return
            }
            
            let _windowId = body["_windowId"] as? Int64
            var webView = self
            if let wId = _windowId, let webViewTransport = plugin?.inAppWebViewManager?.windowWebViews[wId] {
                webView = webViewTransport.webView
            }
            var isInternalHandler = true
            switch (handlerName) {
                case "onPrintRequest":
                    let settings = PrintJobSettings()
                    settings.handledByClient = true
                    if let printJobId = webView.printCurrentPage(settings: settings) {
                        let callback = WebViewChannelDelegate.PrintRequestCallback()
                        callback.nonNullSuccess = { (handledByClient: Bool) in
                            return !handledByClient
                        }
                        callback.defaultBehaviour = { (handledByClient: Bool?) in
                            if let printJob = webView.plugin?.printJobManager?.jobs[printJobId] {
                                printJob?.disposeWhenDidRun = true
                            }
                        }
                        callback.error = { [weak callback] (code: String, message: String?, details: Any?) in
                            callback?.defaultBehaviour(nil)
                        }
                        webView.channelDelegate?.onPrintRequest(url: webView.url, printJobId: printJobId, callback: callback)
                    }
                    break
                case "onConsoleMessage":
                    if let args = body["args"] as? String, let data = args.data(using: .utf8) {
                        let jsonArgs = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [[String: Any]]
                        if let jsonData = jsonArgs?.first {
                            var messageLevel = 1
                            switch (jsonData["level"] as? String) {
                            case "log":
                                messageLevel = 1
                                break
                            case "debug":
                                // on Android, console.debug is TIP
                                messageLevel = 0
                                break
                            case "error":
                                messageLevel = 3
                                break
                            case "info":
                                // on Android, console.info is LOG
                                messageLevel = 1
                                break
                            case "warn":
                                messageLevel = 2
                                break
                            default:
                                messageLevel = 1
                                break
                            }
                            let consoleMessage = jsonData["message"] as? String ?? ""
                            
                            webView.channelDelegate?.onConsoleMessage(message: consoleMessage, messageLevel: messageLevel)
                        }
                    }
                    break
                case "onFindResultReceived":
                    if let args = body["args"] as? String, let data = args.data(using: .utf8) {
                        let jsonArgs = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [[String: Any]]
                        if let jsonData = jsonArgs?.first,
                           let findResult = jsonData["findResult"] as? [String: Any],
                           let activeMatchOrdinal = findResult["activeMatchOrdinal"] as? Int,
                           let numberOfMatches = findResult["numberOfMatches"] as? Int,
                           let isDoneCounting = findResult["isDoneCounting"] as? Bool {
                            webView.findInteractionController?.channelDelegate?.onFindResultReceived(activeMatchOrdinal: activeMatchOrdinal, numberOfMatches: numberOfMatches, isDoneCounting: isDoneCounting)
                            webView.channelDelegate?.onFindResultReceived(activeMatchOrdinal: activeMatchOrdinal, numberOfMatches: numberOfMatches, isDoneCounting: isDoneCounting)
                        }
                    }
                    break
                case "onCallAsyncJavaScriptResultBelowIOS14Received":
                    if let args = body["args"] as? String, let data = args.data(using: .utf8) {
                        let jsonArgs = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [[String: Any]]
                        if let jsonData = jsonArgs?.first,
                           let resultUuid = jsonData["resultUuid"] as? String,
                           let result = webView.callAsyncJavaScriptBelowMacOS11Results[resultUuid] {
                            result([
                                "value": jsonData["value"],
                                "error": jsonData["error"]
                            ])
                            webView.callAsyncJavaScriptBelowMacOS11Results.removeValue(forKey: resultUuid)
                        }
                    }
                    break
                case "onWebMessagePortMessageReceived":
                    if let args = body["args"] as? String, let data = args.data(using: .utf8) {
                        let jsonArgs = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [[String: Any]]
                        if let jsonData = jsonArgs?.first,
                           let webMessageChannelId = jsonData["webMessageChannelId"] as? String,
                           let index = jsonData["index"] as? Int64 {
                            var webMessage: WebMessage? = nil
                            if let webMessageMap = jsonData["message"] as? [String : Any?] {
                                webMessage = WebMessage.fromMap(map: webMessageMap)
                            }
                            
                            if let webMessageChannel = webView.webMessageChannels[webMessageChannelId] {
                                webMessageChannel.channelDelegate?.onMessage(index: index, message: webMessage)
                            }
                        }
                    }
                    break
                case "onWebMessageListenerPostMessageReceived":
                    if let args = body["args"] as? String, let data = args.data(using: .utf8) {
                        let jsonArgs = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [[String: Any]]
                        if let jsonData = jsonArgs?.first, let jsObjectName = jsonData["jsObjectName"] as? String {
                            var webMessage: WebMessage? = nil
                            if let webMessageMap = body["message"] as? [String : Any?] {
                                webMessage = WebMessage.fromMap(map: webMessageMap)
                            }
                            
                            if let webMessageListener = webView.webMessageListeners.first(where: ({($0.jsObjectName == jsObjectName)})) {
                                let isMainFrame = message.frameInfo.isMainFrame
                                
                                let securityOrigin = message.frameInfo.securityOrigin
                                let scheme = securityOrigin.protocol
                                let host = securityOrigin.host
                                let port = securityOrigin.port
                                
                                if !webMessageListener.isOriginAllowed(scheme: scheme, host: host, port: port) {
                                    return
                                }
                                
                                var sourceOrigin: URL? = nil
                                if !scheme.isEmpty, !host.isEmpty {
                                    sourceOrigin = URL(string: "\(scheme)://\(host)\(port != 0 ? ":" + String(port) : "")")
                                }
                                webMessageListener.channelDelegate?.onPostMessage(message: webMessage, sourceOrigin: sourceOrigin, isMainFrame: isMainFrame)
                            }
                        }
                    }
                    break
                case "onScrollChanged":
                    if let args = body["args"] as? String, let data = args.data(using: .utf8) {
                        let jsonArgs = try? JSONSerialization.jsonObject(with: data, options: .mutableContainers) as? [[String: Any]]
                        if let jsonData = jsonArgs?.first,
                           let x = jsonData["x"] as? Int,
                           let y = jsonData["y"] as? Int {
                            webView.channelDelegate?.onScrollChanged(x: x, y: y)
                        }
                    }
                    break
                default:
                    isInternalHandler = false
                    break
            }
            
            let _callHandlerID = body["_callHandlerID"] as? Int64 ?? 0
            
            if isInternalHandler {
                evaluateJavaScript("""
if(window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME())[\(_callHandlerID)] != null) {
    window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME())[\(_callHandlerID)].resolve();
    delete window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME())[\(_callHandlerID)];
}
""", completionHandler: nil)
                return
            }
            
            let args = body["args"] as? String ?? ""
            
            let callback = WebViewChannelDelegate.CallJsHandlerCallback()
            callback.defaultBehaviour = { (response: Any?) in
                var json = "null"
                if let r = response as? String {
                    json = r
                }
                
                webView.evaluateJavaScript("""
if(window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME())[\(_callHandlerID)] != null) {
    window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME())[\(_callHandlerID)].resolve(\(json));
    delete window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME())[\(_callHandlerID)];
}
""", completionHandler: nil)
            }
            callback.error = { (code: String, message: String?, details: Any?) in
                let errorMessage = code + (message != nil ? ", " + (message ?? "") : "")
                print(errorMessage)
                
                webView.evaluateJavaScript("""
if(window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME())[\(_callHandlerID)] != null) {
    window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME())[\(_callHandlerID)].reject(new Error('\(errorMessage.replacingOccurrences(of: "\'", with: "\\'"))'));
    delete window.\(JavaScriptBridgeJS.get_JAVASCRIPT_BRIDGE_NAME())[\(_callHandlerID)];
}
""", completionHandler: nil)
            }
            
            if let channelDelegate = webView.channelDelegate {
                let data = JavaScriptHandlerFunctionData(
                    args: args, isMainFrame: message.frameInfo.isMainFrame,
                    origin: sourceOrigin?.absoluteString ?? "",
                    requestUrl: requestUrl?.absoluteString ?? ""
                )
                channelDelegate.onCallJsHandler(handlerName: handlerName, data: data, callback: callback)
            }
        }
    }
    
    public func scrollTo(x: Int, y: Int, animated: Bool) {
        evaluateJavaScript("window.scrollTo({left: \(x), top: \(y), behavior: \(animated ? "'smooth'" : "'auto'")})")
    }
    
    public func scrollBy(x: Int, y: Int, animated: Bool) {
        evaluateJavaScript("window.scrollBy({left: \(x), top: \(y), behavior: \(animated ? "'smooth'" : "'auto'")})")
    }
    
    
    public func pauseTimers() {
        if !isPausedTimers {
            isPausedTimers = true
            let script = "alert();";
            self.evaluateJavaScript(script, completionHandler: nil)
        }
    }
    
    public func resumeTimers() {
        if isPausedTimers {
            if let completionHandler = isPausedTimersCompletionHandler {
                self.isPausedTimersCompletionHandler = nil
                completionHandler()
            }
            isPausedTimers = false
        }
    }
    
    public func printCurrentPage(settings: PrintJobSettings? = nil,
                                 completionHandler: PrintJobController.CompletionHandler? = nil) -> String? {
        if #available(macOS 11.0, *) {
            var printJobId: String? = nil
            if let settings = settings, settings.handledByClient {
                printJobId = NSUUID().uuidString
            }
            
            var printInfoDictionary: [NSPrintInfo.AttributeKey : Any] = [:]
            if let settings = settings {
                if let jobSavingURL = settings.jobSavingURL, let url = URL(string: jobSavingURL) {
                    printInfoDictionary[.jobSavingURL] = url
                }
                printInfoDictionary[.copies] = settings.copies
                if let firstPage = settings.firstPage {
                    printInfoDictionary[.firstPage] = firstPage
                }
                if let lastPage = settings.lastPage {
                    printInfoDictionary[.lastPage] = lastPage
                }
                printInfoDictionary[.detailedErrorReporting] = settings.detailedErrorReporting
                printInfoDictionary[.faxNumber] = settings.faxNumber ?? ""
                printInfoDictionary[.headerAndFooter] = settings.headerAndFooter
                if let mustCollate = settings.mustCollate {
                    printInfoDictionary[.mustCollate] = mustCollate
                }
                if let pagesAcross = settings.pagesAcross {
                    printInfoDictionary[.pagesAcross] = pagesAcross
                }
                if let pagesDown = settings.pagesDown {
                    printInfoDictionary[.pagesDown] = pagesDown
                }
                if let time = settings.time {
                    printInfoDictionary[.time] = Date(timeIntervalSince1970: TimeInterval(Double(time)/1000))
                }
            }
            
            let printInfo = NSPrintInfo(dictionary: printInfoDictionary)
            
            if let settings = settings {
                if let orientationValue = settings.orientation,
                   let orientation = NSPrintInfo.PaperOrientation.init(rawValue: orientationValue) {
                    printInfo.orientation = orientation
                }
                if let margins = settings.margins {
                    printInfo.topMargin = margins.top
                    printInfo.rightMargin = margins.right
                    printInfo.bottomMargin = margins.bottom
                    printInfo.leftMargin = margins.left
                }
                if let numberOfPages = settings.numberOfPages {
                    printInfo.printSettings["com_apple_print_PrintSettings_PMLastPage"] = numberOfPages
                }
                if let colorMode = settings.colorMode {
                    printInfo.printSettings["ColorModel"] = colorMode
                }
                if let scalingFactor = settings.scalingFactor {
                    printInfo.scalingFactor = scalingFactor
                }
                if let jobDisposition = settings.jobDisposition {
                    printInfo.jobDisposition = Util.getNSPrintInfoJobDisposition(name: jobDisposition)
                }
                if let paperName = settings.paperName {
                    printInfo.paperName = NSPrinter.PaperName.init(rawValue: paperName)
                }
                if let horizontalPagination = settings.horizontalPagination,
                   let pagination = NSPrintInfo.PaginationMode.init(rawValue: horizontalPagination) {
                    printInfo.horizontalPagination = pagination
                }
                if let verticalPagination = settings.verticalPagination,
                   let pagination = NSPrintInfo.PaginationMode.init(rawValue: verticalPagination) {
                    printInfo.verticalPagination = pagination
                }
                printInfo.isHorizontallyCentered = settings.isHorizontallyCentered
                printInfo.isVerticallyCentered = settings.isVerticallyCentered
            }
            let printOperation = printOperation(with: printInfo)
            printOperation.jobTitle = settings?.jobName ?? (title ?? url?.absoluteString ?? "") + " Document"
            printOperation.view?.frame = bounds
            
            if let settings = settings {
                if let pageOrder = settings.pageOrder, let order = NSPrintOperation.PageOrder.init(rawValue: pageOrder) {
                    printOperation.pageOrder = order
                }
                printOperation.canSpawnSeparateThread = settings.canSpawnSeparateThread
                printOperation.showsPrintPanel = settings.showsPrintPanel
                printOperation.showsProgressPanel = settings.showsProgressPanel
                if settings.showsPaperOrientation {
                    printOperation.printPanel.options.insert(.showsOrientation)
                } else {
                    printOperation.printPanel.options.remove(.showsOrientation)
                }
                if settings.showsNumberOfCopies {
                    printOperation.printPanel.options.insert(.showsCopies)
                } else {
                    printOperation.printPanel.options.remove(.showsCopies)
                }
                if settings.showsPaperSize {
                    printOperation.printPanel.options.insert(.showsPaperSize)
                } else {
                    printOperation.printPanel.options.remove(.showsPaperSize)
                }
                if settings.showsScaling {
                    printOperation.printPanel.options.insert(.showsScaling)
                } else {
                    printOperation.printPanel.options.remove(.showsScaling)
                }
                if settings.showsPageRange {
                    printOperation.printPanel.options.insert(.showsPageRange)
                } else {
                    printOperation.printPanel.options.remove(.showsPageRange)
                }
                if settings.showsPageSetupAccessory {
                    printOperation.printPanel.options.insert(.showsPageSetupAccessory)
                } else {
                    printOperation.printPanel.options.remove(.showsPageSetupAccessory)
                }
                if settings.showsPreview {
                    printOperation.printPanel.options.insert(.showsPreview)
                } else {
                    printOperation.printPanel.options.remove(.showsPreview)
                }
                if settings.showsPrintSelection {
                    printOperation.printPanel.options.insert(.showsPrintSelection)
                } else {
                    printOperation.printPanel.options.remove(.showsPrintSelection)
                }
            }
            
            if let id = printJobId, let plugin = plugin {
                let printJob = PrintJobController(plugin: plugin, id: id, job: printOperation, settings: settings)
                plugin.printJobManager?.jobs[id] = printJob
                printJob.present(parentWindow: window, completionHandler: completionHandler)
            } else if let window = window {
                printJobCompletionHandler = completionHandler
                printOperation.runModal(for: window, delegate: self, didRun: #selector(printOperationDidRun), contextInfo: nil)
            } else {
                printView(self)
            }
            
            return printJobId
        } else {
            printView(self)
        }
        return nil
    }
    
    @objc func printOperationDidRun(printOperation: NSPrintOperation,
                                    success: Bool,
                                    contextInfo: UnsafeMutableRawPointer?) {
        if let completionHandler = printJobCompletionHandler {
            completionHandler(printOperation, success, contextInfo)
            printJobCompletionHandler = nil
        }
    }
    
    public func getContentHeight(completionHandler: @escaping ((Int64?, Error?) -> Void)) {
        evaluateJavaScript("document.body.scrollHeight") { scrollHeight, error in
            if let error = error {
                completionHandler(nil, error)
            } else {
                completionHandler(Int64(scrollHeight as? Double ?? 0.0), nil)
            }
        }
    }
    
    public func getContentWidth(completionHandler: @escaping ((Int64?, Error?) -> Void)) {
        evaluateJavaScript("document.body.scrollWidth") { scrollWidth, error in
            if let error = error {
                completionHandler(nil, error)
            } else {
                completionHandler(Int64(scrollWidth as? Double ?? 0.0), nil)
            }
        }
    }
    
    public func getOriginalUrl() -> URL? {
        return currentOriginalUrl
    }
    
    public func getSelectedText(completionHandler: @escaping (Any?, Error?) -> Void) {
        if configuration.preferences.javaScriptEnabled {
            evaluateJavaScript(PluginScriptsUtil.GET_SELECTED_TEXT_JS_SOURCE, completionHandler: completionHandler)
        } else {
            completionHandler(nil, nil)
        }
    }
    
    public func clearFocus() -> Bool {
        return (self.superview?.window ?? self.window)?.makeFirstResponder(nil) ?? false
    }

    public func requestFocus() -> Bool {
        return (self.superview?.window ?? self.window)?.makeFirstResponder(self) ?? false
    }
    
    public func getCertificate() -> SslCertificate? {
        guard let scheme = url?.scheme,
              scheme == "https",
              let host = url?.host,
              let sslCertificate = InAppWebView.sslCertificatesMap[host] else {
            return nil
        }
        return sslCertificate
    }
    
    public func isSecureContext(completionHandler: @escaping (_ isSecureContext: Bool) -> Void) {
        evaluateJavascript(source: "window.isSecureContext") { (isSecureContext) in
            if let isSecureContext = isSecureContext {
                completionHandler(isSecureContext as? Bool ?? false)
                return
            }
            completionHandler(false)
        }
    }
    
    public func canScrollVertically(completionHandler: @escaping ((Bool, Error?) -> Void)) {
        getContentHeight { contentHeight, error in
            if let error = error {
                completionHandler(false, error)
            } else {
                completionHandler(CGFloat(contentHeight ?? 0) > self.frame.height, nil)
            }
        }
    }
    
    public func canScrollHorizontally(completionHandler: @escaping ((Bool, Error?) -> Void)) {
        getContentWidth { contentWidth, error in
            if let error = error {
                completionHandler(false, error)
            } else {
                completionHandler(CGFloat(contentWidth ?? 0) > self.frame.width, nil)
            }
        }
    }
    
    public func createWebMessageChannel(completionHandler: ((WebMessageChannel?) -> Void)? = nil) -> WebMessageChannel? {
        guard let plugin = plugin else {
            completionHandler?(nil)
            return nil
        }
        let id = NSUUID().uuidString
        let webMessageChannel = WebMessageChannel(plugin: plugin, id: id)
        webMessageChannel.initJsInstance(webView: self, completionHandler: completionHandler)
        webMessageChannels[id] = webMessageChannel
        
        return webMessageChannel
    }
    
    public func postWebMessage(message: WebMessage, targetOrigin: String, completionHandler: ((Any?) -> Void)? = nil) throws {
        var portsString = "null"
        if let ports = message.ports {
            var portArrayString: [String] = []
            for port in ports {
                if port.isStarted {
                    throw NSError(domain: "Port is already started", code: 0)
                }
                if port.isClosed || port.isTransferred {
                    throw NSError(domain: "Port is already closed or transferred", code: 0)
                }
                port.isTransferred = true
                portArrayString.append("\(WebMessageChannelJS.WEB_MESSAGE_CHANNELS_VARIABLE_NAME())['\(port.webMessageChannel!.id)'].\(port.name)")
            }
            portsString = "[" + portArrayString.joined(separator: ", ") + "]"
        }
        
        let url = URL(string: targetOrigin)?.absoluteString ?? "*"
        let source = """
        (function() {
            window.postMessage(\(message.jsData), '\(url)', \(portsString));
        })();
        """
        evaluateJavascript(source: source, completionHandler: completionHandler)
        message.dispose()
    }
    
    public func addWebMessageListener(webMessageListener: WebMessageListener) throws {
        if webMessageListeners.map({ ($0.jsObjectName) }).contains(webMessageListener.jsObjectName) {
            throw NSError(domain: "jsObjectName \(webMessageListener.jsObjectName) was already added.", code: 0)
        }
        try webMessageListener.assertOriginRulesValid()
        webMessageListener.initJsInstance(webView: self)
        webMessageListeners.append(webMessageListener)
    }
    
    public func disposeWebMessageChannels() {
        for webMessageChannel in webMessageChannels.values {
            webMessageChannel.dispose()
        }
        webMessageChannels.removeAll()
    }
    
    public func getScrollX(completionHandler: @escaping ((Int64?, Error?) -> Void)) {
        evaluateJavaScript("window.scrollX") { scrollX, error in
            if let error = error {
                completionHandler(nil, error)
            } else {
                completionHandler(Int64(scrollX as? Double ?? 0.0), nil)
            }
        }
    }
    
    public func getScrollY(completionHandler: @escaping ((Int64?, Error?) -> Void)) {
        evaluateJavaScript("window.scrollY") { scrollY, error in
            if let error = error {
                completionHandler(nil, error)
            } else {
                completionHandler(Int64(scrollY as? Double ?? 0.0), nil)
            }
        }
    }
    
    @available(macOS 12.0, *)
    public func saveState() -> Data? {
        return interactionState is NSData || interactionState is Data ? interactionState as? Data : nil
    }
    
    @available(macOS 12.0, *)
    public func restoreState(state: Data) {
        interactionState = state
    }
    
    public func runWindowBeforeCreatedCallbacks() {
        let callbacks = windowBeforeCreatedCallbacks
        callbacks.forEach { (callback) in
            callback()
        }
        windowBeforeCreatedCallbacks.removeAll()
    }
    
    public func dispose() {
        channelDelegate?.dispose()
        channelDelegate = nil
        runWindowBeforeCreatedCallbacks()
        currentOpenPanel?.cancel(self)
        currentOpenPanel?.close()
        currentOpenPanel = nil
        printJobCompletionHandler = nil
        filePathDestination = nil
        removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
        removeObserver(self, forKeyPath: #keyPath(WKWebView.url))
        removeObserver(self, forKeyPath: #keyPath(WKWebView.title))
        if #available(macOS 12.0, *) {
            removeObserver(self, forKeyPath: #keyPath(WKWebView.cameraCaptureState))
            removeObserver(self, forKeyPath: #keyPath(WKWebView.microphoneCaptureState))
        }
        // TODO: Still not working on iOS 16.0!
//        if #available(iOS 16.0, *) {
//            removeObserver(self, forKeyPath: #keyPath(WKWebView.fullscreenState))
//        }
        resumeTimers()
        stopLoading()
        disposeWebMessageChannels()
        for webMessageListener in webMessageListeners {
            webMessageListener.dispose()
        }
        webMessageListeners.removeAll()
        interceptOnlyAsyncAjaxRequestsPluginScript = nil
        if windowId == nil {
            configuration.userContentController.removeAllPluginScriptMessageHandlers()
            configuration.userContentController.removeAllUserScripts()
            if #available(macOS 10.13, *) {
                configuration.userContentController.removeAllContentRuleLists()
            }
        } else if let wId = windowId, plugin?.inAppWebViewManager?.windowWebViews[wId] != nil {
            plugin?.inAppWebViewManager?.windowWebViews.removeValue(forKey: wId)
        }
        configuration.userContentController.dispose(windowId: windowId)
        NotificationCenter.default.removeObserver(self)
        for imp in customIMPs {
            imp_removeBlock(imp)
        }
        findInteractionController?.dispose()
        findInteractionController = nil
        uiDelegate = nil
        navigationDelegate = nil
        isPausedTimersCompletionHandler = nil
        callAsyncJavaScriptBelowMacOS11Results.removeAll()
        plugin = nil
    }
    
    deinit {
        debugPrint("InAppWebView - dealloc")
    }

    // 3. Add a method to start a download with progress tracking
    public func startTrackedDownload(url: URL, suggestedFilename: String?) {
        if urlSession == nil {
            let config = URLSessionConfiguration.default
            urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        }
        
        let task = urlSession!.downloadTask(with: url)
        activeDownloadTasks[url] = task
        activeDownloadProgress[url] = 0
        
        // Send start event
        let request = DownloadStartRequest(
            url: url.absoluteString,
            userAgent: nil,
            contentDisposition: nil,
            mimeType: nil,
            contentLength: 0,
            suggestedFilename: suggestedFilename,
            textEncodingName: nil
        )
        
        DispatchQueue.main.async {
            if let channelDelegate = self.channelDelegate {
                channelDelegate.onDownloadStarting(request: request)
            }
        }
        
        task.resume()
    }
}

extension InAppWebView: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let url = downloadTask.originalRequest?.url else { return }
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        activeDownloadProgress[url] = progress
        
        DispatchQueue.main.async {
            if let channelDelegate = self.channelDelegate {
                channelDelegate.onDownloadProgress(url: url.absoluteString, progress: progress, totalBytes: totalBytesExpectedToWrite, downloadedBytes: totalBytesWritten)
            }
        }
    }
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let url = downloadTask.originalRequest?.url else { return }
        let suggestedFilename = downloadTask.response?.suggestedFilename ?? url.lastPathComponent
        let downloadDirectory: URL
        if let downloadPath = settings?.downloadPath, !downloadPath.isEmpty {
            downloadDirectory = URL(fileURLWithPath: downloadPath)
        } else {
            downloadDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        }
        do {
            try FileManager.default.createDirectory(at: downloadDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create download directory: \(error.localizedDescription)")
        }
        let destinationURL = downloadDirectory.appendingPathComponent(suggestedFilename)
        do {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            let attributes = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            let totalBytes = (attributes[.size] as? NSNumber)?.int64Value
            DispatchQueue.main.async {
                self.channelDelegate?.onDownloadCompleted(
                    originalUrl: url.absoluteString,
                    suggestedFilename: suggestedFilename,
                    filePath: destinationURL.path,
                    mimeType: nil,
                    totalBytes: totalBytes,
                    isSuccessful: true,
                    error: nil
                )
            }
        } catch {
            DispatchQueue.main.async {
                self.channelDelegate?.onDownloadCompleted(
                    originalUrl: url.absoluteString,
                    suggestedFilename: suggestedFilename,
                    filePath: nil,
                    mimeType: nil,
                    totalBytes: nil,
                    isSuccessful: false,
                    error: error.localizedDescription
                )
            }
        }
        activeDownloadTasks.removeValue(forKey: url)
        activeDownloadProgress.removeValue(forKey: url)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let url = task.originalRequest?.url else { return }
        if let error = error {
            DispatchQueue.main.async {
                self.channelDelegate?.onDownloadCompleted(
                    originalUrl: url.absoluteString,
                    suggestedFilename: task.response?.suggestedFilename ?? url.lastPathComponent,
                    filePath: nil,
                    mimeType: task.response?.mimeType,
                    totalBytes: nil,
                    isSuccessful: false,
                    error: error.localizedDescription
                )
            }
        }
        activeDownloadTasks.removeValue(forKey: url)
        activeDownloadProgress.removeValue(forKey: url)
    }
}
