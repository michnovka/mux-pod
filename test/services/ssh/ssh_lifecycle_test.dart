import 'dart:async';

import 'package:flutter_muxpod/services/ssh/ssh_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AsyncCleanupCoordinator', () {
    test('coalesces overlapping cleanup calls into one run', () async {
      final coordinator = AsyncCleanupCoordinator();
      final completer = Completer<void>();
      var cleanupRuns = 0;

      final first = coordinator.run(() async {
        cleanupRuns++;
        await completer.future;
      });
      final second = coordinator.run(() async {
        cleanupRuns++;
      });

      expect(identical(first, second), isTrue);
      expect(cleanupRuns, 1);

      completer.complete();
      await Future.wait([first, second]);

      expect(cleanupRuns, 1);
    });

    test('allows a new cleanup run after the previous one completes', () async {
      final coordinator = AsyncCleanupCoordinator();
      var cleanupRuns = 0;

      await coordinator.run(() async {
        cleanupRuns++;
      });
      await coordinator.run(() async {
        cleanupRuns++;
      });

      expect(cleanupRuns, 2);
    });
  });

  group('startOptionalAsyncResource', () {
    test('returns the resource when startup succeeds', () async {
      final resource = _FakeAsyncResource();

      final started = await startOptionalAsyncResource(
        create: () => resource,
        start: (resource) => resource.start(),
        disposeOnFailure: (resource) => resource.dispose(),
      );

      expect(started, same(resource));
      expect(resource.startCalls, 1);
      expect(resource.disposeCalls, 0);
    });

    test('disposes and drops the resource when startup fails', () async {
      final resource = _FakeAsyncResource(startError: StateError('boom'));

      final started = await startOptionalAsyncResource(
        create: () => resource,
        start: (resource) => resource.start(),
        disposeOnFailure: (resource) => resource.dispose(),
      );

      expect(started, isNull);
      expect(resource.startCalls, 1);
      expect(resource.disposeCalls, 1);
    });
  });
}

class _FakeAsyncResource {
  _FakeAsyncResource({this.startError});

  final Object? startError;
  int startCalls = 0;
  int disposeCalls = 0;

  Future<void> start() async {
    startCalls++;
    if (startError != null) {
      throw startError!;
    }
  }

  Future<void> dispose() async {
    disposeCalls++;
  }
}
