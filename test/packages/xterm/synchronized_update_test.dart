import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

void main() {
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
