import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

enum LiveSignalKind {
  /// Something changed on another device. Sync.
  wake,

  /// The stream is open. Emitted again on every reconnect, because a stream
  /// that was down is a stream that may have slept through a wake-up.
  connected,

  /// The stream dropped and a reconnect is scheduled. Until it lands, this
  /// device is back to finding things out for itself.
  disconnected,
}

/// What the wake-up channel has to say. Never a note: see
/// `packages/contract/src/live.ts` for why the stream carries no data.
///
/// A wake names the space that changed where the server knows it, so the
/// device pulls one space rather than all of them. A wake with no space means
/// the list of spaces itself changed — an invitation accepted, a key granted,
/// a membership ended — and the device should refresh it.
class LiveSignal {
  const LiveSignal._(this.kind, [this.space]);

  final LiveSignalKind kind;
  final String? space;

  static const LiveSignal wake = LiveSignal._(LiveSignalKind.wake);
  static const LiveSignal connected = LiveSignal._(LiveSignalKind.connected);
  static const LiveSignal disconnected = LiveSignal._(
    LiveSignalKind.disconnected,
  );

  factory LiveSignal.wakeFor(String? space) =>
      space == null ? wake : LiveSignal._(LiveSignalKind.wake, space);

  @override
  bool operator ==(Object other) =>
      other is LiveSignal && other.kind == kind && other.space == space;

  @override
  int get hashCode => Object.hash(kind, space);

  @override
  String toString() =>
      space == null ? 'LiveSignal.${kind.name}' : 'LiveSignal.wake($space)';
}

/// SSE `event:` name for a wake-up. Matches `LIVE_EVENT`.
const String liveEventName = 'sync';

/// Holds `GET /sync/live` open and turns it into [LiveSignal]s.
///
/// Hand-rolled rather than pulled from a package: the whole of what we need
/// from SSE is "read lines, a blank one ends a frame, a leading colon is a
/// comment", and the alternative was a dependency for eighty lines of it.
///
/// Nothing here is fatal. Every failure is a network that will come back, so
/// the loop reconnects with backoff and simply stops emitting in the
/// meantime; [SyncService] polls while it is quiet. The one exception is a
/// rejected session, which would hand the same dead token over every few
/// seconds for as long as the app stayed open.
class LiveChannel {
  LiveChannel({
    required Uri url,
    required Future<String?> Function() token,
    required Map<String, String> headers,
    required http.Client client,
    this.minRetry = const Duration(seconds: 3),
    this.maxRetry = const Duration(minutes: 2),
    this.connectTimeout = const Duration(seconds: 20),
  }) : _url = url,
       _token = token,
       _headers = headers,
       _client = client;

  final Uri _url;
  final Future<String?> Function() _token;
  final Map<String, String> _headers;
  final http.Client _client;

  final Duration minRetry;
  final Duration maxRetry;

  /// Applies to opening the stream, and to nothing after it. A live channel
  /// that has been silent for an hour is working exactly as intended.
  final Duration connectTimeout;

  /// Broadcast so the stream survives being listened to twice. The api hands
  /// the same channel out every time, and backgrounding then resuming means
  /// exactly that — a single-subscription controller would throw the second
  /// time the app came back.
  late final StreamController<LiveSignal> _signals =
      StreamController<LiveSignal>.broadcast(onListen: _start, onCancel: _stop);

  bool _wanted = false;
  bool _connected = false;
  int _failures = 0;
  StreamSubscription<String>? _reading;
  Completer<void>? _stream;
  Completer<void>? _backoff;
  Timer? _timer;

  /// Connects on the first listener and disconnects when it goes away, so a
  /// socket exists only while something is actually waiting on it.
  Stream<LiveSignal> get signals => _signals.stream;

  bool get isConnected => _connected;

  void _start() {
    if (_wanted) return;
    _wanted = true;
    unawaited(_run());
  }

  void _stop() {
    _wanted = false;
    _timer?.cancel();
    _timer = null;
    unawaited(_reading?.cancel());
    _reading = null;
    // Releases whichever of the two the loop is sitting on, so it unwinds now
    // rather than after a two-minute backoff nobody is waiting for.
    _release(_stream);
    _release(_backoff);
  }

