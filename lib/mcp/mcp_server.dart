import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'mcp_tools.dart';

/// The MCP endpoint: Streamable HTTP on 127.0.0.1, answering in JSON.
///
/// Nothing on the network can reach it, because it listens on the loopback
/// address alone and refuses any connection that is not from it. What runs on
/// this computer needs a client's bearer token. A web page that rebinds a
/// name to 127.0.0.1 is refused on its Host, a page that posts here directly
/// is refused on its Origin and never passes a preflight, and no response
/// carries a CORS header.
///
/// It keeps no sessions: every request carries its token and is checked on
/// its own, so a revoked client is refused on its very next request, and a
/// client reconnects across app restarts without noticing.
class McpServer {
  McpServer({
    required this.tools,
    required this.authenticate,
    required this.writes,
    required this.onCall,
    this.version = '1.0.0',
  });

  final McpTools tools;

  /// The client a bearer token belongs to, or null for no client.
  final String? Function(String token) authenticate;

  /// Whether the person allows changes right now.
  final bool Function() writes;

  /// Every request a client got through with; [activity] is set for a tool
  /// call, with [refused] when the call came back as an error.
  final void Function(
    String client, {
    String? activity,
    bool refused,
    McpUndo? undo,
  })
  onCall;

  final String version;

  static const String path = '/mcp';
  static const int maxBody = 1 << 20;
  static const int maxOpen = 16;
  static const int callsPerMinute = 120;
  static const int writesPerMinute = 30;
  static const Duration readTimeout = Duration(seconds: 10);
  static const List<String> protocolVersions = [
    '2025-11-25',
    '2025-06-18',
    '2025-03-26',
  ];

  static const String _instructions =
      'Kapy Notes is the person’s notes app. list_notes and read_note find '
      'what they wrote; list_tasks reads their checklists; list_folders reads '
      'their folders. Hidden notes are never available. The write tools appear '
      'only while the person allows changes. Folders are theirs alone and '
      'never enter a shared space, and nothing of a note can be deleted.';

  HttpServer? _http;
  int? _port;
  int _open = 0;
  final Map<String, List<DateTime>> _calls = {};
  final Map<String, List<DateTime>> _writes = {};
  DateTime Function() now = DateTime.now;

  /// The port it listens on, while it does.
  int? get port => _port;

  /// Listens on [port] of 127.0.0.1. Throws a [SocketException] when the
  /// port is taken.
  Future<void> start(int port) async {
    await stop();
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    http
      ..idleTimeout = const Duration(seconds: 5)
      ..autoCompress = false
      ..serverHeader = null;
    _http = http;
    _port = http.port;
    http.listen((request) => unawaited(_serve(request)));
  }

