//
//  InAppWebViewDownloadManager.swift
//  flutter_inappwebview
//

import AppKit
import Foundation
@preconcurrency import WebKit
import UniformTypeIdentifiers

final class InAppWebViewDownloadManager: NSObject, WKDownloadDelegate {
    private weak var webView: InAppWebView?
    private var activeWKDownloads: [ObjectIdentifier: WKDownloadInfo] = [:]
    private var completedDownloadPaths: [String: URL] = [:]

    private class WKDownloadInfo {
        let destinationURL: URL
        let suggestedFilename: String
        let originalUrl: String?
        var mimeType: String?
        var expectedBytes: Int64?
        var downloadedBytes: Int64 = 0
        var contentDisposition: String?
        var textEncodingName: String?
        var progressObservation: NSKeyValueObservation?

        init(destinationURL: URL, suggestedFilename: String, originalUrl: String?) {
            self.destinationURL = destinationURL
            self.suggestedFilename = suggestedFilename
            self.originalUrl = originalUrl
        }
    }

    init(webView: InAppWebView) {
        self.webView = webView
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        showSavePanelForDownload(suggestedFilename: suggestedFilename, mimeType: response.mimeType) { [weak self] selectedURL in
            guard let self = self else {
                completionHandler(nil)
                return
            }

            guard let destinationURL = selectedURL else {
                completionHandler(nil)
                return
            }

            self.prepareWebKitDownload(download, response: response, destinationURL: destinationURL, suggestedFilename: suggestedFilename)
            completionHandler(destinationURL)
        }
    }

    func download(_ download: WKDownload, didReceive response: URLResponse) {
        let downloadId = ObjectIdentifier(download)
        guard let info = activeWKDownloads[downloadId] else {
            return
        }

        if let mimeType = response.mimeType {
            info.mimeType = mimeType
        }

        let expectedLength = response.expectedContentLength
        if expectedLength > 0 {
            info.expectedBytes = expectedLength
        }

        if let textEncodingName = response.textEncodingName {
            info.textEncodingName = textEncodingName
        }

        if let httpResponse = response as? HTTPURLResponse,
           let disposition = contentDispositionHeader(from: httpResponse) {
            info.contentDisposition = disposition
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let downloadId = ObjectIdentifier(download)
        guard let info = activeWKDownloads[downloadId] else {
            return
        }

        info.progressObservation?.invalidate()
        activeWKDownloads.removeValue(forKey: downloadId)

        var isSuccessful = true
        var errorMessage: String?
        var totalBytes: Int64?

        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: info.destinationURL.path)
            totalBytes = (attributes[.size] as? NSNumber)?.int64Value
            if let expectedBytes = info.expectedBytes,
               let actualBytes = totalBytes,
               expectedBytes > 0,
               expectedBytes != actualBytes {
                isSuccessful = false
                errorMessage = "File size mismatch. Expected \(expectedBytes) bytes, got \(actualBytes) bytes."
                try? FileManager.default.removeItem(at: info.destinationURL)
            } else if let originalUrl = info.originalUrl {
                completedDownloadPaths[originalUrl] = info.destinationURL
            }
        } catch {
            isSuccessful = false
            errorMessage = error.localizedDescription
        }

        let originalUrl = info.originalUrl
        let suggestedFilename = info.suggestedFilename
        let mimeType = info.mimeType
        let filePath = isSuccessful ? info.destinationURL.path : nil
        let totalBytesValue = totalBytes

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.webView else { return }
            webView.channelDelegate?.onDownloadCompleted(
                originalUrl: originalUrl,
                suggestedFilename: suggestedFilename,
                filePath: filePath,
                mimeType: mimeType,
                totalBytes: totalBytesValue,
                isSuccessful: isSuccessful,
                error: errorMessage
            )
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let downloadId = ObjectIdentifier(download)
        guard let info = activeWKDownloads[downloadId] else {
            return
        }

        info.progressObservation?.invalidate()
        activeWKDownloads.removeValue(forKey: downloadId)

