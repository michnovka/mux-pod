import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/keychain/known_hosts_service.dart';
import '../../theme/design_colors.dart';

/// Show a host key verification dialog.
///
/// Returns `true` if the user accepts the key, `false` or `null` if rejected.
Future<bool?> showHostKeyDialog({
  required BuildContext context,
  required String host,
  required int port,
  required String keyType,
  required String fingerprint,
  required bool isChanged,
  KnownHostEntry? previousEntry,
}) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _HostKeyDialog(
      host: host,
      port: port,
      keyType: keyType,
      fingerprint: fingerprint,
      isChanged: isChanged,
      previousEntry: previousEntry,
    ),
  );
}

class _HostKeyDialog extends StatelessWidget {
  final String host;
  final int port;
  final String keyType;
  final String fingerprint;
  final bool isChanged;
  final KnownHostEntry? previousEntry;

  const _HostKeyDialog({
    required this.host,
    required this.port,
    required this.keyType,
    required this.fingerprint,
    required this.isChanged,
    this.previousEntry,
  });

  String get _hostDisplay => port == 22 ? host : '$host:$port';

  @override
  Widget build(BuildContext context) {
    if (isChanged) {
      return _buildChangedDialog(context);
    }
    return _buildUnknownDialog(context);
  }

  Widget _buildUnknownDialog(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.vpn_key, size: 20),
          SizedBox(width: 8),
          Text('New Host Key'),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The server at $_hostDisplay presented a $keyType key.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Fingerprint (MD5):',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 4),
            _FingerprintDisplay(fingerprint: fingerprint),
            const SizedBox(height: 12),
            const Text(
              'This is the first connection to this server. '
              'Verify the fingerprint matches the server before trusting.',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Trust'),
        ),
      ],
    );
  }

  Widget _buildChangedDialog(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: DesignColors.error),
          const SizedBox(width: 8),
          Text(
            'Host Key Changed',
            style: TextStyle(color: DesignColors.error),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The server at $_hostDisplay presented a DIFFERENT key '
              'than previously trusted.',
              style: TextStyle(color: DesignColors.error),
            ),
            if (previousEntry != null) ...[
              const SizedBox(height: 12),
              const Text(
                'Previous fingerprint:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
              ),
              const SizedBox(height: 4),
              _FingerprintDisplay(fingerprint: previousEntry!.fingerprint),
              Text(
                'Type: ${previousEntry!.keyType}',
                style: const TextStyle(fontSize: 12),
              ),
            ],
            const SizedBox(height: 12),
            const Text(
              'New fingerprint:',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            const SizedBox(height: 4),
            _FingerprintDisplay(fingerprint: fingerprint),
            Text('Type: $keyType', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 12),
            const Text(
              'This could indicate a man-in-the-middle attack, '
              'or the server was reinstalled.',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Reject'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: DesignColors.error),
          child: const Text('Trust New Key'),
        ),
      ],
    );
  }
}

class _FingerprintDisplay extends StatelessWidget {
  final String fingerprint;

  const _FingerprintDisplay({required this.fingerprint});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: fingerprint));
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Fingerprint copied'),
            duration: Duration(seconds: 2),
          ),
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(4),
        ),
        child: SelectableText(
          fingerprint,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}
