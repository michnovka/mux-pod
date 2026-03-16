import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/terminal/terminal_url_detector.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('URL regex', () {
    test('matches basic https URL', () {
      final urls = TerminalUrlDetector.scanText('visit https://example.com now');
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://example.com');
    });

    test('matches basic http URL', () {
      final urls = TerminalUrlDetector.scanText('see http://foo.bar/path');
      expect(urls, hasLength(1));
      expect(urls[0].url, 'http://foo.bar/path');
    });

    test('matches URL with query string and fragment', () {
      final urls = TerminalUrlDetector.scanText(
        'https://example.com/path?q=1&b=2#section',
      );
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://example.com/path?q=1&b=2#section');
    });

    test('excludes trailing period', () {
      final urls = TerminalUrlDetector.scanText(
        'Visit https://example.com.',
      );
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://example.com');
    });

    test('excludes trailing comma', () {
      final urls = TerminalUrlDetector.scanText(
        'see https://example.com, then',
      );
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://example.com');
    });

    test('excludes trailing exclamation', () {
      final urls = TerminalUrlDetector.scanText('https://example.com!');
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://example.com');
    });

    test('extracts URL from parentheses', () {
      final urls = TerminalUrlDetector.scanText('(https://example.com)');
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://example.com');
    });

    test('extracts URL from double quotes', () {
      final urls = TerminalUrlDetector.scanText('"https://example.com"');
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://example.com');
    });

    test('extracts URL from angle brackets', () {
      final urls = TerminalUrlDetector.scanText('<https://example.com>');
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://example.com');
    });

    test('matches URL with port', () {
      final urls = TerminalUrlDetector.scanText('https://localhost:8080/api');
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://localhost:8080/api');
    });

    test('matches URL with auth', () {
      final urls = TerminalUrlDetector.scanText(
        'https://user:pass@host.com/path',
      );
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://user:pass@host.com/path');
    });

    test('does not match ftp URLs', () {
      final urls = TerminalUrlDetector.scanText('ftp://files.example.com');
      expect(urls, isEmpty);
    });

    test('does not match bare domains without protocol', () {
      final urls = TerminalUrlDetector.scanText('example.com/path');
      expect(urls, isEmpty);
    });

    test('does not match plain text', () {
      final urls = TerminalUrlDetector.scanText('hello world');
      expect(urls, isEmpty);
    });

    test('detects multiple URLs on one line', () {
      final urls = TerminalUrlDetector.scanText(
        'see https://a.com and https://b.com/path',
      );
      expect(urls, hasLength(2));
      expect(urls[0].url, 'https://a.com');
      expect(urls[1].url, 'https://b.com/path');
    });

    test('matches URL with path, dashes, and underscores', () {
      final urls = TerminalUrlDetector.scanText(
        'https://my-host.example.com/path_segment/file-name',
      );
      expect(urls, hasLength(1));
      expect(
        urls[0].url,
        'https://my-host.example.com/path_segment/file-name',
      );
    });
  });

  group('scanText cell offsets', () {
    test('reports correct start and end column', () {
      final urls = TerminalUrlDetector.scanText(
        'abc https://x.co def',
        row: 5,
      );
      expect(urls, hasLength(1));
      expect(urls[0].start, CellOffset(4, 5));
      // 'https://x.co' is 12 chars, last char at index 15
      expect(urls[0].end, CellOffset(15, 5));
    });

    test('multiple URLs have correct offsets', () {
      final urls = TerminalUrlDetector.scanText(
        'http://a.co http://b.co',
      );
      expect(urls, hasLength(2));
      expect(urls[0].start.x, 0);
      expect(urls[1].start.x, 12);
    });
  });

  group('hit testing', () {
    test('returns URL when tapping first char', () {
      final urls = TerminalUrlDetector.scanText('https://example.com');
      final hit = TerminalUrlDetector.getUrlAt(urls, CellOffset(0, 0));
      expect(hit, isNotNull);
      expect(hit!.url, 'https://example.com');
    });

    test('returns URL when tapping last char', () {
      final urls = TerminalUrlDetector.scanText('https://example.com');
      final lastCol = 'https://example.com'.length - 1;
      final hit = TerminalUrlDetector.getUrlAt(urls, CellOffset(lastCol, 0));
      expect(hit, isNotNull);
    });

    test('returns URL when tapping middle char', () {
      final urls = TerminalUrlDetector.scanText('https://example.com');
      final hit = TerminalUrlDetector.getUrlAt(urls, CellOffset(10, 0));
      expect(hit, isNotNull);
    });

    test('returns null when tapping outside URL', () {
      final urls = TerminalUrlDetector.scanText(
        'abc https://example.com def',
      );
      expect(
        TerminalUrlDetector.getUrlAt(urls, CellOffset(0, 0)),
        isNull,
      );
      expect(
        TerminalUrlDetector.getUrlAt(urls, CellOffset(26, 0)),
        isNull,
      );
    });

    test('returns null when no URLs detected', () {
      final urls = TerminalUrlDetector.scanText('hello world');
      final hit = TerminalUrlDetector.getUrlAt(urls, CellOffset(3, 0));
      expect(hit, isNull);
    });

    test('returns correct URL when between two URLs', () {
      final urls = TerminalUrlDetector.scanText(
        'http://a.co XXX http://b.co',
      );
      // Tap in the gap between the two URLs
      final hit = TerminalUrlDetector.getUrlAt(urls, CellOffset(13, 0));
      expect(hit, isNull);
    });
  });

  group('scanLines with Buffer', () {
    test('detects URL on a single line', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('hello https://example.com world\r\n');

      final urls = TerminalUrlDetector.scanLines(terminal.buffer, 0, 0);
      expect(urls, hasLength(1));
      expect(urls[0].url, 'https://example.com');
      expect(urls[0].start.y, 0);
      expect(urls[0].end.y, 0);
    });

    test('detects URLs on multiple lines', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('line1 https://a.com\r\n');
      terminal.write('line2 https://b.com\r\n');

      final urls = TerminalUrlDetector.scanLines(terminal.buffer, 0, 1);
      expect(urls, hasLength(2));
      expect(urls[0].url, 'https://a.com');
      expect(urls[1].url, 'https://b.com');
    });

    test('returns empty for lines without URLs', () {
      final terminal = Terminal(maxLines: 100);
      terminal.write('just plain text\r\n');
      terminal.write('more plain text\r\n');

      final urls = TerminalUrlDetector.scanLines(terminal.buffer, 0, 1);
      expect(urls, isEmpty);
    });

    test('handles empty buffer', () {
      final terminal = Terminal(maxLines: 100);
      final urls = TerminalUrlDetector.scanLines(terminal.buffer, 0, 0);
      expect(urls, isEmpty);
    });
  });

  group('DetectedUrl equality', () {
    test('equal URLs', () {
      const a = DetectedUrl(
        url: 'https://example.com',
        start: CellOffset(0, 0),
        end: CellOffset(18, 0),
      );
      const b = DetectedUrl(
        url: 'https://example.com',
        start: CellOffset(0, 0),
        end: CellOffset(18, 0),
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('different URLs are not equal', () {
      const a = DetectedUrl(
        url: 'https://a.com',
        start: CellOffset(0, 0),
        end: CellOffset(12, 0),
      );
      const b = DetectedUrl(
        url: 'https://b.com',
        start: CellOffset(0, 0),
        end: CellOffset(12, 0),
      );
      expect(a, isNot(equals(b)));
    });

    test('same URL at different positions are not equal', () {
      const a = DetectedUrl(
        url: 'https://example.com',
        start: CellOffset(0, 0),
        end: CellOffset(18, 0),
      );
      const b = DetectedUrl(
        url: 'https://example.com',
        start: CellOffset(5, 1),
        end: CellOffset(23, 1),
      );
      expect(a, isNot(equals(b)));
    });
  });
}
