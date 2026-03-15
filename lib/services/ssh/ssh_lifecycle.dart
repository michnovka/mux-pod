import 'dart:async';

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
  } catch (_) {
    try {
      await disposeOnFailure(resource);
    } catch (_) {
      // Ignore disposal races after failed startup.
    }
    return null;
  }
}
