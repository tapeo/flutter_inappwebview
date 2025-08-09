import 'supported_platforms.dart';

abstract class EnumPlatform implements Platform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;
  final dynamic value;

  const EnumPlatform(
      {this.available, this.apiName, this.apiUrl, this.note, this.value});

  @override
  final name = "";
  @override
  final targetPlatformName = "";
}

class EnumAndroidPlatform implements EnumPlatform, AndroidPlatform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;
  @override
  final dynamic value;

  const EnumAndroidPlatform(
      {this.available, this.apiName, this.apiUrl, this.note, this.value});

  @override
  final name = "Android native WebView";
  @override
  final targetPlatformName = "android";
}

class EnumIOSPlatform implements EnumPlatform, IOSPlatform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;
  @override
  final dynamic value;

  const EnumIOSPlatform(
      {this.available, this.apiName, this.apiUrl, this.note, this.value});

  @override
  final name = "iOS";
  @override
  final targetPlatformName = "iOS";
}

class EnumMacOSPlatform implements EnumPlatform, MacOSPlatform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;
  @override
  final dynamic value;

  const EnumMacOSPlatform(
      {this.available, this.apiName, this.apiUrl, this.note, this.value});

  @override
  final name = "MacOS";
  @override
  final targetPlatformName = "macOS";
}

class EnumWindowsPlatform implements EnumPlatform, WindowsPlatform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;
  @override
  final dynamic value;

  const EnumWindowsPlatform(
      {this.available, this.apiName, this.apiUrl, this.note, this.value});

  @override
  final name = "Windows";
  @override
  final targetPlatformName = "windows";
}

class EnumLinuxPlatform implements EnumPlatform, LinuxPlatform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;
  @override
  final dynamic value;

  const EnumLinuxPlatform(
      {this.available, this.apiName, this.apiUrl, this.note, this.value});

  @override
  final name = "Linux";
  @override
  final targetPlatformName = "linux";
}

class EnumWebPlatform implements EnumPlatform, WebPlatform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;
  @override
  final dynamic value;
  @override
  final bool requiresSameOrigin;

  const EnumWebPlatform(
      {this.available,
      this.apiName,
      this.apiUrl,
      this.note,
      this.value,
      this.requiresSameOrigin = true});

  @override
  final name = "Web";
  @override
  final targetPlatformName = "web";
}

class EnumSupportedPlatforms {
  final List<EnumPlatform> platforms;
  final dynamic defaultValue;

  const EnumSupportedPlatforms({
    required this.platforms,
    this.defaultValue,
  });
}