  /// Stops listening and drops every connection at once.
  Future<void> stop() async {
    final http = _http;
    _http = null;
    _port = null;
    await http?.close(force: true);
  }

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    response.headers
      ..set(HttpHeaders.cacheControlHeader, 'no-store')
      ..set('X-Content-Type-Options', 'nosniff');
    if (_open >= maxOpen) {
      return _status(response, HttpStatus.serviceUnavailable);
    }
    _open++;
    try {
      await _handle(request, response);
    } catch (_) {
      // The details stay here: a stack trace can carry note text.
      try {
        await _status(response, HttpStatus.internalServerError);
      } catch (_) {}
    } finally {
      _open--;
    }
  }

  Future<void> _handle(HttpRequest request, HttpResponse response) async {
    final port = _port;
    final remote = request.connectionInfo?.remoteAddress;
    if (port == null || remote == null || !remote.isLoopback) {
      return _status(response, HttpStatus.forbidden);
    }
    final host = request.headers.value(HttpHeaders.hostHeader);
    if (host != '127.0.0.1:$port' && host != 'localhost:$port') {
      return _status(response, HttpStatus.forbidden);
    }
    final origin = request.headers.value('origin');
    if (origin != null &&
        origin != 'http://127.0.0.1:$port' &&
        origin != 'http://localhost:$port') {
      return _status(response, HttpStatus.forbidden);
    }
    if (request.uri.path != path) {
      return _status(response, HttpStatus.notFound);
    }
    switch (request.method) {
      case 'POST':
        break;
      case 'OPTIONS':
        return _status(response, HttpStatus.forbidden);
      default:
        response.headers.set(HttpHeaders.allowHeader, 'POST');
        return _status(response, HttpStatus.methodNotAllowed);
    }

    final authorization = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    final client = authorization != null && authorization.startsWith('Bearer ')
        ? authenticate(authorization.substring(7).trim())
        : null;
    if (client == null) return _status(response, HttpStatus.unauthorized);

    final protocol = request.headers.value('mcp-protocol-version');
    if (protocol != null && !protocolVersions.contains(protocol)) {
      return _status(response, HttpStatus.badRequest);
    }
    if (request.headers.contentType?.mimeType != 'application/json') {
      return _status(response, HttpStatus.unsupportedMediaType);
    }
    if (request.contentLength > maxBody) {
      return _status(response, HttpStatus.requestEntityTooLarge);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in request.timeout(readTimeout)) {
      if (bytes.length + chunk.length > maxBody) {
        return _status(response, HttpStatus.requestEntityTooLarge);
      }
      bytes.add(chunk);
    }
    if (!_take(_calls, client, callsPerMinute)) {
      return _json(response, _error(null, -32000, _slowDown), status: 429);
    }

    final Object? message;
    try {
      message = jsonDecode(utf8.decode(bytes.takeBytes()));
    } on FormatException {
      return _json(
        response,
        _error(null, -32700, 'That isn’t JSON.'),
        status: 400,
      );
    }
    if (message is! Map<String, Object?> || message['jsonrpc'] != '2.0') {
      return _json(
        response,
        _error(null, -32600, 'Send one JSON-RPC 2.0 message per request.'),
        status: 400,
      );
    }
    final id = message['id'];
    final method = message['method'];
    if (method is! String) {
      // A response or a notification has nothing to answer.
      return _status(response, HttpStatus.accepted);
    }
    final params = message['params'] is Map<String, Object?>
        ? message['params'] as Map<String, Object?>
        : const <String, Object?>{};
    if (!message.containsKey('id')) {
      onCall(client);
      return _status(response, HttpStatus.accepted);
    }

    switch (method) {
      case 'initialize':
        final asked = params['protocolVersion'];
        onCall(client);
        return _json(
          response,
          _result(id, {
            'protocolVersion': protocolVersions.contains(asked)
                ? asked
                : protocolVersions.first,
            'capabilities': {
              'tools': {'listChanged': false},
            },
            'serverInfo': {
              'name': 'kapy-notes',
              'title': 'Kapy Notes',
              'version': version,
            },
            'instructions': _instructions,
          }),
        );
      case 'ping':
        return _json(response, _result(id, const <String, Object?>{}));
      case 'tools/list':
        onCall(client);
        return _json(
          response,
          _result(id, {'tools': tools.definitions(writes: writes())}),
        );
      case 'tools/call':
        final name = params['name'];
        final args = params['arguments'] ?? const <String, Object?>{};
        if (name is! String || args is! Map<String, Object?>) {
          return _json(
            response,
            _error(
              id,
              -32602,
              'tools/call needs a name and an arguments object.',
            ),
          );
        }
        if (McpTools.writeTools.contains(name) &&
            !_take(_writes, client, writesPerMinute)) {
          return _json(response, _error(id, -32000, _slowDown), status: 429);
        }
        final result = tools.call(name, args, writes: writes());
        onCall(
          client,
          activity: result.activity,
          refused: result.error != null,
          undo: result.undo,
        );
        final output = result.output;
        return _json(
          response,
          _result(
            id,
            output == null
                ? {
                    'content': [
                      {'type': 'text', 'text': result.error},
                    ],
                    'isError': true,
                  }
                : {
                    'content': [
                      {'type': 'text', 'text': jsonEncode(output)},
                    ],
                    'structuredContent': output,
                  },
          ),
        );
      default:
        return _json(
          response,
          _error(id, -32601, 'Kapy Notes has no $method.'),
        );
    }
  }

  static const String _slowDown =
      'Too many requests. Kapy Notes takes a short breath; try again in a minute.';

  /// Counts one more call in [client]'s last minute, unless that would pass
  /// [limit].
  bool _take(Map<String, List<DateTime>> windows, String client, int limit) {
    final at = now();
    final window = windows.putIfAbsent(client, () => [])
      ..removeWhere((t) => at.difference(t) >= const Duration(minutes: 1));
    if (window.length >= limit) return false;
    window.add(at);
    return true;
  }

  static Map<String, Object?> _result(Object? id, Object? result) => {
    'jsonrpc': '2.0',
    'id': id,
    'result': result,
  };

  static Map<String, Object?> _error(Object? id, int code, String message) => {
    'jsonrpc': '2.0',
    'id': id,
    'error': {'code': code, 'message': message},
  };

  static Future<void> _json(
    HttpResponse response,
    Map<String, Object?> body, {
    int status = HttpStatus.ok,
  }) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await response.close();
  }

  static Future<void> _status(HttpResponse response, int status) async {
    response
      ..statusCode = status
      ..persistentConnection = status < 400;
    await response.close();
  }
}
