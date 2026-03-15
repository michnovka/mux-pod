import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/settings_provider.dart';

void main() {
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
}
