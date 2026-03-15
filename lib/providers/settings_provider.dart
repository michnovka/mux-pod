import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/storage/versioned_json_storage.dart';
import 'shared_preferences_provider.dart';

/// App settings
class AppSettings {
  final bool darkMode;
  final double fontSize;
  final String fontFamily;
  final bool enableNotifications;
  final bool enableVibration;
  final bool keepScreenOn;
  final int scrollbackLines;
  final double minFontSize;
  final bool autoFitEnabled;

  /// Direct input mode (immediately sends typed characters to the terminal)
  final bool directInputEnabled;

  /// Terminal cursor visibility setting
  final bool showTerminalCursor;

  /// Invert pane navigation direction
  final bool invertPaneNavigation;

  const AppSettings({
    this.darkMode = true,
    this.fontSize = 14.0,
    this.fontFamily = 'JetBrains Mono',
    this.enableNotifications = true,
    this.enableVibration = true,
    this.keepScreenOn = true,
    this.scrollbackLines = 10000,
    this.minFontSize = 8.0,
    this.autoFitEnabled = true,
    this.directInputEnabled = false,
    this.showTerminalCursor = true,
    this.invertPaneNavigation = false,
  });

  AppSettings copyWith({
    bool? darkMode,
    double? fontSize,
    String? fontFamily,
    bool? enableNotifications,
    bool? enableVibration,
    bool? keepScreenOn,
    int? scrollbackLines,
    double? minFontSize,
    bool? autoFitEnabled,
    bool? directInputEnabled,
    bool? showTerminalCursor,
    bool? invertPaneNavigation,
  }) {
    return AppSettings(
      darkMode: darkMode ?? this.darkMode,
      fontSize: fontSize ?? this.fontSize,
      fontFamily: fontFamily ?? this.fontFamily,
      enableNotifications: enableNotifications ?? this.enableNotifications,
      enableVibration: enableVibration ?? this.enableVibration,
      keepScreenOn: keepScreenOn ?? this.keepScreenOn,
      scrollbackLines: scrollbackLines ?? this.scrollbackLines,
      minFontSize: minFontSize ?? this.minFontSize,
      autoFitEnabled: autoFitEnabled ?? this.autoFitEnabled,
      directInputEnabled: directInputEnabled ?? this.directInputEnabled,
      showTerminalCursor: showTerminalCursor ?? this.showTerminalCursor,
      invertPaneNavigation: invertPaneNavigation ?? this.invertPaneNavigation,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'darkMode': darkMode,
      'fontSize': fontSize,
      'fontFamily': fontFamily,
      'enableNotifications': enableNotifications,
      'enableVibration': enableVibration,
      'keepScreenOn': keepScreenOn,
      'scrollbackLines': scrollbackLines,
      'minFontSize': minFontSize,
      'autoFitEnabled': autoFitEnabled,
      'directInputEnabled': directInputEnabled,
      'showTerminalCursor': showTerminalCursor,
      'invertPaneNavigation': invertPaneNavigation,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      darkMode: json['darkMode'] as bool? ?? true,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14.0,
      fontFamily: json['fontFamily'] as String? ?? 'JetBrains Mono',
      enableNotifications: json['enableNotifications'] as bool? ?? true,
      enableVibration: json['enableVibration'] as bool? ?? true,
      keepScreenOn: json['keepScreenOn'] as bool? ?? true,
      scrollbackLines: json['scrollbackLines'] as int? ?? 10000,
      minFontSize: (json['minFontSize'] as num?)?.toDouble() ?? 8.0,
      autoFitEnabled: json['autoFitEnabled'] as bool? ?? true,
      directInputEnabled: json['directInputEnabled'] as bool? ?? false,
      showTerminalCursor: json['showTerminalCursor'] as bool? ?? true,
      invertPaneNavigation: json['invertPaneNavigation'] as bool? ?? false,
    );
  }
}

