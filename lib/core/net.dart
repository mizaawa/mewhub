import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'log.dart';

class ApiException implements Exception {
  ApiException(this.message, {this.status, this.body, this.cause, this.retryAfter});
  final String message;
  final int? status;
  final String? body;
  final Object? cause;
  final Duration? retryAfter;

  @override
  String toString() => status != null ? 'HTTP $status: $message' : message;
}

/// Cancels an in-flight request through package:http's `abortTrigger`.
class CancelToken {
  final _c = Completer<void>();
  bool get isCancelled => _c.isCompleted;
  Future<void> get future => _c.future;
  void cancel() {
    if (!_c.isCompleted) _c.complete();
  }
}

class NetConfig {
  static String userAgent = '';
  static String proxy = '';
  static Duration connectTimeout = const Duration(seconds: 30);
  static Duration responseTimeout = const Duration(seconds: 120);
}

/// Keeps streamed request bodies intact while combining caller cancellation
/// with the response timeout's abort signal.
class _AbortableRequest extends http.BaseRequest with http.Abortable {
  _AbortableRequest(this.original, this.abortTrigger) : super(original.method, original.url) {
    headers.addAll(original.headers);
    contentLength = original.contentLength;
    followRedirects = original.followRedirects;
    maxRedirects = original.maxRedirects;
    persistentConnection = original.persistentConnection;
  }

  final http.BaseRequest original;
  @override
  final Future<void>? abortTrigger;
  @override
  http.ByteStream finalize() {
    super.finalize();
    final body = original.finalize();
    headers.addAll(original.headers);
    return body;
  }
}

class Net {
  static http.Client _client = _build();

  static void reconfigure() {
    _client.close();
    _client = _build();
  }

  static http.Client _build() {
    final hc = HttpClient()
      ..connectionTimeout = NetConfig.connectTimeout
      ..idleTimeout = const Duration(seconds: 30);
    final proxy = NetConfig.proxy.trim();
    if (proxy.isNotEmpty) {
      final hostPort = proxy.replaceFirst(RegExp(r'^https?://'), '');
      hc.findProxy = (_) => 'PROXY $hostPort';
    }
    return IOClient(hc);
  }

  static Map<String, String> _withUa(Map<String, String> h) {
    if (NetConfig.userAgent.isNotEmpty && !h.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      return {...h, 'User-Agent': NetConfig.userAgent};
    }
    return h;
  }

  static Future<http.StreamedResponse> sendRequest(
    http.BaseRequest req, {
    bool log = true,
    String body = '',
    Duration? timeout,
  }) async {
    final start = DateTime.now();
    final entry = log ? AppLog.begin(req.method, req.url, req.headers, body) : null;
    final limit = timeout ?? NetConfig.responseTimeout;
    final abort = CancelToken();
    final callerAbort = req is http.Abortable ? req.abortTrigger : null;
    final request = _AbortableRequest(
      req,
      callerAbort == null ? abort.future : Future.any([callerAbort, abort.future]),
    );
    try {
      final res = await _client
          .send(request)
          .timeout(
            limit,
            onTimeout: () {
              abort.cancel();
              throw TimeoutException('Timed out waiting for response headers', limit);
            },
          );
      // Reset the timeout whenever a chunk arrives so long responses can stream.
      final stream = res.stream.timeout(
        limit,
        onTimeout: (sink) {
          sink.addError(TimeoutException('Timed out waiting for response data', limit));
          abort.cancel();
          sink.close();
        },
      );
      entry?.status = res.statusCode;
      if (res.statusCode < 200 || res.statusCode >= 300) {
        var text = '';
        try {
          text = await http.ByteStream(stream).bytesToString();
        } on http.RequestAbortedException {
          rethrow;
        } catch (_) {
          // Preserve a known HTTP status even when its error body stalls or
          // breaks. In particular, a 401 must not become a retryable timeout.
          abort.cancel();
        }
        if (entry != null) {
          AppLog.appendResponse(entry, text);
          AppLog.end(entry, status: res.statusCode, error: 'HTTP ${res.statusCode}', start: start);
        }
        throw ApiException(
          extractErrorMessage(text, res.reasonPhrase),
          status: res.statusCode,
          body: text,
          retryAfter: parseRetryAfter(res.headers['retry-after']),
        );
      }
      final tee = entry == null
          ? stream
          : stream.transform(
              StreamTransformer<List<int>, List<int>>.fromHandlers(
                handleData: (d, sink) {
                  AppLog.appendResponse(entry, utf8.decode(d, allowMalformed: true));
                  sink.add(d);
                },
                handleError: (e, st, sink) {
                  AppLog.end(entry, error: e.toString(), start: start);
                  sink.addError(e, st);
                },
                handleDone: (sink) {
                  AppLog.end(entry, start: start);
                  sink.close();
                },
              ),
            );
      return http.StreamedResponse(
        tee,
        res.statusCode,
        headers: res.headers,
        reasonPhrase: res.reasonPhrase,
        request: res.request,
        contentLength: res.contentLength,
        isRedirect: res.isRedirect,
        persistentConnection: res.persistentConnection,
      );
    } on http.RequestAbortedException {
      if (entry != null) AppLog.end(entry, error: 'cancelled', start: start);
      rethrow;
    } on ApiException {
      rethrow;
    } catch (e) {
      if (entry != null) AppLog.end(entry, error: e.toString(), start: start);
      throw ApiException(e.toString(), cause: e);
    }
  }

