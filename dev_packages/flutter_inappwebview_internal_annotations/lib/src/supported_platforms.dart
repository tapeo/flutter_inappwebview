abstract class Platform {
  final String? available;
  final String? apiName;
  final String? apiUrl;
  final String? note;

  const Platform({this.available, this.apiName, this.apiUrl, this.note});

  final name = "";
  final targetPlatformName = "";
}

class AndroidPlatform implements Platform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;

  const AndroidPlatform({this.available, this.apiName, this.apiUrl, this.note});

  @override
  final name = "Android native WebView";
  @override
  final targetPlatformName = "android";
}

class IOSPlatform implements Platform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;

  const IOSPlatform({this.available, this.apiName, this.apiUrl, this.note});

  @override
  final name = "iOS";
  @override
  final targetPlatformName = "iOS";
}

class MacOSPlatform implements Platform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;

  const MacOSPlatform({this.available, this.apiName, this.apiUrl, this.note});

  @override
  final name = "MacOS";
  @override
  final targetPlatformName = "macOS";
}

class WindowsPlatform implements Platform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;

  const WindowsPlatform({this.available, this.apiName, this.apiUrl, this.note});

  @override
  final name = "Windows";
  @override
  final targetPlatformName = "windows";
}

class LinuxPlatform implements Platform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;

  const LinuxPlatform({this.available, this.apiName, this.apiUrl, this.note});

  @override
  final name = "Linux";
  @override
  final targetPlatformName = "linux";
}

class WebPlatform implements Platform {
  @override
  final String? available;
  @override
  final String? apiName;
  @override
  final String? apiUrl;
  @override
  final String? note;
  final bool requiresSameOrigin;

  const WebPlatform(
      {this.available,
      this.apiName,
      this.apiUrl,
      this.note,
      this.requiresSameOrigin = true});

  @override
  final name = "Web";
  @override
  final targetPlatformName = "web";
}

class SupportedPlatforms {
  final List<Platform> platforms;

  const SupportedPlatforms({required this.platforms});
}