/// Notifier that manages settings
class SettingsNotifier extends Notifier<AppSettings> {
  static const String _storageKey = 'settings';
  static const String _darkModeKey = 'settings_dark_mode';
  static const String _fontSizeKey = 'settings_font_size';
  static const String _fontFamilyKey = 'settings_font_family';
  static const String _notificationsKey = 'settings_notifications';
  static const String _vibrationKey = 'settings_vibration';
  static const String _keepScreenOnKey = 'settings_keep_screen_on';
  static const String _scrollbackKey = 'settings_scrollback';
  static const String _minFontSizeKey = 'settings_min_font_size';
  static const String _autoFitEnabledKey = 'settings_auto_fit_enabled';
  static const String _directInputEnabledKey = 'settings_direct_input_enabled';
  static const String _showTerminalCursorKey = 'settings_show_terminal_cursor';
  static const String _invertPaneNavKey = 'settings_invert_pane_nav';
  static const List<String> _legacySettingsKeys = [
    _darkModeKey,
    _fontSizeKey,
    _fontFamilyKey,
    'settings_biometric_auth', // removed setting; still needs cleanup
    _notificationsKey,
    _vibrationKey,
    _keepScreenOnKey,
    _scrollbackKey,
    _minFontSizeKey,
    _autoFitEnabledKey,
    _directInputEnabledKey,
    _showTerminalCursorKey,
    _invertPaneNavKey,
  ];
  final Completer<void> _initialLoadCompleter = Completer<void>();
  SharedPreferences? _sharedPreferences;

  @override
  AppSettings build() {
    final prefs = _sharedPreferences = ref.read(sharedPreferencesProvider);
    if (prefs != null) {
      AppSettings settings;
      try {
        settings = _loadSettingsSync(prefs);
      } catch (e, stackTrace) {
        developer.log(
          'Failed to load settings, using defaults: $e',
          name: 'SettingsProvider',
          error: e,
          stackTrace: stackTrace,
        );
        settings = const AppSettings();
      }
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
      return settings;
    }

    _loadSettings();
    return const AppSettings();
  }

  AppSettings _loadSettingsSync(SharedPreferences prefs) {
    final jsonString = prefs.getString(_storageKey);
    if (jsonString != null) {
      try {
        final loaded = decodeVersionedJsonEnvelope<AppSettings>(
          raw: jsonString,
          storageKey: _storageKey,
          versionReaders: {
            sharedPreferencesSchemaVersion1: (data) =>
                AppSettings.fromJson(data as Map<String, dynamic>),
          },
        );
        return loaded.value;
      } catch (e) {
        if (!_hasLegacySettingsKeys(prefs)) {
          rethrow;
        }
        if (kDebugMode) {
          debugPrint('[SettingsNotifier] versioned JSON decode failed, trying legacy: $e');
        }
      }
    }

    final settings = _loadLegacySettings(prefs);
    if (_hasLegacySettingsKeys(prefs)) {
      unawaited(_persistSettingsValue(prefs, settings));
    }
    return settings;
  }

  AppSettings _loadLegacySettings(SharedPreferences prefs) {
    return AppSettings(
      darkMode: prefs.getBool(_darkModeKey) ?? true,
      fontSize: prefs.getDouble(_fontSizeKey) ?? 14.0,
      fontFamily: prefs.getString(_fontFamilyKey) ?? 'JetBrains Mono',
      enableNotifications: prefs.getBool(_notificationsKey) ?? true,
      enableVibration: prefs.getBool(_vibrationKey) ?? true,
      keepScreenOn: prefs.getBool(_keepScreenOnKey) ?? true,
      scrollbackLines: prefs.getInt(_scrollbackKey) ?? 10000,
      minFontSize: prefs.getDouble(_minFontSizeKey) ?? 8.0,
      autoFitEnabled: prefs.getBool(_autoFitEnabledKey) ?? true,
      directInputEnabled: prefs.getBool(_directInputEnabledKey) ?? false,
      showTerminalCursor: prefs.getBool(_showTerminalCursorKey) ?? true,
      invertPaneNavigation: prefs.getBool(_invertPaneNavKey) ?? false,
    );
  }

