import 'package:flutter/foundation.dart';

class RequestLog {
  RequestLog({
    required this.time,
    required this.method,
    required this.url,
    required this.requestHeaders,
    required this.requestBody,
  });

  final DateTime time;
  final String method;
  final String url;
  final Map<String, String> requestHeaders;
  final String requestBody;
  int? status;
  String responseBody = '';
  String? error;
  Duration? duration;
}

/// In-memory ring buffer of recent API requests, shown on the request log page.
/// Secrets in headers are masked before storage.
class AppLog {
  static final ValueNotifier<int> revision = ValueNotifier(0);
  static final List<RequestLog> requests = [];
  static const _max = 60;
  static const _bodyCap = 64 * 1024;

  static RequestLog begin(String method, Uri url, Map<String, String> headers, String body) {
    final log = RequestLog(
      time: DateTime.now(),
      method: method,
      url: _maskUrl(url),
      requestHeaders: {for (final e in headers.entries) e.key: _maskHeader(e.key, e.value)},
      requestBody: _cap(body),
    );
    requests.insert(0, log);
    if (requests.length > _max) requests.removeLast();
    revision.value++;
    return log;
  }

  static void appendResponse(RequestLog log, String chunk) {
    if (log.responseBody.length < _bodyCap) {
      log.responseBody += chunk;
      if (log.responseBody.length > _bodyCap) log.responseBody = _cap(log.responseBody);
    }
  }

  static void end(RequestLog log, {int? status, String? error, required DateTime start}) {
    log.status = status ?? log.status;
    log.error = error;
    log.duration = DateTime.now().difference(start);
    revision.value++;
  }

  static void clear() {
    requests.clear();
    revision.value++;
  }

  static String _cap(String s) => s.length > _bodyCap ? '${s.substring(0, _bodyCap)}\n…(truncated)' : s;

  static String _maskHeader(String k, String v) {
    final lk = k.toLowerCase();
    if (lk == 'authorization' || lk.contains('key') || lk.contains('token') || lk.contains('secret')) {
      return _mask(v);
    }
    return v;
  }

  static String _maskUrl(Uri u) {
    if (!u.queryParameters.containsKey('key')) return u.toString();
    final q = Map<String, String>.from(u.queryParameters)..['key'] = '***';
    return u.replace(queryParameters: q).toString();
  }

  static String _mask(String v) {
    if (v.length <= 12) return '***';
    return '${v.substring(0, 7)}***${v.substring(v.length - 4)}';
  }
}
