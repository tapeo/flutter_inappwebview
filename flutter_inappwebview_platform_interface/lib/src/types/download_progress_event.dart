import 'package:flutter_inappwebview_internal_annotations/flutter_inappwebview_internal_annotations.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';

part 'download_progress_event.g.dart';

///Class representing a download progress event used by the [PlatformWebViewCreationParams.onDownloadProgress] callback.
@ExchangeableObject()
class DownloadProgressEvent_ {
  ///The original URL of the download.
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  WebUri? url;

  ///The progress value (0.0 to 1.0).
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  double? progress;

  ///The total number of bytes expected to download.
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  int? totalBytes;

  ///The number of bytes downloaded so far.
  @SupportedPlatforms(platforms: [
    MacOSPlatform(),
  ])
  int? downloadedBytes;

  DownloadProgressEvent_(
      {this.url, this.progress, this.totalBytes, this.downloadedBytes});
}
