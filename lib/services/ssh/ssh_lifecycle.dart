import 'dart:async';

import 'package:flutter/foundation.dart';

/// Runs async cleanup at most once at a time.
class AsyncCleanupCoordinator {
  Future<void>? _pendingCleanup;

  Future<void> run(Future<void> Function() action) {
    final pendingCleanup = _pendingCleanup;
    if (pendingCleanup != null) {
      return pendingCleanup;
    }

    late final Future<void> trackedCleanup;
    trackedCleanup = Future<void>.sync(action).whenComplete(() {
      if (identical(_pendingCleanup, trackedCleanup)) {
        _pendingCleanup = null;
      }
    });
    _pendingCleanup = trackedCleanup;
    return trackedCleanup;
  }
}

/// Starts an optional async resource and disposes it if startup fails.
Future<T?> startOptionalAsyncResource<T>({
  required FutureOr<T> Function() create,
  required Future<void> Function(T resource) start,
  required Future<void> Function(T resource) disposeOnFailure,
}) async {
  final resource = await Future<T>.sync(create);
  try {
    await start(resource);
    return resource;
  } catch (e) {
    if (kDebugMode) {
      debugPrint('[startOptionalAsyncResource] startup failed: $e');
    }
    try {
      await disposeOnFailure(resource);
    } catch (e) {
      assert(() { debugPrint('startOptionalAsyncResource dispose after failure: $e'); return true; }());
    }
    return null;
  }
}
