import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

BufferLine _line(String text, int width) {
  final line = BufferLine(width);
  final style = CursorStyle.empty;
  final runes = text.runes.toList(growable: false);
  for (var i = 0; i < runes.length && i < width; i++) {
    line.setCell(i, runes[i], 1, style);
  }
  return line;
}

List<String> _visibleLines(Terminal terminal) {
  final buffer = terminal.mainBuffer;
  final start = buffer.scrollBack;
  return List<String>.generate(
    terminal.viewHeight,
    (index) => buffer.lines[start + index].getText(0, terminal.viewWidth),
    growable: false,
  );
}

void main() {
  group('Buffer scroll regions', () {
    test('lineFeed scrolls only the partial scroll region on main buffer', () {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.resize(4, 5);
      terminal.useMainBuffer();
      terminal.mainBuffer.lines.replaceWith([
        _line('A', 4),
        _line('B', 4),
        _line('C', 4),
        _line('D', 4),
        _line('E', 4),
      ]);

      terminal.setMargins(0, 2);
      terminal.setCursor(0, 2);
      terminal.lineFeed();

      expect(_visibleLines(terminal), ['B', 'C', '', 'D', 'E']);
    });

    test('lineFeed at full-height main scroll region still grows scrollback', () {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.resize(4, 3);
      terminal.useMainBuffer();
      terminal.mainBuffer.lines.replaceWith([
        _line('A', 4),
        _line('B', 4),
        _line('C', 4),
      ]);

      terminal.setMargins(0, 2);
      terminal.setCursor(0, 2);
      terminal.lineFeed();

      expect(terminal.mainBuffer.scrollBack, 1);
      expect(_visibleLines(terminal), ['B', 'C', '']);
    });
  });
}