  /// Sends a request and returns the streamed response. Throws [ApiException] for non-2xx.
  static Future<http.StreamedResponse> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
    CancelToken? cancel,
    Duration? timeout,
    bool log = true,
  }) {
    final req = http.AbortableRequest(method, url, abortTrigger: cancel?.future)..headers.addAll(_withUa(headers));
    if (body != null) req.bodyBytes = utf8.encode(body);
    return sendRequest(req, log: log, body: body ?? '', timeout: timeout);
  }

  /// Sends a raw binary body (uploads). Not logged.
  static Future<http.StreamedResponse> sendBytes(
    String method,
    Uri url,
    List<int> bytes, {
    Map<String, String> headers = const {},
  }) {
    final req = http.AbortableRequest(method, url)
      ..headers.addAll(_withUa(headers))
      ..bodyBytes = bytes;
    return sendRequest(req, log: false);
  }

  static Future<String> text(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
    CancelToken? cancel,
    Duration? timeout,
    bool log = true,
  }) async {
    final res = await send(method, url, headers: headers, body: body, cancel: cancel, log: log, timeout: timeout);
    return res.stream.bytesToString();
  }

  static Future<dynamic> json(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    Object? body,
    CancelToken? cancel,
    Duration? timeout,
    bool log = true,
  }) async {
    final s = await text(
      method,
      url,
      headers: {'Content-Type': 'application/json', ...headers},
      body: body == null ? null : (body is String ? body : jsonEncode(body)),
      cancel: cancel,
      timeout: timeout,
      log: log,
    );
    if (s.trim().isEmpty) return null;
    return jsonDecode(s);
  }

  static Future<({List<int> bytes, String? mime})> bytesWithType(
    Uri url, {
    Map<String, String> headers = const {},
    CancelToken? cancel,
  }) async {
    final res = await send('GET', url, headers: headers, cancel: cancel, log: false);
    final out = <int>[];
    await for (final c in res.stream) {
      out.addAll(c);
    }
    return (bytes: out, mime: res.headers['content-type']);
  }

  static Future<List<int>> bytes(Uri url, {Map<String, String> headers = const {}, CancelToken? cancel}) async =>
      (await bytesWithType(url, headers: headers, cancel: cancel)).bytes;
}

Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null || value.trim().isEmpty) return null;
  final seconds = int.tryParse(value.trim());
  if (seconds != null) return seconds < 0 ? Duration.zero : Duration(seconds: seconds);
  try {
    final date = HttpDate.parse(value);
    final delay = date.difference(now ?? DateTime.now().toUtc());
    return delay.isNegative ? Duration.zero : delay;
  } on FormatException {
    return null;
  } on HttpException {
    return null;
  }
}

String extractErrorMessage(String body, String? fallback) {
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final e = j['error'];
      if (e is Map && e['message'] != null) return e['message'].toString();
      if (e is String) return e;
      if (j['message'] != null) return j['message'].toString();
      if (j['detail'] != null) return j['detail'].toString();
    }
    if (j is List && j.isNotEmpty && j.first is Map) {
      final e = (j.first as Map)['error'];
      if (e is Map && e['message'] != null) return e['message'].toString();
    }
  } catch (_) {}
  final trimmed = body.trim();
  if (trimmed.isEmpty) return fallback ?? 'Request failed';
  return trimmed.length > 500 ? '${trimmed.substring(0, 500)}...' : trimmed;
}
