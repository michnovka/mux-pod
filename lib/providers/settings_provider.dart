import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'shared_preferences_provider.dart';

/// App settings
class AppSettings {
  final bool darkMode;
  final double fontSize;
  final String fontFamily;
  final bool requireBiometricAuth;
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
    this.requireBiometricAuth = false,
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
    bool? requireBiometricAuth,
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
      requireBiometricAuth: requireBiometricAuth ?? this.requireBiometricAuth,
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
}

/// Notifier that manages settings
class SettingsNotifier extends Notifier<AppSettings> {
  static const String _darkModeKey = 'settings_dark_mode';
  static const String _fontSizeKey = 'settings_font_size';
  static const String _fontFamilyKey = 'settings_font_family';
  static const String _biometricKey = 'settings_biometric_auth';
  static const String _notificationsKey = 'settings_notifications';
  static const String _vibrationKey = 'settings_vibration';
  static const String _keepScreenOnKey = 'settings_keep_screen_on';
  static const String _scrollbackKey = 'settings_scrollback';
  static const String _minFontSizeKey = 'settings_min_font_size';
  static const String _autoFitEnabledKey = 'settings_auto_fit_enabled';
  static const String _directInputEnabledKey = 'settings_direct_input_enabled';
  static const String _showTerminalCursorKey = 'settings_show_terminal_cursor';
  static const String _invertPaneNavKey = 'settings_invert_pane_nav';
  final Completer<void> _initialLoadCompleter = Completer<void>();
  SharedPreferences? _sharedPreferences;

  @override
  AppSettings build() {
    final prefs = _sharedPreferences = ref.read(sharedPreferencesProvider);
    if (prefs != null) {
      final settings = _loadSettingsSync(prefs);
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
      return settings;
    }

    _loadSettings();
    return const AppSettings();
  }

  AppSettings _loadSettingsSync(SharedPreferences prefs) {
    return AppSettings(
      darkMode: prefs.getBool(_darkModeKey) ?? true,
      fontSize: prefs.getDouble(_fontSizeKey) ?? 14.0,
      fontFamily: prefs.getString(_fontFamilyKey) ?? 'JetBrains Mono',
      requireBiometricAuth: prefs.getBool(_biometricKey) ?? false,
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
    } finally {
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
    }
  }

  Future<void> _waitForInitialLoad() => _initialLoadCompleter.future;

  Future<void> _saveSetting(String key, dynamic value) async {
    final prefs = await _getPrefs();
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is double) {
      await prefs.setDouble(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    }
  }

  /// Set dark mode
  Future<void> setDarkMode(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(darkMode: value);
    await _saveSetting(_darkModeKey, value);
  }

  /// Set font size
  Future<void> setFontSize(double value) async {
    await _waitForInitialLoad();
    state = state.copyWith(fontSize: value);
    await _saveSetting(_fontSizeKey, value);
  }

  /// Set font family
  Future<void> setFontFamily(String value) async {
    await _waitForInitialLoad();
    state = state.copyWith(fontFamily: value);
    await _saveSetting(_fontFamilyKey, value);
  }

  /// Set biometric authentication requirement
  Future<void> setRequireBiometricAuth(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(requireBiometricAuth: value);
    await _saveSetting(_biometricKey, value);
  }

  /// Set notifications
  Future<void> setEnableNotifications(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(enableNotifications: value);
    await _saveSetting(_notificationsKey, value);
  }

  /// Set vibration
  Future<void> setEnableVibration(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(enableVibration: value);
    await _saveSetting(_vibrationKey, value);
  }

  /// Set keep screen on
  Future<void> setKeepScreenOn(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(keepScreenOn: value);
    await _saveSetting(_keepScreenOnKey, value);
  }

  /// Set scrollback line count
  Future<void> setScrollbackLines(int value) async {
    await _waitForInitialLoad();
    state = state.copyWith(scrollbackLines: value);
    await _saveSetting(_scrollbackKey, value);
  }

  /// Set minimum font size
  Future<void> setMinFontSize(double value) async {
    await _waitForInitialLoad();
    state = state.copyWith(minFontSize: value);
    await _saveSetting(_minFontSizeKey, value);
  }

  /// Set auto-fit
  Future<void> setAutoFitEnabled(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(autoFitEnabled: value);
    await _saveSetting(_autoFitEnabledKey, value);
  }

  /// Set direct input mode
  Future<void> setDirectInputEnabled(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(directInputEnabled: value);
    await _saveSetting(_directInputEnabledKey, value);
  }

  /// Toggle direct input mode
  Future<void> toggleDirectInput() async {
    await setDirectInputEnabled(!state.directInputEnabled);
  }

  /// Set terminal cursor visibility
  Future<void> setShowTerminalCursor(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(showTerminalCursor: value);
    await _saveSetting(_showTerminalCursorKey, value);
  }

  /// Set pane navigation direction inversion
  Future<void> setInvertPaneNavigation(bool value) async {
    await _waitForInitialLoad();
    state = state.copyWith(invertPaneNavigation: value);
    await _saveSetting(_invertPaneNavKey, value);
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
