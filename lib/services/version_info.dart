import 'package:package_info_plus/package_info_plus.dart';

/// Provides version information injected at build time.
///
/// Priority:
/// 1. APP_VERSION (set by CI from the release tag)
/// 2. PackageInfo (version from pubspec.yaml)
/// 3. 'UNKNOWN'
class VersionInfo {
  static const String _appVersion = String.fromEnvironment('APP_VERSION');
  static String _packageVersion = '';

  /// Call at app startup to initialize PackageInfo.
  static Future<void> initialize() async {
    if (_appVersion.isEmpty) {
      final info = await PackageInfo.fromPlatform();
      _packageVersion = info.version;
    }
  }

  static String get version {
    if (_appVersion.isNotEmpty) return _appVersion;
    if (_packageVersion.isNotEmpty) return _packageVersion;
    return 'UNKNOWN';
  }
}
