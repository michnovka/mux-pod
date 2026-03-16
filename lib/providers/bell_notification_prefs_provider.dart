import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/storage/versioned_json_storage.dart';
import 'shared_preferences_provider.dart';

/// Build a canonical key for per-window bell notification preferences.
String bellWindowKey(String connectionId, String sessionName, int windowIndex) {
  return '$connectionId:$sessionName:$windowIndex';
}

/// Notifier that manages per-window bell notification preferences.
///
/// State is a `Map<String, bool>` where keys are window keys (see
/// [bellWindowKey]) and values indicate whether OS notifications are enabled
/// for that window.  Default is `false` (OFF).
class BellNotificationPrefsNotifier extends Notifier<Map<String, bool>> {
  static const String _storageKey = 'bell_notification_prefs';
  final Completer<void> _initialLoadCompleter = Completer<void>();
  SharedPreferences? _sharedPreferences;

  @override
  Map<String, bool> build() {
    final prefs = _sharedPreferences = ref.read(sharedPreferencesProvider);
    if (prefs != null) {
      final loaded = _loadSync(prefs);
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
      return loaded;
    }

    _loadAsync();
    return const {};
  }

  Map<String, bool> _loadSync(SharedPreferences prefs) {
    final raw = prefs.getString(_storageKey);
    if (raw == null) return const {};
    try {
      final loaded = decodeVersionedJsonEnvelope<Map<String, bool>>(
        raw: raw,
        storageKey: _storageKey,
        versionReaders: {
          sharedPreferencesSchemaVersion1: (data) {
            final map = data as Map<String, dynamic>;
            return map.map((k, v) => MapEntry(k, v as bool));
          },
        },
      );
      return loaded.value;
    } catch (e, stackTrace) {
      developer.log(
        'Failed to load bell notification prefs: $e',
        name: 'BellNotificationPrefs',
        error: e,
        stackTrace: stackTrace,
      );
      return const {};
    }
  }

  Future<void> _loadAsync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _sharedPreferences = prefs;
      state = _loadSync(prefs);
    } catch (e, stackTrace) {
      developer.log(
        'Failed to async-load bell notification prefs: $e',
        name: 'BellNotificationPrefs',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
    }
  }

  Future<void> _save() async {
    final prefs = _sharedPreferences ?? await SharedPreferences.getInstance();
    _sharedPreferences = prefs;
    await prefs.setString(
      _storageKey,
      encodeVersionedJsonEnvelope(state),
    );
  }

  /// Whether notifications are enabled for the given window key.
  bool isEnabled(String windowKey) {
    return state[windowKey] ?? false;
  }

  /// Toggle the notification preference for a window.
  Future<void> setWindowNotification(String windowKey, bool enabled) async {
    await _initialLoadCompleter.future;
    final updated = Map<String, bool>.from(state);
    if (enabled) {
      updated[windowKey] = true;
    } else {
      updated.remove(windowKey);
    }
    state = updated;
    await _save();
  }
}

/// Per-window bell notification preferences provider.
final bellNotificationPrefsProvider =
    NotifierProvider<BellNotificationPrefsNotifier, Map<String, bool>>(() {
  return BellNotificationPrefsNotifier();
});
