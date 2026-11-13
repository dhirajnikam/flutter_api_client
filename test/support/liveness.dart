/// Fails loudly if [f] does not settle within [d], instead of hanging the run.
Future<R> within<R>(Future<R> f, {Duration d = const Duration(seconds: 4)}) => f
    .timeout(d, onTimeout: () => throw StateError('deadlock / liveness fault'));
