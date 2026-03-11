import 'package:package_info_plus/package_info_plus.dart';

/// ビルド時に注入されるバージョン情報を提供する。
///
/// 優先順位:
/// 1. APP_VERSION (CIがリリースタグから設定)
/// 2. PackageInfo (pubspec.yamlのversion)
/// 3. 'UNKNOWN'
class VersionInfo {
  static const String _appVersion = String.fromEnvironment('APP_VERSION');
  static String _packageVersion = '';

  /// アプリ起動時に呼び出してPackageInfoを初期化する。
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
