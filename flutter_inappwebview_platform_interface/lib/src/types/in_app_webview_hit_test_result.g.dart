// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'in_app_webview_hit_test_result.dart';

// **************************************************************************
// ExchangeableObjectGenerator
// **************************************************************************

///Class that represents the hit result for hitting an HTML elements.
class InAppWebViewHitTestResult {
  ///Additional type-dependant information about the result.
  String? extra;

  ///The type of the hit test result.
  InAppWebViewHitTestResultType? type;

  ///The x coordinate of the hit test result.
  double? x;

  ///The y coordinate of the hit test result.
  double? y;
  
  InAppWebViewHitTestResult({this.extra, this.type, this.x, this.y});

  ///Gets a possible [InAppWebViewHitTestResult] instance from a [Map] value.
  static InAppWebViewHitTestResult? fromMap(Map<String, dynamic>? map,
      {EnumMethod? enumMethod}) {
    if (map == null) {
      return null;
    }
    final instance = InAppWebViewHitTestResult(
      extra: map['extra'],
      type: switch (enumMethod ?? EnumMethod.nativeValue) {
        EnumMethod.nativeValue =>
          InAppWebViewHitTestResultType.fromNativeValue(map['type']),
        EnumMethod.value =>
          InAppWebViewHitTestResultType.fromValue(map['type']),
        EnumMethod.name => InAppWebViewHitTestResultType.byName(map['type'])
      },
      x: map['x']?.toDouble(),
      y: map['y']?.toDouble(),
    );
    return instance;
  }

  ///Converts instance to a map.
  Map<String, dynamic> toMap({EnumMethod? enumMethod}) {
    return {
      "extra": extra,
      "type": switch (enumMethod ?? EnumMethod.nativeValue) {
        EnumMethod.nativeValue => type?.toNativeValue(),
        EnumMethod.value => type?.toValue(),
        EnumMethod.name => type?.name()
      },
      "x": x,
      "y": y,
    };
  }

  ///Converts instance to a map.
  Map<String, dynamic> toJson() {
    return toMap();
  }

  @override
  String toString() {
    return 'InAppWebViewHitTestResult{extra: $extra, type: $type, x: $x, y: $y}';
  }
}
