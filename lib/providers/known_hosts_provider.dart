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
  late final KnownHostsService _service;

  @override
  KnownHostsState build() {
    final prefs = ref.read(sharedPreferencesProvider);
    if (prefs == null) {
      return const KnownHostsState();
    }
    _service = KnownHostsService(prefs);
    return KnownHostsState(hosts: _service.getAll());
  }

  KnownHostsService get service => _service;

  /// Save a host key and update state.
  Future<void> trustHost(
    String host,
    int port,
    String keyType,
    String fingerprint,
  ) async {
    await _service.save(host, port, keyType, fingerprint);
    state = KnownHostsState(hosts: _service.getAll());
  }

  /// Remove a host key and update state.
  Future<void> removeHost(String host, int port) async {
    await _service.remove(host, port);
    state = KnownHostsState(hosts: _service.getAll());
  }

  /// Build a host key verification callback for NON-INTERACTIVE contexts
  /// (auto-reconnect, background refresh).
  ///
  /// Accepts known/trusted hosts; rejects unknown or changed hosts.
  FutureOr<bool> Function(String type, Uint8List fingerprint)
      buildNonInteractiveVerifier(String host, int port) {
    return (String type, Uint8List fingerprint) {
      final fp = KnownHostsService.formatFingerprint(fingerprint);
      final (status, _) = _service.lookup(host, port, type, fp);
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
    final (status, existingEntry) =
        notifier.service.lookup(host, port, type, fp);

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
