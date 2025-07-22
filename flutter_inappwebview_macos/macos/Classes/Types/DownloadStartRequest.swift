//
//  DownloadStartRequest.swift
//  flutter_inappwebview
//
//  Created by Lorenzo Pichilli on 17/04/22.
//

import Foundation

public class DownloadStartRequest: NSObject {
    public var url: String
    public var userAgent: String?
    public var contentDisposition: String?
    public var mimeType: String?
    public var contentLength: Int64
    public var suggestedFilename: String?
    public var textEncodingName: String?
    
    public init(url: String, userAgent: String?, contentDisposition: String?,
                mimeType: String?, contentLength: Int64,
                suggestedFilename: String?, textEncodingName: String?) {
        self.url = url
        self.userAgent = userAgent
        self.contentDisposition = contentDisposition
        self.mimeType = mimeType
        self.contentLength = contentLength
        self.suggestedFilename = suggestedFilename
        self.textEncodingName = textEncodingName
    }
    
    public func toMap () -> [String:Any?] {
        return [
            "url": url,
            "userAgent": userAgent,
            "contentDisposition": contentDisposition,
            "mimeType": mimeType,
            "contentLength": contentLength,
            "suggestedFilename": suggestedFilename,
            "textEncodingName": textEncodingName
        ]
    }
}
