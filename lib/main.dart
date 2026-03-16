import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_muxpod/providers/settings_provider.dart';
import 'package:flutter_muxpod/providers/shared_preferences_provider.dart';
import 'package:flutter_muxpod/screens/home_screen.dart';
import 'package:flutter_muxpod/screens/terminal/terminal_screen.dart';
import 'package:flutter_muxpod/services/license_service.dart';
import 'package:flutter_muxpod/services/notifications/bell_notification_service.dart';
import 'package:flutter_muxpod/services/version_info.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_muxpod/theme/app_theme.dart';

/// Global navigator key for notification-tap navigation.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Register font licenses
  LicenseService.registerLicenses();

  // Initialize version info
  await VersionInfo.initialize();

  // Initialize bell notification service
  final bellService = BellNotificationService();
  await bellService.initialize();
  bellService.onNotificationTap = _handleBellNotificationTap;

  final sharedPreferences = await SharedPreferences.getInstance();

  // Make the status bar transparent
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  runApp(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(sharedPreferences),
      ],
      child: const MyApp(),
    ),
  );

  // Handle cold-start from notification tap
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    final payload = await bellService.getLaunchPayload();
    if (payload != null) {
      _handleBellNotificationTap(payload);
    }
  });
}

void _handleBellNotificationTap(Map<String, dynamic> payload) {
  final connectionId = payload['connectionId'] as String?;
  final sessionName = payload['sessionName'] as String?;
  final windowIndex = payload['windowIndex'] as int?;
  if (connectionId == null) return;

  navigatorKey.currentState?.push(
    MaterialPageRoute(
      builder: (_) => TerminalScreen(
        connectionId: connectionId,
        sessionName: sessionName,
        lastWindowIndex: windowIndex,
      ),
    ),
  );
}

class MyApp extends ConsumerWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'MuxPod',
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: settings.darkMode ? ThemeMode.dark : ThemeMode.light,
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
