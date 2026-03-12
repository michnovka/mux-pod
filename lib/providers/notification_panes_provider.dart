import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/keychain/secure_storage.dart';
import '../services/ssh/ssh_client.dart';
import '../services/tmux/tmux_commands.dart';
import '../services/tmux/tmux_parser.dart';
import 'connection_provider.dart';
import 'known_hosts_provider.dart';

typedef AlertPanesSshClientFactory = SshClient Function();

final alertPanesSshClientFactoryProvider = Provider<AlertPanesSshClientFactory>(
  (ref) {
    return SshClient.new;
  },
);

final alertPanesSecureStorageProvider = Provider<SecureStorageService>((ref) {
  return SecureStorageService();
});

class AlertPanesRefreshConfig {
  final int maxConcurrentConnections;
  final Duration connectTimeout;
  final Duration commandTimeout;
  final Duration perConnectionTimeout;

  const AlertPanesRefreshConfig({
    this.maxConcurrentConnections = 4,
    this.connectTimeout = const Duration(seconds: 10),
    this.commandTimeout = const Duration(seconds: 10),
    this.perConnectionTimeout = const Duration(seconds: 12),
  });
}

final alertPanesRefreshConfigProvider = Provider<AlertPanesRefreshConfig>((
  ref,
) {
  return const AlertPanesRefreshConfig();
});

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

  Future<SshConnectOptions> _buildConnectOptions(
    Connection connection,
    SecureStorageService storage,
    AlertPanesRefreshConfig config,
  ) async {
    final connectTimeoutSeconds = (config.connectTimeout.inMilliseconds / 1000)
        .ceil()
        .clamp(1, 3600)
        .toInt();

    final knownHostsNotifier = ref.read(knownHostsProvider.notifier);
    final verifier = knownHostsNotifier.buildNonInteractiveVerifier(
      connection.host,
      connection.port,
    );

    if (connection.authMethod == 'key' && connection.keyId != null) {
      final credentials = await Future.wait<String?>([
        storage.getPrivateKey(connection.keyId!),
        storage.getPassphrase(connection.keyId!),
      ]);
      return SshConnectOptions(
        privateKey: credentials[0],
        passphrase: credentials[1],
        tmuxPath: connection.tmuxPath,
        timeout: connectTimeoutSeconds,
        onVerifyHostKey: verifier,
      );
    }

    final password = await storage.getPassword(connection.id);
    return SshConnectOptions(
      password: password,
      tmuxPath: connection.tmuxPath,
      timeout: connectTimeoutSeconds,
      onVerifyHostKey: verifier,
    );
  }

  List<AlertPane> _extractAlertPanes(
    Connection connection,
    List<TmuxSession> sessions,
  ) {
    final panes = <AlertPane>[];

    for (final session in sessions) {
      for (final window in session.windows) {
        final windowAlertFlags = window.flags.intersection(_alertFlags);
        if (windowAlertFlags.isEmpty) {
          continue;
        }

        for (final pane in window.panes) {
          panes.add(
            AlertPane(
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
            ),
          );
        }
      }
    }

    return panes;
  }

  Future<void> _disposeClient(SshClient sshClient) async {
    try {
      await sshClient.dispose();
    } catch (e) {
      debugPrint('Failed to dispose alert refresh client: $e');
    }
  }

  Future<void> _runWithConcurrencyLimit(
    List<Future<void> Function()> tasks,
    int maxConcurrent,
  ) async {
    if (tasks.isEmpty) {
      return;
    }

    final workerCount = math.max(1, math.min(maxConcurrent, tasks.length));
    final pending = Queue<Future<void> Function()>.from(tasks);

    Future<void> worker() async {
      while (pending.isNotEmpty) {
        final task = pending.removeFirst();
        await task();
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
  }

  Future<({List<AlertPane> panes, String? error})>
  _fetchAlertPanesForConnection(
    Connection connection,
    SecureStorageService storage,
    AlertPanesRefreshConfig config,
  ) async {
    final sshClient = ref.read(alertPanesSshClientFactoryProvider)();

    try {
      final options = await _buildConnectOptions(connection, storage, config);

      await sshClient
          .connect(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            options: options,
          )
          .timeout(config.connectTimeout);

      final output = await sshClient
          .exec(TmuxCommands.listAllPanes())
          .timeout(config.commandTimeout);
      final sessions = TmuxParser.parseFullTree(output);
      return (panes: _extractAlertPanes(connection, sessions), error: null);
    } catch (e) {
      final message = 'Failed to fetch alert panes for ${connection.name}: $e';
      debugPrint(message);
      return (panes: const <AlertPane>[], error: message);
    } finally {
      await _disposeClient(sshClient);
    }
  }

  /// Clear tmux window flags (select the window via select-window, then switch back)
  Future<void> clearWindowFlag(AlertPane alert) async {
    final connectionsState = ref.read(connectionsProvider);
    final connection = connectionsState.connections
        .where((c) => c.id == alert.connectionId)
        .firstOrNull;
    if (connection == null) return;

    final storage = ref.read(alertPanesSecureStorageProvider);
    final config = ref.read(alertPanesRefreshConfigProvider);
    final sshClient = ref.read(alertPanesSshClientFactoryProvider)();

    try {
      final options = await _buildConnectOptions(connection, storage, config);

      await sshClient
          .connect(
            host: connection.host,
            port: connection.port,
            username: connection.username,
            options: options,
          )
          .timeout(config.connectTimeout);

      // Select the target window to clear flags, then switch back to the original window
      await sshClient
          .exec(TmuxCommands.selectWindow(alert.sessionName, alert.windowIndex))
          .timeout(config.commandTimeout);
    } catch (e) {
      debugPrint('Failed to clear window flag: $e');
    } finally {
      await _disposeClient(sshClient);
    }
  }

  /// Fetch alert panes from all connections
  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, error: null);

    final connectionsState = ref.read(connectionsProvider);
    final connections = connectionsState.connections;
    final storage = ref.read(alertPanesSecureStorageProvider);
    final config = ref.read(alertPanesRefreshConfigProvider);

    final results = List<({List<AlertPane> panes, String? error})?>.filled(
      connections.length,
      null,
    );

    final tasks = connections.indexed.map((entry) {
      final index = entry.$1;
      final connection = entry.$2;
      return () async {
        try {
          final result = await _fetchAlertPanesForConnection(
            connection,
            storage,
            config,
          ).timeout(config.perConnectionTimeout);
          results[index] = result;
        } catch (e) {
          final message =
              'Failed to fetch alert panes for ${connection.name}: $e';
          debugPrint(message);
          results[index] = (panes: const <AlertPane>[], error: message);
        }
      };
    }).toList();

    await _runWithConcurrencyLimit(
      tasks,
      config.maxConcurrentConnections,
    );

    final allAlertPanes = <AlertPane>[
      for (final result
          in results.whereType<({List<AlertPane> panes, String? error})>())
        ...result.panes,
    ];
    final errors = [
      for (final result
          in results.whereType<({List<AlertPane> panes, String? error})>())
        if (result.error != null) result.error!,
    ];

    state = AlertPanesState(
      alertPanes: allAlertPanes,
      error: errors.isEmpty ? null : errors.join('\n'),
    );
  }

  @visibleForTesting
  Set<TmuxWindowFlag> get alertFlags => _alertFlags;

  @visibleForTesting
  List<AlertPane> extractAlertPanes(
    Connection connection,
    List<TmuxSession> sessions,
  ) {
    return _extractAlertPanes(connection, sessions);
  }

  @visibleForTesting
  Future<({List<AlertPane> panes, String? error})> fetchAlertPanesForConnection(
    Connection connection,
    SecureStorageService storage,
    AlertPanesRefreshConfig config,
  ) {
    return _fetchAlertPanesForConnection(connection, storage, config);
  }
}

/// Alert panes provider
final alertPanesProvider =
    NotifierProvider<AlertPanesNotifier, AlertPanesState>(() {
      return AlertPanesNotifier();
    });