  Future<void> dispose() async {
    _stop();
    await _signals.close();
  }

  Future<void> _run() async {
    while (_wanted) {
      try {
        final token = await _token();
        // No session: nothing to listen to, and nothing a retry would fix.
        // The next sync pass is what reports a sign-out, not this.
        if (token == null) return;

        final request = http.Request('GET', _url)
          ..headers.addAll(_headers)
          ..headers['authorization'] = 'Bearer $token'
          ..headers['accept'] = 'text/event-stream'
          ..headers['cache-control'] = 'no-store'
          ..persistentConnection = true;

        final response = await _client.send(request).timeout(connectTimeout);
        // Rejected, or too old to be served: neither is a network that will
        // come back, and the next sync pass is what says so to the user.
        if (response.statusCode == 401 ||
            response.statusCode == 403 ||
            response.statusCode == 426) {
          return;
        }
        if (response.statusCode != 200) {
          throw http.ClientException(
            'live returned ${response.statusCode}',
            _url,
          );
        }

        _failures = 0;
        _connected = true;
        _emit(LiveSignal.connected);
        await _read(response);
      } catch (_) {
        // Offline, DNS, TLS, a captive portal, a proxy that will not carry an
        // event stream: indistinguishable from here, and all worth another go.
      } finally {
        _connected = false;
      }

      if (!_wanted) return;
      // Announced whether the stream dropped or never opened in the first
      // place. The second is the case that matters: a proxy that refuses
      // event streams would otherwise leave a device that never connects,
      // never says so, and therefore never falls back to polling either.
      _emit(LiveSignal.disconnected);
      await _wait();
    }
  }

  /// Reads frames until the stream ends. Completes rather than throwing: the
  /// caller treats every ending the same way.
  Future<void> _read(http.StreamedResponse response) {
    final finished = Completer<void>();
    _stream = finished;
    var event = '';
    var data = '';

    _reading =
        response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (line) {
                if (line.isEmpty) {
                  // A blank line ends a frame. Only one kind of frame means
                  // anything; a heartbeat is a comment and never gets here.
                  if (event == liveEventName) {
                    _emit(LiveSignal.wakeFor(_spaceIn(data)));
                  }
                  event = '';
                  data = '';
                  return;
                }
                if (line.startsWith(':')) return;
                final colon = line.indexOf(':');
                if (colon < 0) return;
                final field = line.substring(0, colon);
                final value = line.substring(colon + 1).trimLeft();
                if (field == 'event') event = value;
                if (field == 'data') data = value;
              },
              onError: (Object _) => _release(finished),
              onDone: () => _release(finished),
              cancelOnError: true,
            );

    return finished.future;
  }

  /// The space a wake-up names, if the server said. Anything else — a build
  /// from before spaces sent `1` — is a wake for everything.
  static String? _spaceIn(String data) {
    if (data.isEmpty) return null;
    try {
      final decoded = jsonDecode(data);
      final space = decoded is Map ? decoded['space'] : null;
      return space is String && space.isNotEmpty ? space : null;
    } on FormatException {
      return null;
    }
  }

  Future<void> _wait() {
    _failures++;
    final backoff = minRetry * pow(2, min(_failures - 1, 6)).toDouble();
    final capped = backoff > maxRetry ? maxRetry : backoff;
    // Jitter, so every device that lost the same wifi does not come back on
    // the same second and reconnect the server to death.
    final jitter = Random().nextDouble() * 0.3 + 0.85;

    final gate = Completer<void>();
    _backoff = gate;
    _timer?.cancel();
    _timer = Timer(
      Duration(milliseconds: (capped.inMilliseconds * jitter).round()),
      () => _release(gate),
    );
    return gate.future;
  }

  void _release(Completer<void>? gate) {
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void _emit(LiveSignal signal) {
    // There is a window between `_stop` and the loop unwinding where there is
    // nobody left to tell.
    if (_signals.isClosed || !_signals.hasListener) return;
    _signals.add(signal);
  }
}
