import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/active_session_provider.dart';
import 'package:flutter_muxpod/providers/connection_provider.dart';
import 'package:flutter_muxpod/providers/key_provider.dart';
import 'package:flutter_muxpod/providers/settings_provider.dart';
import 'package:flutter_muxpod/providers/shared_preferences_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _waitForCondition(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
  Duration pollInterval = const Duration(milliseconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(pollInterval);
  }

  expect(predicate(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'settings mutation waits for initial load and keeps stored values',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings_dark_mode': false,
        'settings_font_size': 18.0,
        'settings_direct_input_enabled': false,
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final initialSettings = container.read(settingsProvider);
      expect(initialSettings.darkMode, isTrue);
      expect(initialSettings.fontSize, 14.0);

      await container
          .read(settingsProvider.notifier)
          .setDirectInputEnabled(true);

      final settings = container.read(settingsProvider);
      expect(settings.darkMode, isFalse);
      expect(settings.fontSize, 18.0);
      expect(settings.directInputEnabled, isTrue);
    },
  );

  test(
    'key mutations wait for initial load and preserve stored keys',
    () async {
      final existingKey = SshKeyMeta(
        id: 'key-existing',
        name: 'Existing key',
        type: 'ed25519',
        publicKey: 'ssh-ed25519 AAAAexisting existing@example.com',
        fingerprint: 'SHA256:existing',
        createdAt: DateTime.utc(2025, 1, 1),
      );
      final addedKey = SshKeyMeta(
        id: 'key-added',
        name: 'Added key',
        type: 'rsa-2048',
        publicKey: 'ssh-rsa AAAAadded added@example.com',
        fingerprint: 'SHA256:added',
        createdAt: DateTime.utc(2025, 1, 2),
      );

      SharedPreferences.setMockInitialValues({
        'ssh_keys_meta': jsonEncode([existingKey.toJson()]),
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final initialState = container.read(keysProvider);
      expect(initialState.isLoading, isTrue);

      await container.read(keysProvider.notifier).add(addedKey);

      final keyIds = container
          .read(keysProvider)
          .keys
          .map((key) => key.id)
          .toSet();
      expect(keyIds, {existingKey.id, addedKey.id});
    },
  );

  test(
    'active session mutations are deferred until the initial load completes',
    () async {
      final existingSession = ActiveSession(
        connectionId: 'conn-1',
        connectionName: 'Existing connection',
        host: 'existing.example.com',
        sessionName: 'existing-session',
        windowCount: 1,
        connectedAt: DateTime.utc(2025, 1, 1),
        lastAccessedAt: DateTime.utc(2025, 1, 1, 12),
      );

      SharedPreferences.setMockInitialValues({
        'active_sessions': jsonEncode([existingSession.toJson()]),
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      final initialState = container.read(activeSessionsProvider);
      expect(initialState.sessions, isEmpty);

      container
          .read(activeSessionsProvider.notifier)
          .addOrUpdateSession(
            connectionId: 'conn-2',
            connectionName: 'New connection',
            host: 'new.example.com',
            sessionName: 'new-session',
            windowCount: 2,
          );

      await _waitForCondition(
        () => container.read(activeSessionsProvider).sessions.length == 2,
      );

      final keys = container
          .read(activeSessionsProvider)
          .sessions
          .map((session) => session.key)
          .toSet();
      expect(keys, {existingSession.key, 'conn-2:new-session'});
    },
  );

  test(
    'connections build loads synchronously when shared preferences are preloaded',
    () async {
      final connection = Connection(
        id: 'conn-1',
        name: 'Saved connection',
        host: 'saved.example.com',
        port: 22,
        username: 'saved-user',
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
      expect(state.connections.map((item) => item.id), [connection.id]);
    },
  );

  test(
    'settings build loads synchronously when shared preferences are preloaded',
    () async {
      SharedPreferences.setMockInitialValues({
        'settings_dark_mode': false,
        'settings_font_size': 18.0,
        'settings_direct_input_enabled': true,
      });
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      final settings = container.read(settingsProvider);
      expect(settings.darkMode, isFalse);
      expect(settings.fontSize, 18.0);
      expect(settings.directInputEnabled, isTrue);
    },
  );

  test(
    'key build loads synchronously when shared preferences are preloaded',
    () async {
      final existingKey = SshKeyMeta(
        id: 'key-existing',
        name: 'Existing key',
        type: 'ed25519',
        publicKey: 'ssh-ed25519 AAAAexisting existing@example.com',
        fingerprint: 'SHA256:existing',
        createdAt: DateTime.utc(2025, 1, 1),
      );

      SharedPreferences.setMockInitialValues({
        'ssh_keys_meta': jsonEncode([existingKey.toJson()]),
      });
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      final state = container.read(keysProvider);
      expect(state.isLoading, isFalse);
      expect(state.keys.single.id, existingKey.id);
    },
  );

  test(
    'active sessions build loads synchronously when shared preferences are preloaded',
    () async {
      final existingSession = ActiveSession(
        connectionId: 'conn-1',
        connectionName: 'Existing connection',
        host: 'existing.example.com',
        sessionName: 'existing-session',
        windowCount: 1,
        connectedAt: DateTime.utc(2025, 1, 1),
        lastAccessedAt: DateTime.utc(2025, 1, 1, 12),
      );

      SharedPreferences.setMockInitialValues({
        'active_sessions': jsonEncode([existingSession.toJson()]),
      });
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      final state = container.read(activeSessionsProvider);
      expect(state.sessions.map((session) => session.key), [
        existingSession.key,
      ]);
    },
  );

  test(
    'active session mutations update state inline when prefs are preloaded',
    () async {
      SharedPreferences.setMockInitialValues({'active_sessions': '[]'});
      final prefs = await SharedPreferences.getInstance();

      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);

      // Trigger build so the completer is already completed.
      container.read(activeSessionsProvider);

      // Fire-and-forget, just like widget code does.
      container.read(activeSessionsProvider.notifier).addOrUpdateSession(
        connectionId: 'conn-1',
        connectionName: 'Inline test',
        host: 'inline.example.com',
        sessionName: 'inline-session',
        windowCount: 1,
      );

      // State must be updated synchronously — no microtask hop.
      final state = container.read(activeSessionsProvider);
      expect(state.sessions, hasLength(1));
      expect(state.sessions.single.key, 'conn-1:inline-session');
    },
  );
}
