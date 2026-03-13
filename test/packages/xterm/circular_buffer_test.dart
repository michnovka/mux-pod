import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/src/utils/circular_buffer.dart';

/// Minimal item for exercising [IndexAwareCircularBuffer].
class _Item with IndexedItem {
  final String label;
  _Item(this.label);

  @override
  String toString() => label;
}

/// Populate a buffer with items labelled 0..count-1.
IndexAwareCircularBuffer<_Item> _filledBuffer(int maxLength, int count) {
  final buf = IndexAwareCircularBuffer<_Item>(maxLength);
  for (var i = 0; i < count; i++) {
    buf.push(_Item('$i'));
  }
  return buf;
}

/// Assert every logical slot holds an attached item with the correct index.
void _assertAllAttached(IndexAwareCircularBuffer<_Item> buf) {
  for (var i = 0; i < buf.length; i++) {
    final item = buf[i];
    expect(item.attached, isTrue, reason: 'buf[$i] (${item.label}) detached');
    expect(item.index, i, reason: 'buf[$i] (${item.label}) index mismatch');
  }
}

void main() {
  group('IndexAwareCircularBuffer same-buffer reassignment', () {
    test('shift-left (scrollUp pattern) keeps all items attached', () {
      // Simulates Buffer.scrollUp: buf[i] = buf[i+1] for each row.
      final buf = _filledBuffer(5, 5);
      // Shift left by 1: copy [1] to [0], [2] to [1], ..., then new at [4].
      for (var i = 0; i < 4; i++) {
        buf[i] = buf[i + 1];
      }
      buf[4] = _Item('new');

      _assertAllAttached(buf);
      expect(buf[0].label, '1');
      expect(buf[3].label, '4');
      expect(buf[4].label, 'new');
    });

    test('shift-right (scrollDown pattern) keeps all items attached', () {
      // Simulates Buffer.scrollDown: copy in reverse.
      final buf = _filledBuffer(5, 5);
      for (var i = 4; i > 0; i--) {
        buf[i] = buf[i - 1];
      }
      buf[0] = _Item('new');

      _assertAllAttached(buf);
      expect(buf[0].label, 'new');
      expect(buf[1].label, '0');
      expect(buf[4].label, '3');
    });

    test('shift-left after trimStart keeps all items attached', () {
      // The scenario that was broken before the identity-scan fix:
      // trimStart advances _startIndex without _absoluteStartIndex,
      // so the old index-based _adoptChild nulled the wrong slot.
      final buf = _filledBuffer(5, 5);
      buf.trimStart(2); // logical [0,1,2] = old [2,3,4]
      expect(buf.length, 3);

      // Shift left by 1 within the trimmed buffer.
      buf[0] = buf[1];
      buf[1] = buf[2];
      buf[2] = _Item('new');

      _assertAllAttached(buf);
      expect(buf[0].label, '3');
      expect(buf[1].label, '4');
      expect(buf[2].label, 'new');
    });

    test('shift-right after trimStart keeps all items attached', () {
      final buf = _filledBuffer(5, 5);
      buf.trimStart(2);
      expect(buf.length, 3);

      buf[2] = buf[1];
      buf[1] = buf[0];
      buf[0] = _Item('new');

      _assertAllAttached(buf);
      expect(buf[0].label, 'new');
      expect(buf[1].label, '2');
      expect(buf[2].label, '3');
    });

    test('insert after trimStart + shift does not crash', () {
      // insert() uses _moveChild which asserts attached.
      // With prior corruption, this would throw.
      final buf = _filledBuffer(8, 8);
      buf.trimStart(3); // length=5
      // Shift left by 1 (simulating scrollUp)
      for (var i = 0; i < buf.length - 1; i++) {
        buf[i] = buf[i + 1];
      }
      buf[buf.length - 1] = _Item('empty');

      // Now insert at the end — exercises _moveChild on post-shift items.
      buf.insert(buf.length, _Item('inserted'));

      _assertAllAttached(buf);
    });

    test('shift-left on a wrapped (full + pushed) buffer stays attached', () {
      // After pushing beyond capacity, _startIndex > 0 so the logical
      // indices wrap around the backing array.
      final buf = IndexAwareCircularBuffer<_Item>(5);
      for (var i = 0; i < 8; i++) {
        buf.push(_Item('$i')); // pushes 0..7, keeps 3..7
      }
      expect(buf.length, 5);
      expect(buf[0].label, '3');

      // Shift left by 1 within the wrapped region.
      for (var i = 0; i < 4; i++) {
        buf[i] = buf[i + 1];
      }
      buf[4] = _Item('new');

      _assertAllAttached(buf);
      expect(buf[0].label, '4');
      expect(buf[4].label, 'new');
    });

    test('multiple sequential scrollUp cycles stay clean', () {
      final buf = _filledBuffer(5, 5);
      for (var cycle = 0; cycle < 3; cycle++) {
        for (var i = 0; i < 4; i++) {
          buf[i] = buf[i + 1];
        }
        buf[4] = _Item('cycle$cycle');
        _assertAllAttached(buf);
      }
      expect(buf[4].label, 'cycle2');
    });

    test('deleteLines pattern (shift-up with gap) stays attached', () {
      // Buffer.deleteLines: buf[i] = buf[i + count] then fill tail.
      final buf = _filledBuffer(6, 6);
      const count = 2;
      const start = 1; // delete 2 lines starting at index 1
      final end = buf.length - 1;

      for (var i = start; i <= end - count; i++) {
        buf[i] = buf[i + count];
      }
      for (var i = 0; i < count; i++) {
        buf[end - i] = _Item('blank');
      }

      _assertAllAttached(buf);
      expect(buf[start].label, '3');
      expect(buf[end].label, 'blank');
    });
  });
}