        if FileManager.default.fileExists(atPath: info.destinationURL.path) {
            try? FileManager.default.removeItem(at: info.destinationURL)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.webView else { return }
            webView.channelDelegate?.onDownloadCompleted(
                originalUrl: info.originalUrl,
                suggestedFilename: info.suggestedFilename,
                filePath: nil,
                mimeType: info.mimeType,
                totalBytes: nil,
                isSuccessful: false,
                error: error.localizedDescription
            )
        }
    }

    func getDownloadedFilePath(for originalUrl: String) -> String? {
        completedDownloadPaths[originalUrl]?.path
    }

    private func prepareWebKitDownload(_ download: WKDownload, response: URLResponse, destinationURL: URL, suggestedFilename: String) {
        let downloadId = ObjectIdentifier(download)
        let resolvedSuggestedFilename = suggestedFilename.isEmpty ? destinationURL.lastPathComponent : suggestedFilename
        let resolvedOriginalURL = download.originalRequest?.url ?? response.url ?? destinationURL

        let info = WKDownloadInfo(destinationURL: destinationURL, suggestedFilename: resolvedSuggestedFilename, originalUrl: resolvedOriginalURL.absoluteString)
        info.mimeType = response.mimeType
        let expectedLength = response.expectedContentLength
        if expectedLength > 0 {
            info.expectedBytes = expectedLength
        }
        info.textEncodingName = response.textEncodingName
        if let httpResponse = response as? HTTPURLResponse {
            info.contentDisposition = contentDispositionHeader(from: httpResponse)
        }

        completedDownloadPaths.removeValue(forKey: resolvedOriginalURL.absoluteString)

        let observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      let info = self.activeWKDownloads[downloadId],
                      let webView = self.webView else { return }

                if progress.totalUnitCount > 0 && info.expectedBytes == nil {
                    info.expectedBytes = progress.totalUnitCount
                }

                let downloadedBytes = progress.completedUnitCount
                info.downloadedBytes = downloadedBytes
                let totalBytes = info.expectedBytes ?? (progress.totalUnitCount > 0 ? progress.totalUnitCount : -1)
                let progressValue: Double
                if totalBytes > 0 {
                    progressValue = Double(downloadedBytes) / Double(totalBytes)
                } else {
                    progressValue = progress.fractionCompleted
                }

                let progressUrl = info.originalUrl ?? destinationURL.absoluteString
                webView.channelDelegate?.onDownloadProgress(
                    url: progressUrl,
                    progress: progressValue.isFinite ? progressValue : 0,
                    totalBytes: totalBytes,
                    downloadedBytes: downloadedBytes
                )
            }
        }

        info.progressObservation = observation
        activeWKDownloads[downloadId]?.progressObservation?.invalidate()
        activeWKDownloads[downloadId] = info

        let contentLength = info.expectedBytes ?? -1
        let request = DownloadStartRequest(
            url: info.originalUrl ?? destinationURL.absoluteString,
            userAgent: download.originalRequest?.value(forHTTPHeaderField: "User-Agent"),
            contentDisposition: info.contentDisposition,
            mimeType: info.mimeType,
            contentLength: contentLength > 0 ? contentLength : 0,
            suggestedFilename: info.suggestedFilename,
            textEncodingName: info.textEncodingName
        )

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let webView = self.webView else { return }
            webView.channelDelegate?.onDownloadStarting(request: request)
        }
    }

    private func contentDispositionHeader(from response: HTTPURLResponse) -> String? {
        for (key, value) in response.allHeaderFields {
            if let keyString = key as? String,
               keyString.caseInsensitiveCompare("Content-Disposition") == .orderedSame {
                return value as? String
            }
        }
        return nil
    }

    private func showSavePanelForDownload(suggestedFilename: String, mimeType: String?, completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.async {
            let savePanel = NSSavePanel()
            savePanel.title = "Save File"
            savePanel.prompt = "Save"
            savePanel.nameFieldStringValue = suggestedFilename.isEmpty ? "download" : suggestedFilename

            if let mimeType = mimeType {
                let fileExtension = self.getFileExtensionForMimeType(mimeType)
                if !fileExtension.isEmpty {
                    savePanel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? UTType.data]
                }
            }

            if let downloadsDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                savePanel.directoryURL = downloadsDirectory
            }

            savePanel.begin { response in
                if response == .OK {
                    completion(savePanel.url)
                } else {
                    completion(nil)
                }
            }
        }
    }

    private func getFileExtensionForMimeType(_ mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png":
            return "png"
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        case "image/svg+xml":
            return "svg"
        case "application/pdf":
            return "pdf"
        case "text/plain":
            return "txt"
        case "text/html":
            return "html"
        case "text/css":
            return "css"
        case "text/javascript", "application/javascript":
            return "js"
        case "application/json":
            return "json"
        case "application/xml", "text/xml":
            return "xml"
        case "application/zip":
            return "zip"
        case "application/x-rar-compressed":
            return "rar"
        case "application/x-7z-compressed":
            return "7z"
        case "video/mp4":
            return "mp4"
        case "video/webm":
            return "webm"
        case "video/quicktime":
            return "mov"
        case "audio/mpeg":
            return "mp3"
        case "audio/wav":
            return "wav"
        case "audio/ogg":
            return "ogg"
        default:
            return ""
        }
    }
}
