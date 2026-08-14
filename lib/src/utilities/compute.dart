import 'dart:async';

import 'package:flutter/foundation.dart' as foundation;

/// Runs [callback] on the current isolate rather than spawning one.
Future<R> _inlineCompute<Q, R>(
  foundation.ComputeCallback<Q, R> callback,
  Q message, {
  String? debugLabel,
}) {
  final FutureOr<R> result = callback(message);
  return result is Future<R> ? result : foundation.SynchronousFuture<R>(result);
}

/// Runs work off the main isolate where that is worth doing.
///
/// Falls back to running inline on the web, which has no isolates, and in debug
/// builds, where spawning one for every picture costs more than it saves and
/// where widget tests expect loading to settle without pumping timers.
const foundation.ComputeImpl compute = (foundation.kDebugMode || foundation.kIsWeb)
    ? _inlineCompute
    : foundation.compute;
