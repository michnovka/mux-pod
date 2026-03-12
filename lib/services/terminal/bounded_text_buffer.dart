import 'dart:collection';

/// A FIFO text buffer that retains only the newest characters up to [maxLength].
class BoundedTextBuffer {
  final int maxLength;
  final Queue<String> _chunks = Queue<String>();
  int _length = 0;

  BoundedTextBuffer({required this.maxLength}) : assert(maxLength > 0);

  bool get isEmpty => _length == 0;

  int get length => _length;

  void write(String data) {
    if (data.isEmpty) {
      return;
    }

    if (data.length >= maxLength) {
      final retained = data.substring(data.length - maxLength);
      _chunks
        ..clear()
        ..add(retained);
      _length = retained.length;
      return;
    }

    _chunks.addLast(data);
    _length += data.length;
    _trimToSize();
  }

  String takeAll() {
    final value = toString();
    clear();
    return value;
  }

  void clear() {
    _chunks.clear();
    _length = 0;
  }

  void _trimToSize() {
    while (_length > maxLength && _chunks.isNotEmpty) {
      final overflow = _length - maxLength;
      final oldestChunk = _chunks.removeFirst();

      if (oldestChunk.length <= overflow) {
        _length -= oldestChunk.length;
        continue;
      }

      final trimmedChunk = oldestChunk.substring(overflow);
      _chunks.addFirst(trimmedChunk);
      _length -= overflow;
    }
  }

  @override
  String toString() => _chunks.join();
}
