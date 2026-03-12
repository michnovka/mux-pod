import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/keychain/known_hosts_service.dart';
import '../widgets/dialogs/host_key_dialog.dart';
import 'shared_preferences_provider.dart';

/// State for the known hosts store.
class KnownHostsState {
  final Map<String, KnownHostEntry> hosts;

  const KnownHostsState({this.hosts = const {}});

  KnownHostsState copyWith({Map<String, KnownHostEntry>? hosts}) {
    return KnownHostsState(hosts: hosts ?? this.hosts);
  }
}

class KnownHostsNotifier extends Notifier<KnownHostsState> {
  KnownHostsService? _service;

  @override
  KnownHostsState build() {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs == null) {
      _service = null;
      return const KnownHostsState();
    }
    _service = KnownHostsService(prefs);
    return KnownHostsState(hosts: _service!.getAll());
  }

  /// Access the underlying service. Null only when SharedPreferences
  /// was not bootstrapped (should not happen in normal app flow).
  KnownHostsService? get service => _service;

  /// Save a host key and update state.
  Future<void> trustHost(
    String host,
    int port,
    String keyType,
    String fingerprint,
  ) async {
    final svc = _service;
    if (svc == null) return;
    await svc.save(host, port, keyType, fingerprint);
    state = KnownHostsState(hosts: svc.getAll());
  }

  /// Remove a host key and update state.
  Future<void> removeHost(String host, int port) async {
    final svc = _service;
    if (svc == null) return;
    await svc.remove(host, port);
    state = KnownHostsState(hosts: svc.getAll());
  }

  /// Build a host key verification callback for NON-INTERACTIVE contexts
  /// (auto-reconnect, background refresh).
  ///
  /// Accepts known/trusted hosts; rejects unknown or changed hosts.
  /// If the known hosts service is unavailable, rejects all keys.
  FutureOr<bool> Function(String type, Uint8List fingerprint)
      buildNonInteractiveVerifier(String host, int port) {
    final svc = _service;
    return (String type, Uint8List fingerprint) {
      if (svc == null) return false;
      final fp = KnownHostsService.formatFingerprint(fingerprint);
      final (status, _) = svc.lookup(host, port, type, fp);
      return status == HostKeyStatus.trusted;
    };
  }
}

final knownHostsProvider =
    NotifierProvider<KnownHostsNotifier, KnownHostsState>(
  KnownHostsNotifier.new,
);

/// Build a host key verification callback for INTERACTIVE contexts
/// (has BuildContext, can show dialogs).
///
/// Auto-accepts trusted keys. Shows a dialog for unknown or changed keys.
FutureOr<bool> Function(String type, Uint8List fingerprint)
    buildInteractiveVerifier({
  required BuildContext context,
  required String host,
  required int port,
  required KnownHostsNotifier notifier,
}) {
  return (String type, Uint8List fingerprint) async {
    final fp = KnownHostsService.formatFingerprint(fingerprint);
    final svc = notifier.service;

    // If service unavailable, fall through to show dialog as unknown
    if (svc == null) {
      if (!context.mounted) return false;
      final accepted = await showHostKeyDialog(
        context: context,
        host: host,
        port: port,
        keyType: type,
        fingerprint: fp,
        isChanged: false,
      );
      return accepted == true;
    }

    final (status, existingEntry) = svc.lookup(host, port, type, fp);

    switch (status) {
      case HostKeyStatus.trusted:
        return true;
      case HostKeyStatus.unknown:
        if (!context.mounted) return false;
        final accepted = await showHostKeyDialog(
          context: context,
          host: host,
          port: port,
          keyType: type,
          fingerprint: fp,
          isChanged: false,
        );
        if (accepted == true) {
          await notifier.trustHost(host, port, type, fp);
          return true;
        }
        return false;
      case HostKeyStatus.changed:
        if (!context.mounted) return false;
        final accepted = await showHostKeyDialog(
          context: context,
          host: host,
          port: port,
          keyType: type,
          fingerprint: fp,
          isChanged: true,
          previousEntry: existingEntry,
        );
        if (accepted == true) {
          await notifier.trustHost(host, port, type, fp);
          return true;
        }
        return false;
    }
  };
}
