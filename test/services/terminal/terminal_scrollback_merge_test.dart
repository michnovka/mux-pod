import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/terminal/terminal_scrollback_merge.dart';
import 'package:xterm/xterm.dart';

void main() {
  List<String> lineTexts(Terminal terminal) {
    return terminal.mainBuffer.lines
        .toList()
        .map(debugTerminalBufferLineText)
        .toList(growable: false);
  }

  Terminal buildTerminal(List<String> lines) {
    final terminal = Terminal(maxLines: 100, reflowEnabled: false);
    terminal.resize(20, lines.isEmpty ? 1 : lines.length);
    terminal.mainBuffer.lines.replaceWith(
      cloneTerminalBufferLines(
        lines.map((line) => debugCreateTerminalBufferLine(line)),
      ),
    );
    return terminal;
  }

  group('terminal scrollback merge', () {
    test('finds overlap between older suffix and newer prefix', () {
      final overlap = findTerminalScrollbackOverlap(
        olderLines: [
          debugCreateTerminalBufferLine('older-1'),
          debugCreateTerminalBufferLine('older-2'),
          debugCreateTerminalBufferLine('shared-1'),
          debugCreateTerminalBufferLine('shared-2'),
        ],
        newerLines: [
          debugCreateTerminalBufferLine('shared-1'),
          debugCreateTerminalBufferLine('shared-2'),
          debugCreateTerminalBufferLine('newer-1'),
        ],
      );

      expect(overlap, 2);
    });

    test('finds lenient overlap when wrapped flag differs at the seam', () {
      final overlap = findTerminalScrollbackOverlapLenient(
        olderLines: [
          debugCreateTerminalBufferLine('older-1'),
          debugCreateTerminalBufferLine('shared-1', wrapped: true),
          debugCreateTerminalBufferLine('shared-2'),
        ],
        newerLines: [
          debugCreateTerminalBufferLine('shared-1'),
          debugCreateTerminalBufferLine('shared-2'),
          debugCreateTerminalBufferLine('newer-1'),
        ],
      );

      expect(overlap, 2);
    });

    test('prepends only missing scrollback and preserves current lines', () {
      final terminal = buildTerminal([
        'shared-1',
        'shared-2',
        'newer-1',
        'newer-2',
      ]);

      final applied = prependTerminalScrollback(
        terminal: terminal,
        fullSnapshotLines: [
          debugCreateTerminalBufferLine('older-1'),
          debugCreateTerminalBufferLine('older-2'),
          debugCreateTerminalBufferLine('shared-1'),
          debugCreateTerminalBufferLine('shared-2'),
        ],
      );

      expect(applied, isTrue);
      expect(
        lineTexts(terminal),
        [
          'older-1',
          'older-2',
          'shared-1',
          'shared-2',
          'newer-1',
          'newer-2',
        ],
      );
    });

    test('prepends scrollback when seam differs only in row metadata', () {
      final terminal = buildTerminal([
        'shared-1',
        'shared-2',
        'newer-1',
      ]);

      final applied = prependTerminalScrollback(
        terminal: terminal,
        fullSnapshotLines: [
          debugCreateTerminalBufferLine('older-1'),
          debugCreateTerminalBufferLine('shared-1', wrapped: true),
          debugCreateTerminalBufferLine('shared-2'),
          debugCreateTerminalBufferLine('newer-1'),
        ],
      );

      expect(applied, isTrue);
      expect(
        lineTexts(terminal),
        ['older-1', 'shared-1', 'shared-2', 'newer-1'],
      );
    });

    test(
      'uses reference lines for overlap detection and keeps mutated current lines',
      () {
        final terminal = buildTerminal([
          'shared-1-updated',
          'shared-2',
          'live-1',
        ]);

        final applied = prependTerminalScrollback(
          terminal: terminal,
          fullSnapshotLines: [
            debugCreateTerminalBufferLine('older-1'),
            debugCreateTerminalBufferLine('shared-1'),
            debugCreateTerminalBufferLine('shared-2'),
          ],
          referenceLines: [
            debugCreateTerminalBufferLine('shared-1'),
            debugCreateTerminalBufferLine('shared-2'),
          ],
        );

        expect(applied, isTrue);
        expect(
          lineTexts(terminal),
          ['older-1', 'shared-1-updated', 'shared-2', 'live-1'],
        );
      },
    );

    test('notifies terminal listeners after applying backfill', () {
      final terminal = buildTerminal([
        'shared-1',
        'shared-2',
        'newer-1',
      ]);
      var notifications = 0;
      terminal.addListener(() {
        notifications += 1;
      });

      final applied = prependTerminalScrollback(
        terminal: terminal,
        fullSnapshotLines: [
          debugCreateTerminalBufferLine('older-1'),
          debugCreateTerminalBufferLine('shared-1'),
          debugCreateTerminalBufferLine('shared-2'),
        ],
      );

      expect(applied, isTrue);
      expect(notifications, 1);
    });

    test('skips merge when there is no safe overlap', () {
      final terminal = buildTerminal([
        'current-1',
        'current-2',
      ]);

      final applied = prependTerminalScrollback(
        terminal: terminal,
        fullSnapshotLines: [
          debugCreateTerminalBufferLine('older-1'),
          debugCreateTerminalBufferLine('older-2'),
        ],
      );

      expect(applied, isFalse);
      expect(lineTexts(terminal), ['current-1', 'current-2']);
    });
  });
}
