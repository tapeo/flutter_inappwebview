import 'package:flutter_inappwebview_internal_annotations/flutter_inappwebview_internal_annotations.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';

part 'download_completed_event.g.dart';

///Class representing a download completion event used by the [PlatformWebViewCreationParams.onDownloadCompleted] callback.
@ExchangeableObject()
class DownloadCompletedEvent_ {
  ///The original URL of the download.
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  WebUri? originalUrl;

  ///The suggested filename for the download.
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  String? suggestedFilename;

  ///The actual path where the file was saved.
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  String? filePath;

  ///The MIME type of the downloaded file.
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  String? mimeType;

  ///The total number of bytes downloaded.
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  int? totalBytes;

  ///Whether the download completed successfully.
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  bool isSuccessful;

  ///Error message if the download failed.
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  String? error;

  DownloadCompletedEvent_(
      {this.originalUrl,
      this.suggestedFilename,
      this.filePath,
      this.mimeType,
      this.totalBytes,
      required this.isSuccessful,
      this.error});
}
