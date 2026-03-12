import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/connection_provider.dart';
import 'package:flutter_muxpod/providers/notification_panes_provider.dart';
import 'package:flutter_muxpod/services/keychain/secure_storage.dart';
import 'package:flutter_muxpod/services/ssh/ssh_client.dart';
import 'package:flutter_muxpod/services/tmux/tmux_parser.dart';

class _TestConnectionsNotifier extends ConnectionsNotifier {
  _TestConnectionsNotifier(this._connections);

  final List<Connection> _connections;

  @override
  ConnectionsState build() {
    return ConnectionsState(connections: _connections);
  }
}

class FakeSecureStorageService extends SecureStorageService {
  FakeSecureStorageService({
    Map<String, String?> passwords = const {},
    Map<String, String?> privateKeys = const {},
    Map<String, String?> passphrases = const {},
  }) : _passwords = passwords,
       _privateKeys = privateKeys,
       _passphrases = passphrases;

  final Map<String, String?> _passwords;
  final Map<String, String?> _privateKeys;
  final Map<String, String?> _passphrases;

  @override
  Future<String?> getPassword(String connectionId) async {
    return _passwords[connectionId];
  }

  @override
  Future<String?> getPrivateKey(String keyId) async {
    return _privateKeys[keyId];
  }

  @override
  Future<String?> getPassphrase(String keyId) async {
    return _passphrases[keyId];
  }
}

class FakeAlertSshClient extends SshClient {
  FakeAlertSshClient({this.onConnect, this.onExec});

  final Future<void> Function()? onConnect;
  final Future<String> Function(String command, Duration? timeout)? onExec;

  int connectCalls = 0;
  int execCalls = 0;
  int disposeCalls = 0;

  @override
  Future<void> connect({
    required String host,
    required int port,
    required String username,
    required SshConnectOptions options,
  }) async {
    connectCalls++;
    await onConnect?.call();
  }

  @override
  Future<String> exec(String command, {Duration? timeout}) async {
    execCalls++;
    if (onExec != null) {
      return onExec!(command, timeout);
    }
    return '';
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}

class _QueuedAlertSshClientFactory {
  _QueuedAlertSshClientFactory(this.clients);

  final List<FakeAlertSshClient> clients;
  int createdCount = 0;

  SshClient call() {
    if (createdCount >= clients.length) {
      throw StateError('No fake alert SSH clients left in the queue');
    }
    return clients[createdCount++];
  }
}

Future<void> _waitForCondition(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 1),
  Duration pollInterval = const Duration(milliseconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(pollInterval);
  }

  expect(predicate(), isTrue);
}

Connection _connection(String id, String name) {
  return Connection(
    id: id,
    name: name,
    host: '$name.example.com',
    port: 22,
    username: 'tester',
    createdAt: DateTime.utc(2025, 1, 1),
  );
}

