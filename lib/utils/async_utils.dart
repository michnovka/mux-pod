import 'dart:async';
import 'dart:developer' as developer;

/// Fire-and-forget a future, logging any errors to the developer console.
void fireAndForget(Future<void> future, {String? debugLabel}) {
  unawaited(
    future.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      developer.log(
        'Unhandled async error${debugLabel != null ? ' ($debugLabel)' : ''}',
        name: 'fireAndForget',
        error: error,
        stackTrace: stack,
      );
    }),
  );
}
