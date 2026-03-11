import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/keychain/secure_storage.dart';
import '../services/ssh/ssh_client.dart';
import '../services/tmux/tmux_commands.dart';
import '../services/tmux/tmux_parser.dart';
import 'connection_provider.dart';

/// Alert pane information based on tmux window flags
class AlertPane {
  final String connectionId;
  final String connectionName;
  final String host;
  final String sessionName;
  final int windowIndex;
  final String windowName;
  final Set<TmuxWindowFlag> flags;
  final String paneId;
  final int paneIndex;
  final String? currentCommand;

  const AlertPane({
    required this.connectionId,
    required this.connectionName,
    required this.host,
    required this.sessionName,
    required this.windowIndex,
    required this.windowName,
    required this.flags,
    required this.paneId,
    required this.paneIndex,
    this.currentCommand,
  });

  String get key => '$connectionId:$sessionName:$windowIndex:$paneId';

  /// Window-level key (shared by all panes in the same window)
  String get windowKey => '$connectionId:$sessionName:$windowIndex';

  /// Get the highest priority flag (bell > activity > silence)
  TmuxWindowFlag? get primaryFlag {
    if (flags.contains(TmuxWindowFlag.bell)) return TmuxWindowFlag.bell;
    if (flags.contains(TmuxWindowFlag.activity)) return TmuxWindowFlag.activity;
    if (flags.contains(TmuxWindowFlag.silence)) return TmuxWindowFlag.silence;
    return null;
  }
}

/// State for the alert panes list
class AlertPanesState {
  final List<AlertPane> alertPanes;
  final bool isLoading;
  final String? error;

  const AlertPanesState({
    this.alertPanes = const [],
    this.isLoading = false,
    this.error,
  });

  AlertPanesState copyWith({
    List<AlertPane>? alertPanes,
    bool? isLoading,
    String? error,
  }) {
    return AlertPanesState(
      alertPanes: alertPanes ?? this.alertPanes,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// Notifier that manages the alert panes list
class AlertPanesNotifier extends Notifier<AlertPanesState> {
  static const _alertFlags = {
    TmuxWindowFlag.activity,
    TmuxWindowFlag.bell,
    TmuxWindowFlag.silence,
  };

  @override
  AlertPanesState build() {
    return const AlertPanesState();
  }

  /// Dismiss an alert from the local list
  void dismiss(String key) {
    final updated = state.alertPanes.where((a) => a.key != key).toList();
    state = state.copyWith(alertPanes: updated);
  }

  /// Clear tmux window flags (select the window via select-window, then switch back)
  Future<void> clearWindowFlag(AlertPane alert) async {
    final connectionsState = ref.read(connectionsProvider);
    final connection = connectionsState.connections
        .where((c) => c.id == alert.connectionId)
        .firstOrNull;
    if (connection == null) return;

    try {
      final storage = SecureStorageService();
      SshConnectOptions options;
      if (connection.authMethod == 'key' && connection.keyId != null) {
        final privateKey = await storage.getPrivateKey(connection.keyId!);
        final passphrase = await storage.getPassphrase(connection.keyId!);
        options = SshConnectOptions(privateKey: privateKey, passphrase: passphrase, tmuxPath: connection.tmuxPath);
      } else {
        final password = await storage.getPassword(connection.id);
        options = SshConnectOptions(password: password, tmuxPath: connection.tmuxPath);
      }

      final sshClient = SshClient();
      await sshClient.connect(
        host: connection.host,
        port: connection.port,
        username: connection.username,
        options: options,
      );

      // Select the target window to clear flags, then switch back to the original window
      await sshClient.exec(
        TmuxCommands.selectWindow(alert.sessionName, alert.windowIndex),
      );

      await sshClient.disconnect();
    } catch (e) {
      debugPrint('Failed to clear window flag: $e');
    }
  }

  /// Fetch alert panes from all connections
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, error: null);

    final connectionsState = ref.read(connectionsProvider);
    final connections = connectionsState.connections;
    final storage = SecureStorageService();
    final allAlertPanes = <AlertPane>[];

    for (final connection in connections) {
      try {
        SshConnectOptions options;
        if (connection.authMethod == 'key' && connection.keyId != null) {
          final privateKey = await storage.getPrivateKey(connection.keyId!);
          final passphrase = await storage.getPassphrase(connection.keyId!);
          options = SshConnectOptions(privateKey: privateKey, passphrase: passphrase, tmuxPath: connection.tmuxPath);
        } else {
          final password = await storage.getPassword(connection.id);
          options = SshConnectOptions(password: password, tmuxPath: connection.tmuxPath);
        }

        final sshClient = SshClient();
        await sshClient.connect(
          host: connection.host,
          port: connection.port,
          username: connection.username,
          options: options,
        );

        final output = await sshClient.exec(TmuxCommands.listAllPanes());
        final sessions = TmuxParser.parseFullTree(output);

        for (final session in sessions) {
          for (final window in session.windows) {
            final windowAlertFlags = window.flags.intersection(_alertFlags);
            if (windowAlertFlags.isNotEmpty) {
              for (final pane in window.panes) {
                allAlertPanes.add(AlertPane(
                  connectionId: connection.id,
                  connectionName: connection.name,
                  host: connection.host,
                  sessionName: session.name,
                  windowIndex: window.index,
                  windowName: window.name,
                  flags: windowAlertFlags,
                  paneId: pane.id,
                  paneIndex: pane.index,
                  currentCommand: pane.currentCommand,
                ));
              }
            }
          }
        }

        await sshClient.disconnect();
      } catch (e) {
        debugPrint('Failed to fetch alert panes for ${connection.name}: $e');
      }
    }

    state = AlertPanesState(alertPanes: allAlertPanes);
  }
}

/// Alert panes provider
final alertPanesProvider =
    NotifierProvider<AlertPanesNotifier, AlertPanesState>(() {
  return AlertPanesNotifier();
});
