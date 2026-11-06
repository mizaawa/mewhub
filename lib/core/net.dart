import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../data/proxy_config.dart';
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
  static Map<String, String> providerProxies = {};
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
  static final Map<String, http.Client> _clients = {};

  static void reconfigure() {
    for (final client in _clients.values) {
      client.close();
    }
    _clients.clear();
    // Keep the default client eagerly created so callers can install a scoped
    // HttpOverrides before reconfiguration (used by tests and embedded hosts).
    _clientFor(null);
  }

  static String _proxyFor(String? providerId) =>
      (providerId == null ? null : NetConfig.providerProxies[providerId]) ?? NetConfig.proxy;

  static http.Client _clientFor(String? providerId) {
    final proxyUrl = _proxyFor(providerId).trim();
    return _clients.putIfAbsent(proxyUrl, () => _build(proxyUrl));
  }

  static http.Client _build(String proxyUrl) {
    final hc = HttpClient()
      ..connectionTimeout = NetConfig.connectTimeout
      ..idleTimeout = const Duration(seconds: 30);
    if (proxyUrl.isNotEmpty) {
      final endpoint = ProxyEndpoint.parse(proxyUrl);
      if (endpoint.protocol == ProxyProtocol.http) {
        hc.findProxy = (_) => 'PROXY ${endpoint.node}';
        if (endpoint.hasCredentials) {
          hc.authenticateProxy = (host, port, scheme, realm) async {
            if (host != endpoint.host || port != endpoint.port || scheme.toLowerCase() != 'basic') return false;
            hc.addProxyCredentials(
              host,
              port,
              realm ?? '',
              HttpClientBasicCredentials(endpoint.username, endpoint.password),
            );
            return true;
          };
        }
      } else {
        hc.findProxy = (_) => 'DIRECT';
        hc.connectionFactory = (uri, _, _) async {
          final socket = await Socket.connect(endpoint.host, endpoint.port, timeout: NetConfig.connectTimeout);
          try {
            final reader = _SocketReader(socket);
            await _socks5Connect(reader, socket, endpoint, uri.host, uri.port).timeout(NetConfig.connectTimeout);
            if (uri.scheme == 'https') {
              reader.pause();
              // SecureSocket.secure takes ownership of this socket while upgrading it to TLS.
              // ignore: close_sinks
              final secure = await SecureSocket.secure(socket, host: uri.host).timeout(NetConfig.connectTimeout);
              return ConnectionTask.fromSocket<Socket>(Future<Socket>.value(secure), socket.destroy);
            }
            final wrapped = _SocksSocket(socket, reader);
            reader.forwardTo(wrapped.incoming);
            return ConnectionTask.fromSocket<Socket>(Future<Socket>.value(wrapped), wrapped.destroy);
          } catch (_) {
            socket.destroy();
            rethrow;
          }
        };
      }
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
    String? providerId,
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
      final res = await _clientFor(providerId)
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
    bool log = true,
    String? providerId,
    Duration? timeout,
  }) {
    final req = http.AbortableRequest(method, url, abortTrigger: cancel?.future)..headers.addAll(_withUa(headers));
    if (body != null) req.bodyBytes = utf8.encode(body);
    return sendRequest(req, log: log, body: body ?? '', providerId: providerId, timeout: timeout);
  }

  /// Sends a raw binary body (uploads). Not logged.
  static Future<http.StreamedResponse> sendBytes(
    String method,
    Uri url,
    List<int> bytes, {
    Map<String, String> headers = const {},
    String? providerId,
  }) {
    final req = http.AbortableRequest(method, url)
      ..headers.addAll(_withUa(headers))
      ..bodyBytes = bytes;
    return sendRequest(req, log: false, providerId: providerId);
  }

  static Future<String> text(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
    String? body,
    CancelToken? cancel,
    Duration? timeout,
    bool log = true,
    String? providerId,
  }) async {
    final res = await send(
      method,
      url,
      headers: headers,
      body: body,
      cancel: cancel,
      log: log,
      providerId: providerId,
      timeout: timeout,
    );
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
    String? providerId,
  }) async {
    final s = await text(
      method,
      url,
      headers: {'Content-Type': 'application/json', ...headers},
      body: body == null ? null : (body is String ? body : jsonEncode(body)),
      cancel: cancel,
      timeout: timeout,
      log: log,
      providerId: providerId,
    );
    if (s.trim().isEmpty) return null;
    return jsonDecode(s);
  }

  static Future<({List<int> bytes, String? mime})> bytesWithType(
    Uri url, {
    Map<String, String> headers = const {},
    CancelToken? cancel,
    String? providerId,
  }) async {
    final res = await send('GET', url, headers: headers, cancel: cancel, log: false, providerId: providerId);
    final out = <int>[];
    await for (final c in res.stream) {
      out.addAll(c);
    }
    return (bytes: out, mime: res.headers['content-type']);
  }

  static Future<List<int>> bytes(Uri url, {Map<String, String> headers = const {}, CancelToken? cancel}) async =>
      (await bytesWithType(url, headers: headers, cancel: cancel)).bytes;

  /// Connects through a proxy and completes a tunnel to measure its latency.
  static Future<Duration> probeProxy(String proxyUrl, {Duration timeout = const Duration(seconds: 8)}) async {
    final endpoint = ProxyEndpoint.parse(proxyUrl);
    final sw = Stopwatch()..start();
    final socket = await Socket.connect(endpoint.host, endpoint.port, timeout: timeout);
    try {
      if (endpoint.protocol == ProxyProtocol.socks5) {
        final reader = _SocketReader(socket);
        await _socks5Connect(reader, socket, endpoint, 'example.com', 443).timeout(timeout);
        await reader.dispose();
      } else {
        final auth = endpoint.hasCredentials
            ? 'Proxy-Authorization: Basic ${base64Encode(utf8.encode('${endpoint.username}:${endpoint.password}'))}\r\n'
            : '';
        socket.write('CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n$auth\r\n');
        await socket.flush();
        final status = await socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(timeout);
        if (!RegExp(r'^HTTP/\d(?:\.\d)? 200(?: |$)').hasMatch(status)) {
          throw SocketException('Proxy tunnel rejected: $status');
        }
      }
      return sw.elapsed;
    } finally {
      socket.destroy();
    }
  }

  static Future<void> _socks5Connect(
    _SocketReader reader,
    Socket socket,
    ProxyEndpoint endpoint,
    String targetHost,
    int targetPort,
  ) async {
    final methods = endpoint.hasCredentials ? const [0, 2] : const [0];
    socket.add([5, methods.length, ...methods]);
    await socket.flush();
    final version = await reader.readByte();
    final method = await reader.readByte();
    if (version != 5 || method == 0xff) throw const SocketException('SOCKS5 authentication method rejected');
    if (method == 2) {
      final user = utf8.encode(endpoint.username);
      final password = utf8.encode(endpoint.password);
      if (user.isEmpty || user.length > 255 || password.length > 255) {
        throw const SocketException('Invalid SOCKS5 username or password');
      }
      socket.add([1, user.length, ...user, password.length, ...password]);
      await socket.flush();
      if (await reader.readByte() != 1 || await reader.readByte() != 0) {
        throw const SocketException('SOCKS5 authentication failed');
      }
    } else if (method != 0) {
      throw const SocketException('SOCKS5 server selected an unsupported authentication method');
    }

    final address = InternetAddress.tryParse(targetHost);
    final List<int> addressBytes;
    final int addressType;
    if (address != null && address.type == InternetAddressType.IPv4) {
      addressBytes = address.rawAddress;
      addressType = 1;
    } else if (address != null && address.type == InternetAddressType.IPv6) {
      addressBytes = address.rawAddress;
      addressType = 4;
    } else {
      addressBytes = utf8.encode(targetHost);
      if (addressBytes.isEmpty || addressBytes.length > 255) throw const SocketException('Invalid SOCKS5 destination');
      addressType = 3;
    }
    socket.add([
      5,
      1,
      0,
      addressType,
      if (addressType == 3) addressBytes.length,
      ...addressBytes,
      targetPort >> 8,
      targetPort & 0xff,
    ]);
    await socket.flush();
    final response = await reader.readBytes(4);
    if (response[0] != 5 || response[1] != 0) throw SocketException('SOCKS5 connection failed (${response[1]})');
    final boundLength = switch (response[3]) {
      1 => 4,
      4 => 16,
      3 => await reader.readByte(),
      _ => throw const SocketException('Invalid SOCKS5 response address'),
    };
    await reader.readBytes(boundLength + 2);
  }
}

