import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/keychain/secure_storage.dart';
import '../services/keychain/ssh_key_service.dart';
import '../services/storage/versioned_json_storage.dart';
import 'shared_preferences_provider.dart';

/// Enum indicating the origin of the key
enum KeySource {
  generated, // Generated within the app
  imported, // Imported via file/paste
}

/// SSH key metadata
class SshKeyMeta {
  final String id;
  final String name;
  final String type; // 'ed25519' | 'rsa-2048' | 'rsa-3072' | 'rsa-4096'
  final String? publicKey;
  final String? fingerprint; // SHA256 fingerprint
  final bool hasPassphrase;
  final DateTime createdAt;
  final String? comment;
  final KeySource source; // Key origin

  const SshKeyMeta({
    required this.id,
    required this.name,
    required this.type,
    this.publicKey,
    this.fingerprint,
    this.hasPassphrase = false,
    required this.createdAt,
    this.comment,
    this.source = KeySource.generated,
  });

  SshKeyMeta copyWith({
    String? id,
    String? name,
    String? type,
    String? publicKey,
    String? fingerprint,
    bool? hasPassphrase,
    DateTime? createdAt,
    String? comment,
    KeySource? source,
  }) {
    return SshKeyMeta(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      publicKey: publicKey ?? this.publicKey,
      fingerprint: fingerprint ?? this.fingerprint,
      hasPassphrase: hasPassphrase ?? this.hasPassphrase,
      createdAt: createdAt ?? this.createdAt,
      comment: comment ?? this.comment,
      source: source ?? this.source,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type,
      'publicKey': publicKey,
      'fingerprint': fingerprint,
      'hasPassphrase': hasPassphrase,
      'createdAt': createdAt.toIso8601String(),
      'comment': comment,
      'source': source.name,
    };
  }

  factory SshKeyMeta.fromJson(Map<String, dynamic> json) {
    return SshKeyMeta(
      id: json['id'] as String,
      name: json['name'] as String,
      type: json['type'] as String,
      publicKey: json['publicKey'] as String?,
      fingerprint: json['fingerprint'] as String?,
      hasPassphrase: json['hasPassphrase'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
      comment: json['comment'] as String?,
      source: KeySource.values.firstWhere(
        (e) => e.name == (json['source'] as String?),
        orElse: () => KeySource.generated,
      ),
    );
  }
}

/// State for the keys list
class KeysState {
  final List<SshKeyMeta> keys;
  final bool isLoading;
  final String? error;

  const KeysState({this.keys = const [], this.isLoading = false, this.error});

  KeysState copyWith({List<SshKeyMeta>? keys, bool? isLoading, String? error}) {
    return KeysState(
      keys: keys ?? this.keys,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// Notifier that manages SSH keys
class KeysNotifier extends Notifier<KeysState> {
  static const String _storageKey = 'ssh_keys_meta';
  final Completer<void> _initialLoadCompleter = Completer<void>();
  SharedPreferences? _sharedPreferences;

  @override
  KeysState build() {
    final prefs = _sharedPreferences = ref.read(sharedPreferencesProvider);
    if (prefs != null) {
      final state = _loadKeysSync(prefs);
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
      return state;
    }

    _loadKeys();
    return const KeysState(isLoading: true);
  }

  KeysState _loadKeysSync(SharedPreferences prefs) {
    try {
      final jsonString = prefs.getString(_storageKey);

      if (jsonString == null) {
        return const KeysState();
      }

      final loaded = decodeVersionedJsonEnvelope<List<SshKeyMeta>>(
        raw: jsonString,
        storageKey: _storageKey,
        versionReaders: {
          sharedPreferencesSchemaVersion1: (data) => _decodeKeysList(data),
        },
        legacyReader: (legacy) => _decodeKeysList(legacy),
      );
      final keys = loaded.value
          .toList();

      keys.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return KeysState(keys: keys);
    } catch (e) {
      return KeysState(error: e.toString());
    }
  }

  List<SshKeyMeta> _decodeKeysList(Object? data) {
    final jsonList = data as List<dynamic>;
    return jsonList
        .map((json) => SshKeyMeta.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<SharedPreferences> _getPrefs() async {
    final prefs = _sharedPreferences;
    if (prefs != null) {
      return prefs;
    }

    final loadedPrefs = await SharedPreferences.getInstance();
    _sharedPreferences = loadedPrefs;
    return loadedPrefs;
  }

  Future<void> _loadKeys() async {
    try {
      state = _loadKeysSync(await _getPrefs());
    } catch (e) {
      state = KeysState(error: e.toString());
    } finally {
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
    }
  }

  Future<void> _waitForInitialLoad() => _initialLoadCompleter.future;

  Future<void> _saveKeys() async {
    final prefs = await _getPrefs();
    final jsonList = state.keys.map((k) => k.toJson()).toList();
    await prefs.setString(_storageKey, encodeVersionedJsonEnvelope(jsonList));
  }

  /// Add a key
  Future<void> add(SshKeyMeta key) async {
    await _waitForInitialLoad();
    final keys = [...state.keys, key];
    state = state.copyWith(keys: keys);
    await _saveKeys();
  }

  /// Remove a key
  Future<void> remove(String id) async {
    await _waitForInitialLoad();
    final keys = state.keys.where((k) => k.id != id).toList();
    state = state.copyWith(keys: keys);
    await _saveKeys();
  }

  /// Update a key
  Future<void> update(SshKeyMeta key) async {
    await _waitForInitialLoad();
    final keys = state.keys.map((k) {
      return k.id == key.id ? key : k;
    }).toList();
    state = state.copyWith(keys: keys);
    await _saveKeys();
  }

  /// Get a key
  SshKeyMeta? getById(String id) {
    try {
      return state.keys.firstWhere((k) => k.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Reload
  Future<void> reload() async {
    state = state.copyWith(isLoading: true, error: null);
    await _loadKeys();
  }
}

/// SSH keys provider
final keysProvider = NotifierProvider<KeysNotifier, KeysState>(() {
  return KeysNotifier();
});

/// SSH key service provider
final sshKeyServiceProvider = Provider<SshKeyService>((ref) {
  return SshKeyService();
});

/// Secure storage provider
final secureStorageProvider = Provider<SecureStorageService>((ref) {
  return SecureStorageService();
});
