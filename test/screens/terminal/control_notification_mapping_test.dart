import 'package:flutter_test/flutter_test.dart';

/// Documents the expected mapping from tmux control mode notifications
/// to sync actions (refreshTree, resyncPane).
///
/// This test serves as a contract: if the notification handler in
/// terminal_screen.dart is changed, this table should be updated to
/// match. The actual handler is a private method on _TerminalScreenState
/// and cannot be unit-tested directly without full widget instantiation.
void main() {
  /// Expected notification → action mapping.
  ///
  /// Each entry: notification name → (refreshTree, resyncPane).
  /// This must match the switch in _handleControlNotification().
  const expectedMapping = <String, (bool refreshTree, bool resyncPane)>{
    'layout-change': (true, true),
    'pane-mode-changed': (false, false), // ignored intentionally
    'session-changed': (true, true),
    'session-window-changed': (true, true),
    'window-close': (true, true),
    'window-pane-changed': (true, true),
    'sessions-changed': (true, false),
    'unlinked-window-add': (true, false),
    'unlinked-window-close': (true, false),
    'window-add': (true, false),
    'window-renamed': (true, false),
    'exit': (false, false), // handled separately
  };

  group('control notification mapping contract', () {
    test('session-window-changed requires both refreshTree and resyncPane', () {
      final entry = expectedMapping['session-window-changed'];
      expect(entry, isNotNull, reason: 'session-window-changed must be mapped');
      expect(
        entry!.$1,
        isTrue,
        reason: 'session-window-changed must refresh tree to update active window',
      );
      expect(
        entry.$2,
        isTrue,
        reason: 'session-window-changed must resync pane to load new window content',
      );
    });

    test('all window/session change notifications refresh the tree', () {
      final treeChanges = [
        'session-changed',
        'session-window-changed',
        'sessions-changed',
        'window-add',
        'window-close',
        'window-renamed',
        'window-pane-changed',
      ];
      for (final name in treeChanges) {
        final entry = expectedMapping[name];
        expect(
          entry?.$1,
          isTrue,
          reason: '$name must refresh tree',
        );
      }
    });

    test('notifications that change the active pane also resync pane content', () {
      final paneChanges = [
        'layout-change',
        'session-changed',
        'session-window-changed',
        'window-close',
        'window-pane-changed',
      ];
      for (final name in paneChanges) {
        final entry = expectedMapping[name];
        expect(
          entry?.$2,
          isTrue,
          reason: '$name must resync pane to show correct terminal content',
        );
      }
    });
  });
}
