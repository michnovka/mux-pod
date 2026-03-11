/// Terminal diff calculation service
///
/// For performance optimization during high-frequency updates,
/// detects diffs line by line and identifies only the changed portions.
class TerminalDiff {
  /// Previous content (line by line)
  List<String> _previousLines = [];

  /// Hash values per line from previous content
  List<int> _previousHashes = [];

  /// Number of consecutive frames without changes
  int _unchangedFrames = 0;

  /// Diff calculation result
  DiffResult calculateDiff(String newContent) {
    final newLines = newContent.split('\n');
    final newHashes = newLines.map((line) => line.hashCode).toList();

    // Full update on first run or when line count differs significantly
    if (_previousLines.isEmpty ||
        (newLines.length - _previousLines.length).abs() > 10) {
      _previousLines = newLines;
      _previousHashes = newHashes;
      _unchangedFrames = 0;
      return DiffResult(
        hasChanges: true,
        isFullUpdate: true,
        changedLineIndices: List.generate(newLines.length, (i) => i),
        unchangedFrames: 0,
      );
    }

    // Detect diffs line by line
    final changedIndices = <int>[];
    final maxLen =
        newLines.length > _previousLines.length ? newLines.length : _previousLines.length;

    for (int i = 0; i < maxLen; i++) {
      if (i >= _previousLines.length) {
        // Newly added line
        changedIndices.add(i);
      } else if (i >= newLines.length) {
        // Deleted line (usually doesn't happen)
        changedIndices.add(i);
      } else if (_previousHashes[i] != newHashes[i]) {
        // Changed line
        changedIndices.add(i);
      }
    }

    // Increment frame count if no changes
    if (changedIndices.isEmpty) {
      _unchangedFrames++;
    } else {
      _unchangedFrames = 0;
    }

    // Update previous state
    _previousLines = newLines;
    _previousHashes = newHashes;

    return DiffResult(
      hasChanges: changedIndices.isNotEmpty,
      isFullUpdate: false,
      changedLineIndices: changedIndices,
      unchangedFrames: _unchangedFrames,
    );
  }

  /// Reset diff state
  void reset() {
    _previousLines = [];
    _previousHashes = [];
    _unchangedFrames = 0;
  }

  /// Get the number of consecutive frames without changes
  int get unchangedFrames => _unchangedFrames;
}

/// Diff calculation result
class DiffResult {
  /// Whether there are changes
  final bool hasChanges;

  /// Whether a full update is needed
  final bool isFullUpdate;

  /// Indices of changed lines
  final List<int> changedLineIndices;

  /// Number of consecutive frames without changes
  final int unchangedFrames;

  const DiffResult({
    required this.hasChanges,
    required this.isFullUpdate,
    required this.changedLineIndices,
    required this.unchangedFrames,
  });

  /// Ratio of changed lines (0.0 to 1.0)
  double get changeRatio {
    if (changedLineIndices.isEmpty) return 0.0;
    // Estimated total line count
    final totalLines = changedLineIndices.isEmpty
        ? 1
        : changedLineIndices.last + 1;
    return changedLineIndices.length / totalLines;
  }
}

/// Adaptive polling interval calculation
///
/// Dynamically adjusts the polling interval according to content change frequency.
class AdaptivePollingInterval {
  /// Minimum polling interval (milliseconds)
  static const int minInterval = 50;

  /// Maximum polling interval (milliseconds) -- when idle
  static const int maxInterval = 2000;

  /// Default polling interval (milliseconds)
  static const int defaultInterval = 100;

  /// High-frequency update threshold (high-frequency mode when unchanged frames are at or below this count)
  static const int highFrequencyThreshold = 3;

  /// Low-frequency update threshold (low-frequency mode when unchanged frames are at or above this count)
  static const int lowFrequencyThreshold = 15;

  /// Calculate the current polling interval
  ///
  /// [unchangedFrames] Number of consecutive frames without changes
  /// [changeRatio] Recent change ratio
  static int calculateInterval(int unchangedFrames, double changeRatio) {
    // During high-frequency updates (htop, etc.)
    if (unchangedFrames <= highFrequencyThreshold || changeRatio > 0.3) {
      return minInterval;
    }

    // During low-frequency updates (idle state)
    if (unchangedFrames >= lowFrequencyThreshold) {
      return maxInterval;
    }

    // Intermediate state: linear interpolation
    final ratio = (unchangedFrames - highFrequencyThreshold) /
        (lowFrequencyThreshold - highFrequencyThreshold);
    return (minInterval + (maxInterval - minInterval) * ratio).round();
  }
}
