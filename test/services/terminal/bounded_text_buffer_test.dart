import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/terminal/bounded_text_buffer.dart';

void main() {
  group('BoundedTextBuffer', () {
    test('retains full content while under the limit', () {
      final buffer = BoundedTextBuffer(maxLength: 16);

      buffer.write('hello');
      buffer.write(' world');

      expect(buffer.length, 11);
      expect(buffer.toString(), 'hello world');
    });

    test('trims the oldest content when writes exceed the limit', () {
      final buffer = BoundedTextBuffer(maxLength: 8);

      buffer.write('hello');
      buffer.write(' world');

      expect(buffer.length, 8);
      expect(buffer.toString(), 'lo world');
    });

    test('keeps only the newest tail of a large single write', () {
      final buffer = BoundedTextBuffer(maxLength: 5);

      buffer.write('abcdefghij');

      expect(buffer.length, 5);
      expect(buffer.toString(), 'fghij');
    });

    test('takeAll returns the buffered text and clears the buffer', () {
      final buffer = BoundedTextBuffer(maxLength: 8);

      buffer.write('1234');

      expect(buffer.takeAll(), '1234');
      expect(buffer.isEmpty, isTrue);
      expect(buffer.length, 0);
    });
  });
}
