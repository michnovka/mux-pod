import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

/// Tests for the future-chain + generation-counter serialization pattern
/// used in TerminalScreen to deliver keystrokes in order.
///
/// These tests exercise the pattern in isolation — they do not require
/// a widget harness.
void main() {
  group('Future-chain serializer', () {
    test('executes sends in FIFO order', () async {
      final order = <int>[];
      var chain = Future<void>.value();

      for (var i = 0; i < 10; i++) {
        final index = i;
        chain = chain.then((_) async {
          // Simulate variable async work.
          await Future<void>.delayed(Duration(milliseconds: 5 - index % 3));
          order.add(index);
        }).catchError((_) {});
      }

      await chain;
      expect(order, List.generate(10, (i) => i));
    });

    test('error in one link does not block subsequent links', () async {
      final order = <int>[];
      var chain = Future<void>.value();

      for (var i = 0; i < 5; i++) {
        final index = i;
        chain = chain.then((_) async {
          if (index == 2) throw Exception('boom');
          order.add(index);
        }).catchError((_) {});
      }

      await chain;
      // Link 2 threw, so it's missing. Others executed.
      expect(order, [0, 1, 3, 4]);
    });

    test('generation counter skips stale links', () async {
      final executed = <String>[];
      var chain = Future<void>.value();
      var generation = 0;

      // Enqueue A and B at gen=0.
      for (final label in ['A', 'B']) {
        final gen = generation;
        chain = chain.then((_) async {
          if (generation != gen) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          executed.add(label);
        }).catchError((_) {});
      }

      // Bump generation (simulates pane switch).
      generation++;

      // Enqueue C at gen=1.
      final gen = generation;
      chain = chain.then((_) async {
        if (generation != gen) return;
        executed.add('C');
      }).catchError((_) {});

      await chain;
      // A and B should be skipped, only C executes.
      expect(executed, ['C']);
    });

    test('switch-boundary: in-flight send completes, queued sends skipped',
        () async {
      final executed = <String>[];
      var chain = Future<void>.value();
      var generation = 0;

      // Use a completer to hold the first send in-flight.
      final inFlightCompleter = Completer<void>();

      // Enqueue "inflight" at gen=0 — held by completer.
      final gen0 = generation;
      chain = chain.then((_) async {
        if (generation != gen0) return;
        await inFlightCompleter.future;
        executed.add('inflight');
      }).catchError((_) {});

      // Yield to let the microtask scheduler run the inflight callback
      // so it enters the await (past the generation check).
      await Future<void>.value();

      // Enqueue "queued" at gen=0 — waiting behind "inflight".
      chain = chain.then((_) async {
        if (generation != gen0) return;
        executed.add('queued');
      }).catchError((_) {});

      // Simulate pane switch: bump generation, then drain the chain.
      generation++;
      // Release the in-flight send so the drain completes.
      inFlightCompleter.complete();
      await chain;

      // "inflight" started before the bump — its generation check passed
      // before we incremented, so it completes.
      // "queued" hadn't started yet — its generation check fails, skipped.
      expect(executed, ['inflight']);

      // Now enqueue a post-switch send at gen=1.
      final gen1 = generation;
      chain = chain.then((_) async {
        if (generation != gen1) return;
        executed.add('post-switch');
      }).catchError((_) {});

      await chain;
      expect(executed, ['inflight', 'post-switch']);
    });
  });
}
