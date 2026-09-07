import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// What a socket tells the service: it came up, it went down, or the server
/// said something.
enum SocketEventKind { connected, disconnected, message }

class SocketEvent {
  const SocketEvent.connected() : kind = SocketEventKind.connected, message = null;
  const SocketEvent.disconnected()
    : kind = SocketEventKind.disconnected,
      message = null;
  const SocketEvent.message(Map<String, Object?> this.message)
    : kind = SocketEventKind.message;

  final SocketEventKind kind;
  final Map<String, Object?>? message;
}

/// One device's socket to the server: every space it is in, ops in both
/// directions, kept open for as long as the app is in the foreground.
///
/// Abstract so the service can be driven in a test by a fake wired to an
/// in-memory server. The real one reconnects on its own with backoff; the
/// service's whole view of it is [events] and [send].
abstract class SyncSocket {
  Stream<SocketEvent> get events;
  bool get isConnected;

  /// Opens the connection, and keeps reopening it until [close]. Idempotent.
  void connect();

  /// Writes one frame. False if there is no connection to write to, in
  /// which case the caller keeps what it wanted to send and tries again on
  /// the next [SocketEventKind.connected].
  bool send(Map<String, Object?> message);

  Future<void> close();
}

/// The socket over `dart:io`, with reconnect.
///
/// A dropped connection is ordinary — a phone changing networks, a laptop
/// lid, a proxy that reaps idle sockets — so coming back is the socket's
/// own job, with backoff and jitter so every device that lost the same
/// network does not return at the same instant. Nothing is buffered here:
/// the service holds what it has not managed to send, because it is the one
/// that knows what is still worth sending.
class WebSocketSyncSocket implements SyncSocket {
  WebSocketSyncSocket({
    required Uri url,
    required Future<String?> Function() token,
    Map<String, String> headers = const {},
    this.minRetry = const Duration(seconds: 1),
    this.maxRetry = const Duration(minutes: 1),
    this.pingInterval = const Duration(seconds: 25),
    this.connectTimeout = const Duration(seconds: 20),
  }) : _url = url.replace(scheme: url.scheme == 'https' ? 'wss' : 'ws'),
       _token = token,
       _headers = headers;

  final Uri _url;
  final Future<String?> Function() _token;
  final Map<String, String> _headers;
  final Duration minRetry;
  final Duration maxRetry;

  /// Client-side keepalive. The server pings too; either side noticing a
  /// dead peer is enough, and a phone behind a NAT is the one that has to
  /// notice first.
  final Duration pingInterval;
  final Duration connectTimeout;

  final StreamController<SocketEvent> _events = StreamController.broadcast();
  WebSocket? _socket;
  Timer? _retry;
  int _failures = 0;
  bool _wanted = false;
  bool _closed = false;
  bool _connected = false;

  /// Whether the service has been told the socket is down since it was last
  /// up. A connection that never comes up at all is still down, and the
  /// service needs to hear that once to start polling.
  bool _downSignaled = false;

  @override
  Stream<SocketEvent> get events => _events.stream;

  @override
  bool get isConnected => _connected;

  @override
  void connect() {
    if (_closed || _wanted) return;
    _wanted = true;
    unawaited(_open());
  }

  Future<void> _open() async {
    if (!_wanted || _closed || _socket != null) return;
    final token = await _token();
    if (token == null) {
      // Nothing to connect as. The service learns this from its own HTTP
      // calls and stops asking; here it is just a reason to wait.
      _scheduleRetry();
      return;
    }
    try {
      final socket = await WebSocket.connect(
        _url.toString(),
        headers: {..._headers, 'authorization': 'Bearer $token'},
      ).timeout(connectTimeout);
      if (!_wanted || _closed) {
        unawaited(socket.close());
        return;
      }
      socket.pingInterval = pingInterval;
      _socket = socket;
      _failures = 0;
      _connected = true;
      _downSignaled = false;
      _events.add(const SocketEvent.connected());
      socket.listen(
        _onData,
        onError: (_) => _onClosed(),
        onDone: _onClosed,
        cancelOnError: true,
      );
    } catch (error) {
      debugPrint('KapyNotes: socket connect failed: $error');
      _signalDown();
      _scheduleRetry();
    }
  }

  void _signalDown() {
    if (_downSignaled || _closed) return;
    _downSignaled = true;
    _events.add(const SocketEvent.disconnected());
  }

  void _onData(dynamic data) {
    if (data is! String) return;
    Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is Map<String, Object?>) _events.add(SocketEvent.message(decoded));
  }

  void _onClosed() {
    _socket = null;
    _connected = false;
    _signalDown();
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (!_wanted || _closed || _retry != null) return;
    _failures++;
    final backoff = minRetry * pow(2, min(_failures - 1, 6)).toDouble();
    final capped = backoff > maxRetry ? maxRetry : backoff;
    final jitter = Random().nextDouble() * 0.3 + 0.85;
    _retry = Timer(
      Duration(milliseconds: (capped.inMilliseconds * jitter).round()),
      () {
        _retry = null;
        unawaited(_open());
      },
    );
  }

  @override
  bool send(Map<String, Object?> message) {
    final socket = _socket;
    if (socket == null || !_connected) return false;
    try {
      socket.add(jsonEncode(message));
      return true;
    } catch (error) {
      debugPrint('KapyNotes: socket send failed: $error');
      _onClosed();
      return false;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _wanted = false;
    _retry?.cancel();
    _retry = null;
    final socket = _socket;
    _socket = null;
    _connected = false;
    _signalDown();
    await socket?.close();
    await _events.close();
  }
}
