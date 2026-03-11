/// A class that queues input during disconnection
///
/// Holds key input while the SSH connection is disconnected,
/// allowing it to be sent in bulk after reconnection.
class InputQueue {
  final List<String> _queue = [];

  /// Maximum queue size (in characters)
  static const int maxSize = 1000;

  /// Add input to the queue
  ///
  /// If maxSize would be exceeded, the input is not added and isOverflow becomes true.
  void enqueue(String input) {
    if (length + input.length <= maxSize) {
      _queue.add(input);
    }
  }

  /// Dequeue and concatenate all input in the queue
  ///
  /// After dequeuing, the queue becomes empty.
  String flush() {
    if (_queue.isEmpty) return '';
    final result = _queue.join();
    _queue.clear();
    return result;
  }

  /// Clear the queue
  void clear() {
    _queue.clear();
  }

  /// Whether the queue is empty
  bool get isEmpty => _queue.isEmpty;

  /// Total number of characters in the queue
  int get length {
    int total = 0;
    for (final item in _queue) {
      total += item.length;
    }
    return total;
  }

  /// Whether in overflow state (no more input can be added)
  bool get isOverflow => length >= maxSize;

  /// Number of items in the queue
  int get itemCount => _queue.length;
}
