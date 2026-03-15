import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/storage/versioned_json_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_muxpod/services/keychain/known_hosts_service.dart';

void main() {
  late KnownHostsService service;

  bool isVersionedEnvelopeString(String? raw) {
    if (raw == null) {
      return false;
    }

    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> &&
          decoded['version'] == sharedPreferencesSchemaVersion1 &&
          decoded.containsKey('data');
    } catch (_) {
      return false;
    }
  }

  Future<void> waitForCondition(
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    service = KnownHostsService(prefs);
  });

  String encodeEnvelope(Object? data) =>
      jsonEncode({'version': sharedPreferencesSchemaVersion1, 'data': data});

  group('formatFingerprint', () {
    test('converts bytes to colon-separated hex', () {
      final bytes = Uint8List.fromList([0xaa, 0xbb, 0xcc, 0x00, 0xff]);
      expect(
        KnownHostsService.formatFingerprint(bytes),
        equals('aa:bb:cc:00:ff'),
      );
    });

    test('pads single-digit hex with leading zero', () {
      final bytes = Uint8List.fromList([0x01, 0x0f]);
      expect(KnownHostsService.formatFingerprint(bytes), equals('01:0f'));
    });

    test('handles empty bytes', () {
      expect(KnownHostsService.formatFingerprint(Uint8List(0)), equals(''));
    });
  });

  group('hostKey', () {
    test('formats IPv4 host:port', () {
      expect(KnownHostsService.hostKey('192.168.1.1', 22), '192.168.1.1:22');
    });

    test('formats hostname:port', () {
      expect(
        KnownHostsService.hostKey('example.com', 2222),
        'example.com:2222',
      );
    });

    test('brackets IPv6 addresses', () {
      expect(KnownHostsService.hostKey('::1', 22), '[::1]:22');
      expect(KnownHostsService.hostKey('2001:db8::1', 22), '[2001:db8::1]:22');
    });
  });

  group('lookup', () {
    test('returns unknown for empty store', () {
      final (status, entry) = service.lookup(
        'example.com',
        22,
        'ssh-ed25519',
        'aa:bb:cc',
      );
      expect(status, HostKeyStatus.unknown);
      expect(entry, isNull);
    });

    test('returns trusted when fingerprint matches', () async {
      await service.save('example.com', 22, 'ssh-ed25519', 'aa:bb:cc');

      final (status, entry) = service.lookup(
        'example.com',
        22,
        'ssh-ed25519',
        'aa:bb:cc',
      );
      expect(status, HostKeyStatus.trusted);
      expect(entry, isNotNull);
      expect(entry!.fingerprint, 'aa:bb:cc');
      expect(entry.keyType, 'ssh-ed25519');
    });

    test('returns changed when fingerprint differs', () async {
      await service.save('example.com', 22, 'ssh-ed25519', 'aa:bb:cc');

      final (status, entry) = service.lookup(
        'example.com',
        22,
        'ssh-rsa',
        'dd:ee:ff',
      );
      expect(status, HostKeyStatus.changed);
      expect(entry, isNotNull);
      expect(entry!.fingerprint, 'aa:bb:cc'); // old fingerprint
    });

    test('differentiates by port', () async {
      await service.save('example.com', 22, 'ssh-ed25519', 'aa:bb:cc');

      final (status, _) = service.lookup(
        'example.com',
        2222,
        'ssh-ed25519',
        'aa:bb:cc',
      );
      expect(status, HostKeyStatus.unknown);
    });
  });

  group('save', () {
    test('overwrites existing entry', () async {
      await service.save('example.com', 22, 'ssh-ed25519', 'aa:bb:cc');
      await service.save('example.com', 22, 'ssh-rsa', 'dd:ee:ff');

      final (status, entry) = service.lookup(
        'example.com',
        22,
        'ssh-rsa',
        'dd:ee:ff',
      );
      expect(status, HostKeyStatus.trusted);
      expect(entry!.keyType, 'ssh-rsa');
    });
  });

  group('remove', () {
    test('removes an existing entry', () async {
      await service.save('example.com', 22, 'ssh-ed25519', 'aa:bb:cc');
      await service.remove('example.com', 22);

      final (status, _) = service.lookup(
        'example.com',
        22,
        'ssh-ed25519',
        'aa:bb:cc',
      );
      expect(status, HostKeyStatus.unknown);
    });

    test('no-op for non-existent entry', () async {
      await service.remove('example.com', 22); // should not throw
    });
  });

  group('getAll', () {
    test('returns empty map initially', () {
      expect(service.getAll(), isEmpty);
    });

    test('returns all saved entries', () async {
      await service.save('host1.com', 22, 'ssh-ed25519', 'aa:bb');
      await service.save('host2.com', 2222, 'ssh-rsa', 'cc:dd');

      final all = service.getAll();
      expect(all.length, 2);
      expect(all.containsKey('host1.com:22'), isTrue);
      expect(all.containsKey('host2.com:2222'), isTrue);
    });
  });

  group('persistence', () {
    test('survives service recreation with same SharedPreferences', () async {
      await service.save('example.com', 22, 'ssh-ed25519', 'aa:bb:cc');

      // Recreate service with same prefs
      final prefs = await SharedPreferences.getInstance();
      final service2 = KnownHostsService(prefs);

      final (status, _) = service2.lookup(
        'example.com',
        22,
        'ssh-ed25519',
        'aa:bb:cc',
      );
      expect(status, HostKeyStatus.trusted);
    });

    test('writes known hosts in a versioned envelope', () async {
      await service.save('example.com', 22, 'ssh-ed25519', 'aa:bb:cc');

      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('known_hosts');
      expect(raw, isNotNull);

      final stored = jsonDecode(raw!) as Map<String, dynamic>;
      expect(stored['version'], sharedPreferencesSchemaVersion1);
      expect(
        (stored['data'] as Map<String, dynamic>).containsKey('example.com:22'),
        isTrue,
      );
    });

    test('loads legacy unversioned known hosts entries', () async {
      final legacyEntry = KnownHostEntry(
        keyType: 'ssh-ed25519',
        fingerprint: 'aa:bb:cc',
        addedAt: DateTime.utc(2026, 3, 15),
      );
      SharedPreferences.setMockInitialValues({
        'known_hosts': jsonEncode({'example.com:22': legacyEntry.toJson()}),
      });
      final prefs = await SharedPreferences.getInstance();
      final legacyService = KnownHostsService(prefs);

      final (status, entry) = legacyService.lookup(
        'example.com',
        22,
        'ssh-ed25519',
        'aa:bb:cc',
      );

      expect(status, HostKeyStatus.trusted);
      expect(entry, isNotNull);
      expect(entry!.fingerprint, legacyEntry.fingerprint);

      await waitForCondition(
        () => isVersionedEnvelopeString(prefs.getString('known_hosts')),
      );
    });

    test('loads versioned known hosts entries', () async {
      final entry = KnownHostEntry(
        keyType: 'ssh-ed25519',
        fingerprint: 'aa:bb:cc',
        addedAt: DateTime.utc(2026, 3, 15),
      );
      SharedPreferences.setMockInitialValues({
        'known_hosts': encodeEnvelope({'example.com:22': entry.toJson()}),
      });
      final prefs = await SharedPreferences.getInstance();
      final versionedService = KnownHostsService(prefs);

      final (status, loadedEntry) = versionedService.lookup(
        'example.com',
        22,
        'ssh-ed25519',
        'aa:bb:cc',
      );

      expect(status, HostKeyStatus.trusted);
      expect(loadedEntry, isNotNull);
      expect(loadedEntry!.fingerprint, entry.fingerprint);
    });
  });

  group('KnownHostEntry JSON', () {
    test('round-trips through JSON', () {
      final entry = KnownHostEntry(
        keyType: 'ssh-ed25519',
        fingerprint: 'aa:bb:cc',
        addedAt: DateTime.utc(2026, 3, 12),
      );
      final json = entry.toJson();
      final restored = KnownHostEntry.fromJson(json);

      expect(restored.keyType, entry.keyType);
      expect(restored.fingerprint, entry.fingerprint);
      expect(restored.addedAt, entry.addedAt);
    });
  });
}