class _SocketReader {
  _SocketReader(this.socket) {
    _subscription = socket.listen(
      (data) {
        if (_forwarding) {
          _output?.add(data);
        } else {
          _pending.addAll(data);
          _wake?.complete();
          _wake = null;
        }
      },
      onError: (Object error, StackTrace stack) {
        _error = error;
        _output?.addError(error, stack);
        _wake?.complete();
        _wake = null;
      },
      onDone: () {
        _closed = true;
        _output?.close();
        _wake?.complete();
        _wake = null;
      },
    );
  }

  final Socket socket;
  final List<int> _pending = [];
  late final StreamSubscription<Uint8List> _subscription;
  Completer<void>? _wake;
  StreamController<Uint8List>? _output;
  Object? _error;
  bool _closed = false;
  bool _forwarding = false;

  Future<int> readByte() async {
    while (_pending.isEmpty) {
      if (_error != null) throw _error!;
      if (_closed) throw const SocketException('SOCKS5 proxy closed the connection');
      final wake = _wake = Completer<void>();
      await wake.future;
    }
    return _pending.removeAt(0);
  }

  Future<List<int>> readBytes(int count) async => [for (var i = 0; i < count; i++) await readByte()];

  void pause() => _subscription.pause();

  void forwardTo(StreamController<Uint8List> output) {
    _output = output;
    _forwarding = true;
    if (_pending.isNotEmpty) {
      output.add(Uint8List.fromList(_pending));
      _pending.clear();
    }
    if (_closed) output.close();
  }

  Future<void> dispose() => _subscription.cancel();
}

class _SocksSocket extends Stream<Uint8List> implements Socket {
  _SocksSocket(this._socket, this._reader) : incoming = StreamController<Uint8List>(sync: true);

  final Socket _socket;
  final _SocketReader _reader;
  final StreamController<Uint8List> incoming;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => incoming.stream.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);
  @override
  Encoding get encoding => _socket.encoding;
  @override
  set encoding(Encoding value) => _socket.encoding = value;
  @override
  void add(List<int> data) => _socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _socket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);
  @override
  Future<void> close() => _socket.close();
  @override
  Future<void> get done => _socket.done;
  @override
  Future<void> flush() => _socket.flush();
  @override
  void write(Object? object) => _socket.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) => _socket.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
  @override
  void destroy() {
    incoming.close();
    _socket.destroy();
    _reader.dispose();
  }

  @override
  bool setOption(SocketOption option, bool enabled) => _socket.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _socket.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
  @override
  int get port => _socket.port;
  @override
  int get remotePort => _socket.remotePort;
  @override
  InternetAddress get address => _socket.address;
  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
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
