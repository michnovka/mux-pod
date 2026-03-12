import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/connection_provider.dart';
import 'package:flutter_muxpod/providers/ssh_provider.dart';
import 'package:flutter_muxpod/services/network/network_monitor.dart';
import 'package:flutter_muxpod/services/ssh/ssh_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeNetworkMonitor extends NetworkMonitor {
  final _statusController = StreamController<NetworkStatus>.broadcast();
  NetworkStatus _currentStatus;

  FakeNetworkMonitor([this._currentStatus = NetworkStatus.online]);

  @override
  NetworkStatus get currentStatus => _currentStatus;

  @override
  bool get isOnline => _currentStatus == NetworkStatus.online;

  @override
  Stream<NetworkStatus> get statusStream => _statusController.stream;

  void emit(NetworkStatus status) {
    _currentStatus = status;
    _statusController.add(status);
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    await _statusController.close();
  }
}

class FakeSshClient extends SshClient {
  FakeSshClient({Completer<void>? connectCompleter})
    : _connectCompleter = connectCompleter;

  final Completer<void>? _connectCompleter;
  final _connectionStateController =
      StreamController<SshConnectionState>.broadcast();

  int connectCalls = 0;
  bool disposed = false;
  bool disconnected = false;

  @override
  Stream<SshConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  @override
  Future<void> connect({
    required String host,
    required int port,
    required String username,
    required SshConnectOptions options,
  }) async {
    connectCalls++;
    await _connectCompleter?.future;
  }

  @override
  Future<void> disconnect() async {
    disconnected = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_connectionStateController.isClosed) {
      await _connectionStateController.close();
    }
  }

  void emitConnectionState(SshConnectionState state) {
    _connectionStateController.add(state);
  }
}

class QueuedSshClientFactory {
  QueuedSshClientFactory(this.clients);

  final List<FakeSshClient> clients;
  int createdCount = 0;

  SshClient call() {
    if (createdCount >= clients.length) {
      throw StateError('No fake SSH clients left in the queue');
    }
    return clients[createdCount++];
  }
}

Future<void> _waitForCondition(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
  Duration pollInterval = const Duration(milliseconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(pollInterval);
  }

  expect(predicate(), isTrue);
}

Connection _testConnection() {
  return Connection(
    id: 'conn-1',
    name: 'Test',
    host: 'example.com',
    port: 22,
    username: 'tester',
    createdAt: DateTime.utc(2025, 1, 1),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('reconnectNow reuses the in-flight reconnect attempt', () async {
    final initialClient = FakeSshClient();
    final reconnectGate = Completer<void>();
    final reconnectClient = FakeSshClient(connectCompleter: reconnectGate);
    final factory = QueuedSshClientFactory([initialClient, reconnectClient]);
    final monitor = FakeNetworkMonitor();

    final container = ProviderContainer(
      overrides: [
        networkMonitorProvider.overrideWith((ref) => monitor),
        sshClientFactoryProvider.overrideWith((ref) => factory.call),
      ],
    );
    addTearDown(() async {
      await monitor.dispose();
      container.dispose();
    });

    final notifier = container.read(sshProvider.notifier);
    await notifier.connectWithoutShell(
      _testConnection(),
      const SshConnectOptions(password: 'secret'),
    );

    final firstAttempt = notifier.reconnectNow();
    final secondAttempt = notifier.reconnectNow();

    await _waitForCondition(() => factory.createdCount == 2);
    expect(reconnectClient.connectCalls, 1);

    reconnectGate.complete();

    expect(await firstAttempt, isTrue);
    expect(await secondAttempt, isTrue);
    expect(container.read(sshProvider).isConnected, isTrue);
  });

  test('network recovery triggers only one immediate reconnect', () async {
    final initialClient = FakeSshClient();
    final reconnectGate = Completer<void>();
    final reconnectClient = FakeSshClient(connectCompleter: reconnectGate);
    final factory = QueuedSshClientFactory([initialClient, reconnectClient]);
    final monitor = FakeNetworkMonitor();

    final container = ProviderContainer(
      overrides: [
        networkMonitorProvider.overrideWith((ref) => monitor),
        sshClientFactoryProvider.overrideWith((ref) => factory.call),
      ],
    );
    addTearDown(() async {
      await monitor.dispose();
      container.dispose();
    });

    final notifier = container.read(sshProvider.notifier);
    await notifier.connectWithoutShell(
      _testConnection(),
      const SshConnectOptions(password: 'secret'),
    );

    monitor.emit(NetworkStatus.offline);
    await Future<void>.delayed(Duration.zero);

    expect(await notifier.reconnect(), isFalse);
    expect(container.read(sshProvider).isPaused, isTrue);

    monitor.emit(NetworkStatus.online);
    monitor.emit(NetworkStatus.online);
    await Future<void>.delayed(Duration.zero);

    expect(factory.createdCount, 2);
    expect(reconnectClient.connectCalls, 1);

    reconnectGate.complete();

    await _waitForCondition(() => container.read(sshProvider).isConnected);
  });

  test('disconnect invalidates an in-flight reconnect attempt', () async {
    final initialClient = FakeSshClient();
    final reconnectGate = Completer<void>();
    final reconnectClient = FakeSshClient(connectCompleter: reconnectGate);
    final factory = QueuedSshClientFactory([initialClient, reconnectClient]);
    final monitor = FakeNetworkMonitor();

    final container = ProviderContainer(
      overrides: [
        networkMonitorProvider.overrideWith((ref) => monitor),
        sshClientFactoryProvider.overrideWith((ref) => factory.call),
      ],
    );
    addTearDown(() async {
      await monitor.dispose();
      container.dispose();
    });

    final notifier = container.read(sshProvider.notifier);
    await notifier.connectWithoutShell(
      _testConnection(),
      const SshConnectOptions(password: 'secret'),
    );

    final reconnectAttempt = notifier.reconnectNow();
    await _waitForCondition(() => reconnectClient.connectCalls == 1);

    await notifier.disconnect();
    reconnectGate.complete();

    expect(await reconnectAttempt, isFalse);
    await _waitForCondition(() => reconnectClient.disposed);
    expect(container.read(sshProvider).isDisconnected, isTrue);
  });
}
