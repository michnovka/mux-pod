import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/connection_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
}
