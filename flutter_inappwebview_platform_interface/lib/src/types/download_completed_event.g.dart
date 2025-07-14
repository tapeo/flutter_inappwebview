// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'download_completed_event.dart';

// **************************************************************************
// ExchangeableObjectGenerator
// **************************************************************************

///Class representing a download completion event used by the [PlatformWebViewCreationParams.onDownloadCompleted] callback.
class DownloadCompletedEvent {
  ///Error message if the download failed.
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  String? error;

  ///The actual path where the file was saved.
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  String? filePath;

  ///Whether the download completed successfully.
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  bool isSuccessful;

  ///The MIME type of the downloaded file.
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  String? mimeType;

  ///The original URL of the download.
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  WebUri? originalUrl;

  ///The suggested filename for the download.
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  String? suggestedFilename;

  ///The total number of bytes downloaded.
  ///
  ///**Officially Supported Platforms/Implementations**:
  ///- MacOS
  int? totalBytes;
  DownloadCompletedEvent(
      {this.error,
      this.filePath,
      required this.isSuccessful,
      this.mimeType,
      this.originalUrl,
      this.suggestedFilename,
      this.totalBytes});

  ///Gets a possible [DownloadCompletedEvent] instance from a [Map] value.
  static DownloadCompletedEvent? fromMap(Map<String, dynamic>? map,
      {EnumMethod? enumMethod}) {
    if (map == null) {
      return null;
    }
    final instance = DownloadCompletedEvent(
      error: map['error'],
      filePath: map['filePath'],
      isSuccessful: map['isSuccessful'],
      mimeType: map['mimeType'],
      originalUrl:
          map['originalUrl'] != null ? WebUri(map['originalUrl']) : null,
      suggestedFilename: map['suggestedFilename'],
      totalBytes: map['totalBytes'],
    );
    return instance;
  }

  ///Converts instance to a map.
  Map<String, dynamic> toMap({EnumMethod? enumMethod}) {
    return {
      "error": error,
      "filePath": filePath,
      "isSuccessful": isSuccessful,
      "mimeType": mimeType,
      "originalUrl": originalUrl?.toString(),
      "suggestedFilename": suggestedFilename,
      "totalBytes": totalBytes,
    };
  }

  ///Converts instance to a map.
  Map<String, dynamic> toJson() {
    return toMap();
  }

  @override
  String toString() {
    return 'DownloadCompletedEvent{error: $error, filePath: $filePath, isSuccessful: $isSuccessful, mimeType: $mimeType, originalUrl: $originalUrl, suggestedFilename: $suggestedFilename, totalBytes: $totalBytes}';
  }
}