String _alertPaneOutput({
  String sessionName = 'session-1',
  int windowIndex = 1,
  String windowName = 'alerts',
  String paneId = '%1',
  int paneIndex = 0,
  String currentCommand = 'vim',
  String flags = '!',
}) {
  return '$sessionName|||\$0|||$windowIndex|||@1|||$windowName|||0|||'
      '$paneIndex|||$paneId|||1|||80|||24|||0|||0|||bash|||'
      '$currentCommand|||0|||0|||$flags';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('refresh disconnects the SSH client when exec throws', () async {
    final connection = _connection('conn-1', 'alpha');
    final client = FakeAlertSshClient(
      onExec: (command, timeout) async => throw Exception('exec failed'),
    );
    final factory = _QueuedAlertSshClientFactory([client]);

    final container = ProviderContainer(
      overrides: [
        connectionsProvider.overrideWith(
          () => _TestConnectionsNotifier([connection]),
        ),
        alertPanesSecureStorageProvider.overrideWith(
          (ref) => FakeSecureStorageService(passwords: {connection.id: 'pw'}),
        ),
        alertPanesSshClientFactoryProvider.overrideWith((ref) => factory.call),
      ],
    );
    addTearDown(container.dispose);

    await container.read(alertPanesProvider.notifier).refresh();

    final state = container.read(alertPanesProvider);
    expect(client.disposeCalls, 1);
    expect(state.alertPanes, isEmpty);
    expect(state.error, contains(connection.name));
  });

  test('refresh starts multiple connections in parallel', () async {
    final firstConnection = _connection('conn-1', 'alpha');
    final secondConnection = _connection('conn-2', 'beta');
    final firstGate = Completer<void>();
    final secondGate = Completer<void>();
    final firstClient = FakeAlertSshClient(
      onConnect: () => firstGate.future,
      onExec: (command, timeout) async => '',
    );
    final secondClient = FakeAlertSshClient(
      onConnect: () => secondGate.future,
      onExec: (command, timeout) async => '',
    );
    final factory = _QueuedAlertSshClientFactory([firstClient, secondClient]);

    final container = ProviderContainer(
      overrides: [
        connectionsProvider.overrideWith(
          () => _TestConnectionsNotifier([firstConnection, secondConnection]),
        ),
        alertPanesSecureStorageProvider.overrideWith(
          (ref) => FakeSecureStorageService(
            passwords: {
              firstConnection.id: 'pw-1',
              secondConnection.id: 'pw-2',
            },
          ),
        ),
        alertPanesSshClientFactoryProvider.overrideWith((ref) => factory.call),
      ],
    );
    addTearDown(container.dispose);

    final refreshFuture = container.read(alertPanesProvider.notifier).refresh();

    await _waitForCondition(
      () => firstClient.connectCalls == 1 && secondClient.connectCalls == 1,
    );

    firstGate.complete();
    secondGate.complete();
    await refreshFuture;

    expect(factory.createdCount, 2);
  });

  test('refresh times out slow connections and keeps fast results', () async {
    final slowConnection = _connection('conn-1', 'slow');
    final fastConnection = _connection('conn-2', 'fast');
    final slowClient = FakeAlertSshClient(
      onConnect: () => Completer<void>().future,
    );
    final fastClient = FakeAlertSshClient(
      onExec: (command, timeout) async => _alertPaneOutput(
        sessionName: 'session-fast',
        paneId: '%2',
        currentCommand: 'tail',
        flags: '#',
      ),
    );
    final factory = _QueuedAlertSshClientFactory([slowClient, fastClient]);

    final container = ProviderContainer(
      overrides: [
        connectionsProvider.overrideWith(
          () => _TestConnectionsNotifier([slowConnection, fastConnection]),
        ),
        alertPanesSecureStorageProvider.overrideWith(
          (ref) => FakeSecureStorageService(
            passwords: {slowConnection.id: 'pw-1', fastConnection.id: 'pw-2'},
          ),
        ),
        alertPanesSshClientFactoryProvider.overrideWith((ref) => factory.call),
        alertPanesRefreshConfigProvider.overrideWith(
          (ref) => const AlertPanesRefreshConfig(
            connectTimeout: Duration(milliseconds: 20),
            commandTimeout: Duration(milliseconds: 20),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    await container.read(alertPanesProvider.notifier).refresh();

    final state = container.read(alertPanesProvider);
    expect(state.alertPanes, hasLength(1));
    expect(state.alertPanes.single.connectionId, fastConnection.id);
    expect(state.alertPanes.single.primaryFlag, TmuxWindowFlag.activity);
    expect(state.error, contains(slowConnection.name));
    expect(slowClient.disposeCalls, 1);
    expect(fastClient.disposeCalls, 1);
  });

  test('clearWindowFlag disconnects the SSH client on failure', () async {
    final connection = _connection('conn-1', 'alpha');
    final client = FakeAlertSshClient(
      onExec: (command, timeout) async =>
          throw Exception('select-window failed'),
    );
    final factory = _QueuedAlertSshClientFactory([client]);

    final container = ProviderContainer(
      overrides: [
        connectionsProvider.overrideWith(
          () => _TestConnectionsNotifier([connection]),
        ),
        alertPanesSecureStorageProvider.overrideWith(
          (ref) => FakeSecureStorageService(passwords: {connection.id: 'pw'}),
        ),
        alertPanesSshClientFactoryProvider.overrideWith((ref) => factory.call),
      ],
    );
    addTearDown(container.dispose);

    const alert = AlertPane(
      connectionId: 'conn-1',
      connectionName: 'alpha',
      host: 'alpha.example.com',
      sessionName: 'session-1',
      windowIndex: 1,
      windowName: 'alerts',
      flags: {TmuxWindowFlag.bell},
      paneId: '%1',
      paneIndex: 0,
      currentCommand: 'vim',
    );

    await container.read(alertPanesProvider.notifier).clearWindowFlag(alert);

    expect(client.disposeCalls, 1);
    expect(client.execCalls, 1);
  });
}