  Future<SharedPreferences> _getPrefs() async {
    final prefs = _sharedPreferences;
    if (prefs != null) {
      return prefs;
    }

    final loadedPrefs = await SharedPreferences.getInstance();
    _sharedPreferences = loadedPrefs;
    return loadedPrefs;
  }

  Future<void> _loadSettings() async {
    try {
      state = _loadSettingsSync(await _getPrefs());
    } catch (e, stackTrace) {
      developer.log(
        'Failed to async-load settings, using defaults: $e',
        name: 'SettingsProvider',
        error: e,
        stackTrace: stackTrace,
      );
      state = const AppSettings();
    } finally {
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
    }
  }

  bool _hasLegacySettingsKeys(SharedPreferences prefs) {
    for (final key in _legacySettingsKeys) {
      if (prefs.containsKey(key)) {
        return true;
      }
    }
    return false;
  }

  Future<void> _waitForInitialLoad() => _initialLoadCompleter.future;

  Future<void> _saveSettings() async {
    await _persistSettingsValue(await _getPrefs(), state);
  }

  Future<void> _persistSettingsValue(
    SharedPreferences prefs,
    AppSettings settings,
  ) async {
    await prefs.setString(
      _storageKey,
      encodeVersionedJsonEnvelope(settings.toJson()),
    );
    await _removeLegacySettingsKeys(prefs);
  }

  Future<void> _removeLegacySettingsKeys(SharedPreferences prefs) async {
    await Future.wait(_legacySettingsKeys.map(prefs.remove));
  }

  /// Set dark mode
  Future<void> setDarkMode(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(darkMode: value);
    await _saveSettings();
  }

  /// Set font size
  Future<void> setFontSize(double value) async {
    await _waitForInitialLoad();
    state = state.copyWith(fontSize: value);
    await _saveSettings();
  }

  /// Set font family
  Future<void> setFontFamily(String value) async {
    await _waitForInitialLoad();
    state = state.copyWith(fontFamily: value);
    await _saveSettings();
  }

  /// Set notifications
  Future<void> setEnableNotifications(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(enableNotifications: value);
    await _saveSettings();
  }

  /// Set vibration
  Future<void> setEnableVibration(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(enableVibration: value);
    await _saveSettings();
  }

  /// Set keep screen on
  Future<void> setKeepScreenOn(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(keepScreenOn: value);
    await _saveSettings();
  }

  /// Set scrollback line count
  Future<void> setScrollbackLines(int value) async {
    await _waitForInitialLoad();
    state = state.copyWith(scrollbackLines: value);
    await _saveSettings();
  }

  /// Set minimum font size
  Future<void> setMinFontSize(double value) async {
    await _waitForInitialLoad();
    state = state.copyWith(minFontSize: value);
    await _saveSettings();
  }

  /// Set auto-fit
  Future<void> setAutoFitEnabled(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(autoFitEnabled: value);
    await _saveSettings();
  }

  /// Set direct input mode
  Future<void> setDirectInputEnabled(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(directInputEnabled: value);
    await _saveSettings();
  }

  /// Toggle direct input mode
  Future<void> toggleDirectInput() async {
    await setDirectInputEnabled(!state.directInputEnabled);
  }

  /// Set terminal cursor visibility
  Future<void> setShowTerminalCursor(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(showTerminalCursor: value);
    await _saveSettings();
  }

  /// Set pane navigation direction inversion
  Future<void> setInvertPaneNavigation(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(invertPaneNavigation: value);
    await _saveSettings();
  }

  /// Reload
  Future<void> reload() async {
    await _loadSettings();
  }
}

/// Settings provider
final settingsProvider = NotifierProvider<SettingsNotifier, AppSettings>(() {
  return SettingsNotifier();
});

/// Dark mode provider (convenience accessor)
final darkModeProvider = Provider<bool>((ref) {
  return ref.watch(settingsProvider).darkMode;
});
