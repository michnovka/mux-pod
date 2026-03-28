import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/core/buffer/cell_flags.dart';
import 'package:xterm/xterm.dart';

void main() {
  group('Terminal CSI prefix handling', () {
    test('CSI > m (kitty progressive enhancement) does not set SGR attributes', () {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.resize(80, 24);

      // ESC[>4;2m is kitty key reporting mode, NOT SGR 4 (underline) + 2 (faint)
      terminal.write('\x1b[>4;2m');

      expect(terminal.cursor.attrs, 0,
          reason: 'CSI > prefix should not be treated as SGR');

      // Write a character and verify it has no underline/faint flags
      terminal.write('A');
      final cell = terminal.mainBuffer.lines[0];
      expect(cell.getAttributes(0), 0,
          reason: 'Cell should have no flags after CSI > m');
    });

    test('CSI > u (kitty keyboard push) does not corrupt state', () {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.resize(80, 24);

      terminal.write('\x1b[>1u');
      terminal.write('B');

      expect(terminal.cursor.attrs, 0);
      expect(terminal.mainBuffer.lines[0].getAttributes(0), 0);
    });

    test('regular SGR still works after CSI > m is ignored', () {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.resize(80, 24);

      // Kitty sequence (should be ignored)
      terminal.write('\x1b[>4;2m');
      // Regular bold
      terminal.write('\x1b[1m');
      terminal.write('C');
      // Reset
      terminal.write('\x1b[0m');
      terminal.write('D');

      expect(terminal.mainBuffer.lines[0].getAttributes(0) & CellFlags.bold,
          CellFlags.bold, reason: 'C should be bold');
      expect(terminal.mainBuffer.lines[0].getAttributes(1), 0,
          reason: 'D should have no flags after reset');
    });
  });

  group('Terminal SGR 22 (normal intensity)', () {
    test('SGR 22 resets both bold and faint', () {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.resize(80, 24);

      // Set bold
      terminal.write('\x1b[1mA');
      expect(terminal.mainBuffer.lines[0].getAttributes(0) & CellFlags.bold,
          CellFlags.bold);

      // SGR 22 should reset bold
      terminal.write('\x1b[22mB');
      expect(terminal.mainBuffer.lines[0].getAttributes(1) & CellFlags.bold, 0,
          reason: 'SGR 22 should reset bold');

      // Set faint
      terminal.write('\x1b[2mC');
      expect(terminal.mainBuffer.lines[0].getAttributes(2) & CellFlags.faint,
          CellFlags.faint);

      // SGR 22 should reset faint too
      terminal.write('\x1b[22mD');
      expect(terminal.mainBuffer.lines[0].getAttributes(3) & CellFlags.faint, 0,
          reason: 'SGR 22 should reset faint');
    });

    test('SGR 22 resets bold+faint when both are set', () {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.resize(80, 24);

      terminal.write('\x1b[1;2mA');
      final flags = terminal.mainBuffer.lines[0].getAttributes(0);
      expect(flags & CellFlags.bold, CellFlags.bold);
      expect(flags & CellFlags.faint, CellFlags.faint);

      terminal.write('\x1b[22mB');
      final flags2 = terminal.mainBuffer.lines[0].getAttributes(1);
      expect(flags2 & CellFlags.bold, 0);
      expect(flags2 & CellFlags.faint, 0);
    });
  });

  group('Terminal synchronized updates', () {
    test('defers repaint notifications until synchronized update ends', () {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.resize(12, 3);

      var notifications = 0;
      terminal.addListener(() {
        notifications++;
      });

      terminal.write('\x1b[?2026hhello');
      expect(notifications, 0);

      terminal.write(' world');
      expect(notifications, 0);

      terminal.write('\x1b[?2026l');
      expect(notifications, 1);
      expect(terminal.mainBuffer.lines[0].getText(0, terminal.viewWidth).trimRight(),
          'hello world');
    });

    test('continues notifying once per write outside synchronized updates', () {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.resize(12, 3);

      var notifications = 0;
      terminal.addListener(() {
        notifications++;
      });

      terminal.write('hello');
      terminal.write(' world');

      expect(notifications, 2);
      expect(terminal.mainBuffer.lines[0].getText(0, terminal.viewWidth).trimRight(),
          'hello world');
    });
  });
}
