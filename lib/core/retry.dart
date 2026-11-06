import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../data/network_settings.dart';
import 'net.dart';

bool isRetryableNetworkError(Object error, NetworkSettings settings) {
  if (error is http.RequestAbortedException) return false;
  if (error is ApiException) {
    final status = error.status;
    if (status != null) {
      return status == 408 ||
          (status == 429 && settings.retryOnRateLimit) ||
          (status >= 500 && status < 600 && settings.retryOnServerError);
    }
    return error.cause != null && isRetryableNetworkError(error.cause!, settings);
  }
  return error is SocketException ||
      error is HttpException ||
      error is TimeoutException ||
      error is http.ClientException;
}

/// Null means the server asks us to wait beyond the user's limit. Surface the
/// error in that case instead of retrying earlier than Retry-After allows.
Duration? retryDelay(NetworkSettings settings, int attempt, {Duration? retryAfter}) {
  final factor = settings.exponentialBackoff ? 1 << attempt.clamp(0, 20) : 1;
  var seconds = (settings.retryDelaySeconds * factor).clamp(1, settings.maxRetryDelaySeconds);
  if (settings.respectRetryAfter && retryAfter != null) {
    if (retryAfter > Duration(seconds: settings.maxRetryDelaySeconds)) return null;
    final serverSeconds = (retryAfter.inMilliseconds / 1000).ceil();
    if (serverSeconds > seconds) seconds = serverSeconds;
  }
  return Duration(seconds: seconds);
}

/// Retries only before the first event: replaying partial text, reasoning or
/// tool calls could duplicate visible content or repeat a tool invocation.
Stream<T> retryStream<T>(
  Stream<T> Function() start, {
  required CancelToken cancel,
  required NetworkSettings settings,
  bool enabled = true,
}) async* {
  final retries = enabled ? settings.maxRetries : 0;
  for (var attempt = 0; ; attempt++) {
    if (cancel.isCancelled) throw http.RequestAbortedException();
    var received = false;
    try {
      await for (final event in start()) {
        if (cancel.isCancelled) throw http.RequestAbortedException();
        received = true;
        yield event;
      }
      return;
    } catch (error) {
      if (cancel.isCancelled) throw http.RequestAbortedException();
      if (received || attempt >= retries || !isRetryableNetworkError(error, settings)) rethrow;
      final delay = retryDelay(settings, attempt, retryAfter: error is ApiException ? error.retryAfter : null);
      if (delay == null) rethrow;
      await _wait(delay, cancel);
    }
  }
}

Future<void> _wait(Duration delay, CancelToken cancel) async {
  if (cancel.isCancelled) throw http.RequestAbortedException();
  final done = Completer<void>();
  final timer = Timer(delay, done.complete);
  unawaited(
    cancel.future.then((_) {
      if (!done.isCompleted) done.complete();
    }),
  );
  try {
    await done.future;
  } finally {
    timer.cancel();
  }
  if (cancel.isCancelled) throw http.RequestAbortedException();
}
