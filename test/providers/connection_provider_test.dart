import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/connection_provider.dart';
import 'package:flutter_muxpod/providers/shared_preferences_provider.dart';
import 'package:flutter_muxpod/services/storage/versioned_json_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String encodeEnvelope(Object? data) =>
      jsonEncode({'version': sharedPreferencesSchemaVersion1, 'data': data});

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('getByIdWhenReady waits for the initial async load', () async {
    final connection = Connection(
      id: 'conn-1',
      name: 'Test',
      host: 'example.com',
      port: 22,
      username: 'user',
      createdAt: DateTime.utc(2025, 1, 1),
    );

    SharedPreferences.setMockInitialValues({
      'connections': jsonEncode([connection.toJson()]),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(connectionsProvider);
    final resolved = await container
        .read(connectionsProvider.notifier)
        .getByIdWhenReady(connection.id);

    expect(resolved, isNotNull);
    expect(resolved!.id, connection.id);
    expect(resolved.host, connection.host);
  });

  test('add waits for initial load and preserves stored connections', () async {
    final existing = Connection(
      id: 'conn-existing',
      name: 'Existing',
      host: 'existing.example.com',
      port: 22,
      username: 'existing-user',
      createdAt: DateTime.utc(2025, 1, 1),
    );
    final added = Connection(
      id: 'conn-added',
      name: 'Added',
      host: 'added.example.com',
      port: 22,
      username: 'added-user',
      createdAt: DateTime.utc(2025, 1, 2),
    );

    SharedPreferences.setMockInitialValues({
      'connections': jsonEncode([existing.toJson()]),
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    final initialState = container.read(connectionsProvider);
    expect(initialState.isLoading, isTrue);

    await container.read(connectionsProvider.notifier).add(added);

    final connections = container.read(connectionsProvider).connections;
    expect(connections.map((connection) => connection.id), {
      existing.id,
      added.id,
    });
  });

  test('saves versioned connections JSON on mutation', () async {
    final connection = Connection(
      id: 'conn-1',
      name: 'Test',
      host: 'example.com',
      port: 22,
      username: 'user',
      createdAt: DateTime.utc(2025, 1, 1),
    );

    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    container.read(connectionsProvider);
    await container.read(connectionsProvider.notifier).add(connection);

    final raw = prefs.getString('connections');
    expect(raw, isNotNull);
    final stored = jsonDecode(raw!) as Map<String, dynamic>;
    expect(stored['version'], sharedPreferencesSchemaVersion1);
    expect(stored['data'], hasLength(1));
    expect((stored['data'] as List).single['id'], connection.id);
  });

  test(
    'build loads synchronously when shared preferences are preloaded',
    () async {
      final connection = Connection(
        id: 'conn-1',
        name: 'Test',
        host: 'example.com',
        port: 22,
        username: 'user',
        createdAt: DateTime.utc(2025, 1, 1),
      );

      SharedPreferences.setMockInitialValues({
        'connections': jsonEncode([connection.toJson()]),
      });
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      final state = container.read(connectionsProvider);
      expect(state.isLoading, isFalse);
      expect(state.connections.single.id, connection.id);
    },
  );

  test('loads versioned connections JSON when shared preferences are preloaded', () async {
    final connection = Connection(
      id: 'conn-1',
      name: 'Test',
      host: 'example.com',
      port: 22,
      username: 'user',
      createdAt: DateTime.utc(2025, 1, 1),
    );

    SharedPreferences.setMockInitialValues({
      'connections': encodeEnvelope([connection.toJson()]),
    });
    final prefs = await SharedPreferences.getInstance();

    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final state = container.read(connectionsProvider);
    expect(state.isLoading, isFalse);
    expect(state.connections.single.id, connection.id);
  });
}
