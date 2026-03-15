import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/settings_provider.dart';
import 'package:flutter_muxpod/providers/shared_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('AppSettings round-trips through JSON', () {
    const settings = AppSettings(
      darkMode: false,
      fontSize: 18.0,
      fontFamily: 'HackGen Console',
      enableNotifications: false,
      enableVibration: false,
      keepScreenOn: false,
      scrollbackLines: 5000,
      minFontSize: 9.5,
      autoFitEnabled: false,
      directInputEnabled: true,
      showTerminalCursor: false,
      invertPaneNavigation: true,
    );

    final restored = AppSettings.fromJson(settings.toJson());

    expect(restored.darkMode, settings.darkMode);
    expect(restored.fontSize, settings.fontSize);
    expect(restored.fontFamily, settings.fontFamily);
    expect(restored.enableNotifications, settings.enableNotifications);
    expect(restored.enableVibration, settings.enableVibration);
    expect(restored.keepScreenOn, settings.keepScreenOn);
    expect(restored.scrollbackLines, settings.scrollbackLines);
    expect(restored.minFontSize, settings.minFontSize);
    expect(restored.autoFitEnabled, settings.autoFitEnabled);
    expect(restored.directInputEnabled, settings.directInputEnabled);
    expect(restored.showTerminalCursor, settings.showTerminalCursor);
    expect(restored.invertPaneNavigation, settings.invertPaneNavigation);
  });

  test('legacy settings_biometric_auth key is cleaned up during migration',
      () async {
    // Simulate an upgraded install that still has the old biometric key
    // alongside other legacy per-field keys.
    SharedPreferences.setMockInitialValues({
      'settings_dark_mode': false,
      'settings_biometric_auth': true,
    });
    final prefs = await SharedPreferences.getInstance();

    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    // Reading the provider triggers the migration from legacy keys to
    // a versioned JSON envelope.
    container.read(settingsProvider);

    // Give the async _persistSettingsValue call time to complete.
    await Future<void>.delayed(const Duration(milliseconds: 100));

    // The versioned blob should exist now.
    expect(prefs.getString('settings'), isNotNull);
    // The legacy biometric key must have been removed.
    expect(prefs.containsKey('settings_biometric_auth'), isFalse);
    // Other legacy keys should also be gone.
    expect(prefs.containsKey('settings_dark_mode'), isFalse);
  });
}
