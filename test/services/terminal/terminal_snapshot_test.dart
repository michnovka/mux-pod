import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/terminal/terminal_snapshot.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalSnapshot', () {
    test('restores a normal-mode snapshot into the main buffer', () {
      final terminal = createTerminalFromSnapshot(
        frame: const TerminalSnapshotFrame(
          content: 'hello\nworld',
          paneWidth: 80,
          paneHeight: 24,
          cursorX: 4,
          cursorY: 1,
        ),
        maxLines: 1000,
        showCursor: true,
        onOutput: (_) {},
        controller: TerminalController(),
      );

      expect(terminal.isUsingAltBuffer, isFalse);
      expect(terminal.mainBuffer.getText(), contains('hello'));
      expect(terminal.mainBuffer.getText(), contains('world'));
      expect(terminal.altBuffer.getText(), isNot(contains('hello')));
    });

    test('replays captured lines from column zero', () {
      final terminal = createTerminalFromSnapshot(
        frame: const TerminalSnapshotFrame(
          content: 'alpha\nbeta',
          paneWidth: 80,
          paneHeight: 24,
        ),
        maxLines: 1000,
        showCursor: true,
        onOutput: (_) {},
        controller: TerminalController(),
      );

      expect(terminal.mainBuffer.lines[0].getText().trimRight(), 'alpha');
      expect(terminal.mainBuffer.lines[1].getText().trimRight(), 'beta');
    });

    test(
      'restores both main and alternate buffers when alternate screen is active',
      () {
        final terminal = createTerminalFromSnapshot(
          frame: const TerminalSnapshotFrame(
            content: 'vim buffer',
            mainContent: 'shell prompt',
            alternateScreen: true,
            paneWidth: 80,
            paneHeight: 24,
            cursorX: 2,
            cursorY: 0,
          ),
          maxLines: 1000,
          showCursor: true,
          onOutput: (_) {},
          controller: TerminalController(),
        );

        expect(terminal.isUsingAltBuffer, isTrue);
        expect(terminal.mainBuffer.getText(), contains('shell prompt'));
        expect(terminal.altBuffer.getText(), contains('vim buffer'));
      },
    );

    test(
      'clears stale alternate-buffer content when reseeding back to the main screen',
      () {
        final terminal = Terminal(maxLines: 1000, reflowEnabled: false);
        final controller = TerminalController();

        applySnapshotToTerminal(
          terminal: terminal,
          controller: controller,
          frame: const TerminalSnapshotFrame(
            content: 'alt view',
            mainContent: 'shell prompt',
            alternateScreen: true,
            paneWidth: 80,
            paneHeight: 24,
          ),
          showCursor: true,
        );

        applySnapshotToTerminal(
          terminal: terminal,
          controller: controller,
          frame: const TerminalSnapshotFrame(
            content: 'plain prompt',
            paneWidth: 80,
            paneHeight: 24,
          ),
          showCursor: true,
        );

        expect(terminal.isUsingAltBuffer, isFalse);
        expect(terminal.mainBuffer.getText(), contains('plain prompt'));
        expect(terminal.altBuffer.getText(), isNot(contains('alt view')));
      },
    );

    test(
      'restores terminal input and viewport modes from snapshot metadata',
      () {
        final terminal = createTerminalFromSnapshot(
          frame: const TerminalSnapshotFrame(
            content: 'prompt',
            paneWidth: 80,
            paneHeight: 24,
            cursorX: 3,
            cursorY: 5,
            insertMode: true,
            cursorKeysMode: true,
            appKeypadMode: true,
            autoWrapMode: false,
            cursorVisible: false,
            originMode: true,
            scrollRegionUpper: 2,
            scrollRegionLower: 20,
          ),
          maxLines: 1000,
          showCursor: true,
          onOutput: (_) {},
          controller: TerminalController(),
        );

        expect(terminal.insertMode, isTrue);
        expect(terminal.cursorKeysMode, isTrue);
        expect(terminal.appKeypadMode, isTrue);
        expect(terminal.autoWrapMode, isFalse);
        expect(terminal.cursorVisibleMode, isFalse);
        expect(terminal.originMode, isTrue);
        expect(terminal.buffer.marginTop, 2);
        expect(terminal.buffer.marginBottom, 20);
        expect(terminal.buffer.cursorX, 3);
        expect(terminal.buffer.cursorY, 5);
      },
    );
  });
}
