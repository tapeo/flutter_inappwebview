import 'dart:async';

import 'package:flutter/services.dart';

/// A utility class for managing WebView profiles using WKWebsiteDataStore identifiers.
///
/// Profiles allow you to create separate WebView instances with isolated data stores.
/// Each profile has its own cookies, local storage, cache, and other website data.
///
/// When `profileId` is set to a non-empty string, a profile-specific data store is used.
/// If the string is a valid UUID, it will be used directly. Otherwise, a deterministic
/// UUID will be generated from the string.
///
/// When `profileId` is null or empty, the WebView falls back to the default behavior
/// (using `cacheEnabled` and `incognito` settings).
///
/// This feature is only available on iOS 17.0+ and macOS 14.0+.
class WebViewProfiles {
  static const MethodChannel _channel =
      MethodChannel('com.pichillilorenzo/flutter_inappwebview_profile_manager');

  /// Creates a new profile with the given [profileId].
  ///
  /// The [profileId] can be any non-empty string.
  ///
  /// Returns `true` if the profile was created successfully, `false` otherwise.
  ///
  /// Example:
  /// ```dart
  /// final profileId = 'user_profile_123';
  /// final success = await WebViewProfiles.createProfile(profileId);
  /// ```
  static Future<bool> createProfile(String profileId) async {
    try {
      final result = await _channel.invokeMethod('createProfile', {
        'profileId': profileId,
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Deletes the profile with the given [profileId].
  ///
  /// This will remove all data associated with the profile including cookies,
  /// local storage, cache, and other website data.
  ///
  /// Returns `true` if the profile was deleted successfully, `false` otherwise.
  ///
  /// Example:
  /// ```dart
  /// final success = await WebViewProfiles.deleteProfile(profileId);
  /// ```
  static Future<bool> deleteProfile(String profileId) async {
    try {
      final result = await _channel.invokeMethod('deleteProfile', {
        'profileId': profileId,
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Returns a list of all existing profile IDs.
  ///
  /// Example:
  /// ```dart
  /// final profileIds = await WebViewProfiles.listProfiles();
  /// print('Available profiles: $profileIds');
  /// ```
  static Future<List<String>> listProfiles() async {
    try {
      final result = await _channel.invokeMethod('listProfiles');
      if (result is List) {
        return result.cast<String>();
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  /// Checks if a profile with the given [profileId] exists.
  ///
  /// Returns `true` if the profile exists, `false` otherwise.
  ///
  /// Example:
  /// ```dart
  /// final exists = await WebViewProfiles.profileExists(profileId);
  /// if (exists) {
  ///   print('Profile exists');
  /// }
  /// ```
  static Future<bool> profileExists(String profileId) async {
    try {
      final result = await _channel.invokeMethod('profileExists', {
        'profileId': profileId,
      });
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Deletes all existing profiles.
  ///
  /// This will remove all data associated with all profiles.
  /// Use with caution as this operation cannot be undone.
  ///
  /// Returns `true` if all profiles were deleted successfully, `false` otherwise.
  ///
  /// Example:
  /// ```dart
  /// final success = await WebViewProfiles.deleteAllProfiles();
  /// ```
  static Future<bool> deleteAllProfiles() async {
    try {
      final result = await _channel.invokeMethod('deleteAllProfiles');
      return result == true;
    } catch (e) {
      return false;
    }
  }

  /// Validates if the given [profileId] is a valid profile identifier.
  ///
  /// Returns `true` if the profile ID is valid (non-empty string), `false` otherwise.
  ///
  /// Example:
  /// ```dart
  /// final isValid = WebViewProfiles.isValidProfileId(profileId);
  /// ```
  static bool isValidProfileId(String profileId) {
    return profileId.isNotEmpty;
  }
}
