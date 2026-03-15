import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../storage/versioned_json_storage.dart';

/// Result of looking up a host in the known hosts store.
enum HostKeyStatus { trusted, unknown, changed }

/// A single known host entry.
class KnownHostEntry {
  final String keyType;
  final String fingerprint;
  final DateTime addedAt;

  const KnownHostEntry({
    required this.keyType,
    required this.fingerprint,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'keyType': keyType,
    'fingerprint': fingerprint,
    'addedAt': addedAt.toIso8601String(),
  };

  factory KnownHostEntry.fromJson(Map<String, dynamic> json) {
    return KnownHostEntry(
      keyType: json['keyType'] as String,
      fingerprint: json['fingerprint'] as String,
      addedAt: DateTime.parse(json['addedAt'] as String),
    );
  }
}

/// Persistent storage for SSH host key fingerprints (TOFU model).
///
/// Stores MD5 fingerprints keyed by "host:port" in SharedPreferences.
/// Fingerprints are public data, not secrets, so SharedPreferences is appropriate.
class KnownHostsService {
  static const String _storageKey = 'known_hosts';

  final SharedPreferences _prefs;

  KnownHostsService(this._prefs);

  /// Convert raw MD5 bytes to colon-separated hex string.
  static String formatFingerprint(Uint8List rawBytes) {
    return rawBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  }

  /// Build a normalized storage key for a host:port pair.
  static String hostKey(String host, int port) {
    // Bracket IPv6 addresses to avoid ambiguity with port separator
    if (host.contains(':')) {
      return '[$host]:$port';
    }
    return '$host:$port';
  }

  /// Look up whether a host:port is known.
  ///
  /// Returns a tuple of (status, existingEntry).
  (HostKeyStatus, KnownHostEntry?) lookup(
    String host,
    int port,
    String keyType,
    String fingerprint,
  ) {
    final entries = _loadEntries();
    final key = hostKey(host, port);
    final entry = entries[key];

    if (entry == null) {
      return (HostKeyStatus.unknown, null);
    }

    if (entry.fingerprint == fingerprint) {
      return (HostKeyStatus.trusted, entry);
    }

    return (HostKeyStatus.changed, entry);
  }

  /// Save or overwrite the fingerprint for a host:port.
  Future<void> save(
    String host,
    int port,
    String keyType,
    String fingerprint,
  ) async {
    final entries = _loadEntries();
    final key = hostKey(host, port);
    entries[key] = KnownHostEntry(
      keyType: keyType,
      fingerprint: fingerprint,
      addedAt: DateTime.now(),
    );
    await _saveEntries(entries);
  }

  /// Remove a known host entry.
  Future<void> remove(String host, int port) async {
    final entries = _loadEntries();
    final key = hostKey(host, port);
    entries.remove(key);
    await _saveEntries(entries);
  }

  /// Get all known host entries.
  Map<String, KnownHostEntry> getAll() => _loadEntries();

  Map<String, KnownHostEntry> _loadEntries() {
    final raw = _prefs.getString(_storageKey);
    if (raw == null) return {};

    try {
      final loaded = decodeVersionedJsonEnvelope<Map<String, KnownHostEntry>>(
        raw: raw,
        storageKey: _storageKey,
        versionReaders: {
          sharedPreferencesSchemaVersion1: (data) =>
              _decodeEntries(data as Map<String, dynamic>),
        },
        legacyReader: (legacy) =>
            _decodeEntries(legacy as Map<String, dynamic>),
      );
      if (loaded.usedLegacyFormat) {
        unawaited(_saveEntries(loaded.value));
      }
      return loaded.value;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[KnownHostsService] failed to decode known hosts: $e');
      }
      return {};
    }
  }

  Future<void> _saveEntries(Map<String, KnownHostEntry> entries) async {
    final encoded = encodeVersionedJsonEnvelope(
      entries.map((key, entry) => MapEntry(key, entry.toJson())),
    );
    await _prefs.setString(_storageKey, encoded);
  }

  Map<String, KnownHostEntry> _decodeEntries(Map<String, dynamic> decoded) {
    return decoded.map(
      (key, value) =>
          MapEntry(key, KnownHostEntry.fromJson(value as Map<String, dynamic>)),
    );
  }
}
