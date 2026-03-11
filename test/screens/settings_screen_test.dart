import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_muxpod/screens/settings/settings_screen.dart';

void main() {
  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  Widget buildTestApp() {
    return const ProviderScope(
      child: MaterialApp(
        home: SettingsScreen(),
      ),
    );
  }

  group('SettingsScreen', () {
    testWidgets('displays settings sections', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Section headers use toUpperCase()
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('TERMINAL'), findsOneWidget);
      expect(find.text('BEHAVIOR'), findsOneWidget);

      // Scroll down to see remaining sections
      await tester.scrollUntilVisible(find.text('APPEARANCE'), 100);
      expect(find.text('APPEARANCE'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('ABOUT'), 100);
      expect(find.text('ABOUT'), findsOneWidget);
    });

    testWidgets('displays Haptic Feedback toggle', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      expect(find.text('Haptic Feedback'), findsOneWidget);
      expect(find.text('Vibrate on key press'), findsOneWidget);
      expect(find.byType(SwitchListTile), findsWidgets);
    });

    testWidgets('displays Keep Screen On toggle', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // May need to scroll to see it
      await tester.scrollUntilVisible(find.text('Keep Screen On'), 100);
      expect(find.text('Keep Screen On'), findsOneWidget);
      expect(find.text('Prevent screen from sleeping'), findsOneWidget);
    });

    testWidgets('behavior toggles are interactive', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Find the Haptic Feedback switch
      final hapticSwitch = find.ancestor(
        of: find.text('Haptic Feedback'),
        matching: find.byType(SwitchListTile),
      );
      expect(hapticSwitch, findsOneWidget);

      // Scroll to Keep Screen On
      await tester.scrollUntilVisible(find.text('Keep Screen On'), 100);
      final keepScreenSwitch = find.ancestor(
        of: find.text('Keep Screen On'),
        matching: find.byType(SwitchListTile),
      );
      expect(keepScreenSwitch, findsOneWidget);
    });

    testWidgets('displays Source Code link', (tester) async {
      await tester.pumpWidget(buildTestApp());
      await tester.pumpAndSettle();

      // Scroll down to see Source Code link in About section
      await tester.scrollUntilVisible(find.text('Source Code'), 100);
      expect(find.text('Source Code'), findsOneWidget);
      expect(find.text('github.com/moezakura/mux-pod'), findsOneWidget);
    });
  });
}
