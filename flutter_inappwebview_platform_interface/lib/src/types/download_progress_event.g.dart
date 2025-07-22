// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'download_progress_event.dart';

// **************************************************************************
// ExchangeableObjectGenerator
// **************************************************************************

///Class representing a download progress event used by the [PlatformWebViewCreationParams.onDownloadProgress] callback.
class DownloadProgressEvent {
  ///The number of bytes downloaded so far.
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  int? downloadedBytes;

  ///The progress value (0.0 to 1.0).
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  double? progress;

  ///The total number of bytes expected to download.
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  int? totalBytes;

  ///The original URL of the download.
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  WebUri? url;
  DownloadProgressEvent(
      {this.downloadedBytes, this.progress, this.totalBytes, this.url});

  ///Gets a possible [DownloadProgressEvent] instance from a [Map] value.
  static DownloadProgressEvent? fromMap(Map<String, dynamic>? map,
      {EnumMethod? enumMethod}) {
    if (map == null) {
      return null;
    }
    final instance = DownloadProgressEvent(
      downloadedBytes: map['downloadedBytes'],
      progress: map['progress'],
      totalBytes: map['totalBytes'],
      url: map['url'] != null ? WebUri(map['url']) : null,
    );
    return instance;
  }

  ///Converts instance to a map.
  Map<String, dynamic> toMap({EnumMethod? enumMethod}) {
    return {
      "downloadedBytes": downloadedBytes,
      "progress": progress,
      "totalBytes": totalBytes,
      "url": url?.toString(),
    };
  }

  ///Converts instance to a map.
  Map<String, dynamic> toJson() {
    return toMap();
  }

  @override
  String toString() {
    return 'DownloadProgressEvent{downloadedBytes: $downloadedBytes, progress: $progress, totalBytes: $totalBytes, url: $url}';
  }
}
