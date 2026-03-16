import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Callback type for notification taps.
typedef BellNotificationTapCallback = void Function(Map<String, dynamic> payload);

/// Manages OS-level notifications for tmux bell events.
class BellNotificationService {
  static final BellNotificationService _instance =
      BellNotificationService._internal();
  factory BellNotificationService() => _instance;
  BellNotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;
  BellNotificationTapCallback? _onTap;

  /// Handler registered by the active terminal screen.
  /// Returns true if the tap was consumed (e.g. same connection, navigated
  /// to the target window).  Falls through to [_onTap] when null or false.
  bool Function(Map<String, dynamic> payload)? activeTerminalHandler;

  /// Set the fallback callback invoked when no terminal screen handles the tap.
  set onNotificationTap(BellNotificationTapCallback? callback) {
    _onTap = callback;
  }

  /// Initialize the notification plugin and create the bell channel.
  Future<void> initialize() async {
    if (_isInitialized) return;
    if (!Platform.isAndroid) {
      _isInitialized = true;
      return;
    }

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );

    // Create the bell notification channel
    const channel = AndroidNotificationChannel(
      'muxpod_bell_alerts',
      'Bell Alerts',
      description: 'Notifications for tmux bell events',
      importance: Importance.high,
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    _isInitialized = true;
  }

  /// Return launch notification payload if the app was opened via a bell notification.
  Future<Map<String, dynamic>?> getLaunchPayload() async {
    if (!Platform.isAndroid) return null;
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    final response = details.notificationResponse;
    if (response == null || response.payload == null) return null;
    try {
      return jsonDecode(response.payload!) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    if (response.payload == null) return;
    try {
      final payload = jsonDecode(response.payload!) as Map<String, dynamic>;
      // Let the active terminal screen handle the tap if possible.
      if (activeTerminalHandler?.call(payload) == true) return;
      _onTap?.call(payload);
    } catch (e) {
      developer.log(
        'Failed to parse bell notification payload: $e',
        name: 'BellNotificationService',
      );
    }
  }

  /// Show an OS notification for a bell event.
  Future<void> showBellNotification({
    required String connectionId,
    required String connectionName,
    required String sessionName,
    required int windowIndex,
    required String windowName,
  }) async {
    if (!_isInitialized || !Platform.isAndroid) return;

    // Deterministic ID so repeated bells on the same window replace the notification
    final windowKey = '$connectionId:$sessionName:$windowIndex';
    final notificationId = windowKey.hashCode & 0x7FFFFFFF;

    final payload = jsonEncode({
      'connectionId': connectionId,
      'sessionName': sessionName,
      'windowIndex': windowIndex,
    });

    const androidDetails = AndroidNotificationDetails(
      'muxpod_bell_alerts',
      'Bell Alerts',
      channelDescription: 'Notifications for tmux bell events',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      notificationId,
      'Bell: $windowName',
      '$connectionName > $sessionName',
      details,
      payload: payload,
    );
  }
}
