import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_muxpod/services/terminal/terminal_search_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalSearchEngine', () {
    test('basic case-insensitive matching', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('Hello World\r\n');

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: 'hello',
      );

      expect(matches, hasLength(1));
      expect(matches[0].start, CellOffset(0, 0));
      expect(matches[0].end, CellOffset(4, 0));
    });

    test('case-sensitive matching', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('Hello hello\r\n');

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: 'hello',
        caseSensitive: true,
      );

      expect(matches, hasLength(1));
      expect(matches[0].start, CellOffset(6, 0));
      expect(matches[0].end, CellOffset(10, 0));
    });

    test('multiple matches', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('abc abc abc\r\n');

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: 'abc',
      );

      expect(matches, hasLength(3));
      expect(matches[0].start, CellOffset(0, 0));
      expect(matches[0].end, CellOffset(2, 0));
      expect(matches[1].start, CellOffset(4, 0));
      expect(matches[1].end, CellOffset(6, 0));
      expect(matches[2].start, CellOffset(8, 0));
      expect(matches[2].end, CellOffset(10, 0));
    });

    test('multi-line search finds match on second line', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('First line\r\n');
      terminal.write('Second line\r\n');

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: 'second',
      );

      expect(matches, hasLength(1));
      expect(matches[0].start, CellOffset(0, 1));
      expect(matches[0].end, CellOffset(5, 1));
    });

    test('empty query returns empty results', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('Hello World\r\n');

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: '',
      );

      expect(matches, isEmpty);
    });

    test('empty buffer returns empty results', () {
      final terminal = Terminal(maxLines: 1000);

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: 'hello',
      );

      expect(matches, isEmpty);
    });

    test('no match returns empty results', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('Hello World\r\n');

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: 'xyz',
      );

      expect(matches, isEmpty);
    });

    test('regex: valid pattern matches digits', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('line 42 end\r\n');

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: r'\d+',
        regex: true,
      );

      expect(matches, hasLength(1));
      expect(matches[0].start, CellOffset(5, 0));
      expect(matches[0].end, CellOffset(6, 0));
    });

    test('regex: invalid pattern throws FormatException', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('some text\r\n');

      expect(
        () => TerminalSearchEngine.search(
          terminal.mainBuffer,
          query: '[invalid',
          regex: true,
        ),
        throwsFormatException,
      );
    });

    test('zero-length regex matches are skipped', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('hello world\r\n');

      final caretMatches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: r'^',
        regex: true,
      );
      expect(caretMatches, isEmpty);

      final boundaryMatches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: r'\b',
        regex: true,
      );
      expect(boundaryMatches, isEmpty);
    });

    test('special regex chars are escaped in plain mode', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('a.b axb\r\n');

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: 'a.b',
      );

      expect(matches, hasLength(1));
      expect(matches[0].start, CellOffset(0, 0));
      expect(matches[0].end, CellOffset(2, 0));
    });

    test('wide characters (CJK) have correct cell offsets', () {
      final terminal = Terminal(maxLines: 1000);
      terminal.write('a你好b\r\n');

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: '好',
      );

      expect(matches, hasLength(1));
      // 'a' at cell 0, '你' at cells 1-2, '好' at cells 3-4, 'b' at cell 5
      expect(matches[0].start, CellOffset(3, 0));
      expect(matches[0].end, CellOffset(4, 0));
    });

    test('wrapped lines: search across wrap boundary', () {
      final terminal = Terminal(maxLines: 1000);
      // Write a string that exceeds 80 columns to force wrapping.
      // Place a search term spanning the wrap boundary at columns 78-82.
      final prefix = 'A' * 78;
      final searchTerm = 'FIND';
      final suffix = 'B' * 10;
      terminal.write('$prefix$searchTerm$suffix\r\n');

      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: 'FIND',
      );

      expect(matches, hasLength(1));
      // 'FIND' starts at column 78 on row 0. The terminal is 80 cols wide,
      // so 'FI' is on row 0 (cols 78-79) and 'ND' wraps to row 1 (cols 0-1).
      expect(matches[0].start, CellOffset(78, 0));
      expect(matches[0].end, CellOffset(1, 1));
    });
  });
}
