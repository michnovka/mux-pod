import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Manages the Foreground Service to keep SSH connections alive in the background
class SshForegroundTaskService {
  static final SshForegroundTaskService _instance =
      SshForegroundTaskService._internal();
  factory SshForegroundTaskService() => _instance;
  SshForegroundTaskService._internal();

  bool _isInitialized = false;
  bool _isRunning = false;
  String? _currentConnectionName;

  /// Whether the service is running
  bool get isRunning => _isRunning;

  /// Name of the current active connection
  String? get currentConnectionName => _currentConnectionName;

  /// Initialize the Foreground Task
  Future<void> initialize() async {
    if (_isInitialized) return;
    if (!Platform.isAndroid) {
      _isInitialized = true;
      return;
    }

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'muxpod_ssh_foreground',
        channelName: 'SSH Connection',
        channelDescription: 'Keeps SSH connection alive in background',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        playSound: false,
        visibility: NotificationVisibility.VISIBILITY_SECRET,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: false,
        allowWifiLock: true,
      ),
    );

    _isInitialized = true;
  }

  /// Request notification permissions
  Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) return true;

    // Notification permission is required on Android 13+
    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    return await FlutterForegroundTask.checkNotificationPermission() ==
        NotificationPermission.granted;
  }

  /// Start the Foreground Service when SSH connects
  Future<bool> startService({
    required String connectionName,
    required String host,
  }) async {
    if (!Platform.isAndroid) return true;
    if (_isRunning) return true;

    await initialize();

    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      return false;
    }

    _currentConnectionName = connectionName;

    final result = await FlutterForegroundTask.startService(
      notificationTitle: 'SSH connected: $connectionName',
      notificationText: 'Host: $host',
      callback: _startCallback,
    );

    _isRunning = result is ServiceRequestSuccess;
    return _isRunning;
  }

  /// Update notification text
  Future<void> updateNotification({
    String? title,
    String? text,
  }) async {
    if (!Platform.isAndroid || !_isRunning) return;

    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  /// Stop the Foreground Service when SSH disconnects
  Future<void> stopService() async {
    if (!Platform.isAndroid || !_isRunning) return;

    await FlutterForegroundTask.stopService();
    _isRunning = false;
    _currentConnectionName = null;
  }

  /// Check if the service can be started
  Future<bool> canStartService() async {
    if (!Platform.isAndroid) return false;

    final permission =
        await FlutterForegroundTask.checkNotificationPermission();
    return permission == NotificationPermission.granted;
  }
}

/// Callback when Foreground Task starts (required, but SSH connection is managed in the main isolate)
@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_SshTaskHandler());
}

/// TaskHandler for maintaining SSH connections
class _SshTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // SSH connection is managed in the main isolate, so nothing to do here
    // This Handler exists only to keep the Foreground Service alive
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // Periodic execution event (not used)
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isAppTerminated) async {
    // Processing on service termination (cleanup as needed)
  }

  @override
  void onNotificationButtonPressed(String id) {
    // When the notification button is tapped (not used)
  }

  @override
  void onNotificationPressed() {
    // When the notification is tapped - bring the app to the foreground
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {
    // When the notification is dismissed by swiping
  }
}

