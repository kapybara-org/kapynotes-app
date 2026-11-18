import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../data/local_store.dart';
import '../sync/key_store.dart';
import 'mcp_clients.dart';
import 'mcp_library.dart';
import 'mcp_server.dart';
import 'mcp_tools.dart';

/// One app that has been given a token.
typedef McpConnection = ({
  String tokenHash,
  DateTime createdAt,
  DateTime? lastUsedAt,
});

/// One line of Recent activity: which app, what it did, and when. Holds a
/// note's title at most, never its text.
typedef McpActivity = ({
  McpClientKind client,
  String text,
  DateTime at,
  bool refused,
});

/// The MCP switch, its server, the apps given tokens, and what they did.
///
/// Off until the person turns it on. The address stays the same from launch
/// to launch, because every app's config holds it; when its port is taken it
/// moves to another and says so. Tokens are never stored: their SHA-256
/// digests go to the platform keystore, so a token exists only in the app it
/// was given to. Nothing here syncs: each computer runs its own server.
class McpService extends ChangeNotifier {
  McpService({
    required LocalStore store,
    required SecureStore secrets,
    required McpLibrary library,
    DateTime Function()? now,
    Random? random,
    Future<Directory> Function()? scratch,
  }) : _store = store,
       _secrets = secrets,
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure(),
       _scratch = scratch ?? _temporary {
    _server = McpServer(
      tools: McpTools(library),
      authenticate: _authenticate,
      writes: () => _allowWrites,
      onCall: _onCall,
    );
  }

  final LocalStore _store;
  final SecureStore _secrets;
  final DateTime Function() _now;
  final Random _random;
  final Future<Directory> Function() _scratch;
  late final McpServer _server;

  static const String _prefsKey = 'mcp.v1';
  static const String _activityKey = 'mcp.activity.v1';
  static const String _secretKey = 'mcp.clients.v1';
  static const int activityLimit = 50;

  /// How long Claude's extension file may wait to be installed.
  static const Duration extensionKept = Duration(minutes: 10);

  /// Where a port is first chosen: below the range both macOS and Windows
  /// hand out for outgoing connections, so one of those can't take it later.
  static const int _firstPort = 40000;
  static const int _portSpan = 9000;

  bool _enabled = false;
  bool _allowWrites = false;
  int? _port;
  bool _moved = false;
  String? _problem;
  Map<McpClientKind, McpConnection> _connections = {};
  List<McpActivity> _activity = [];

  /// How to take back this session's changes, by their activity line. Kept
  /// in memory only: an old title is all some of them hold, and that stays
  /// on this device for as long as the app is open.
  final Map<McpActivity, McpUndo> _undos = {};
  File? _extension;
  Timer? _extensionExpiry;
  Future<void> _stopped = Future<void>.value();

  bool get enabled => _enabled;
  bool get allowWrites => _allowWrites;

  /// Whether the server is answering right now.
  bool get running => _server.port != null;

  /// `127.0.0.1:port` while running.
  String? get address => running ? '127.0.0.1:${_server.port}' : null;
  String? get url => running ? 'http://${address!}${McpServer.path}' : null;

  /// Set when the saved port was taken at start and the server moved, so
  /// every app needs its config again.
  bool get moved => _moved;

  /// Why the server isn't running although it is on.
  String? get problem => _problem;

  Map<McpClientKind, McpConnection> get connections =>
      Map.unmodifiable(_connections);
  List<McpActivity> get activity => List.unmodifiable(_activity);

  /// Completes once [dispose] has let go of the port.
  @visibleForTesting
  Future<void> get stopped => _stopped;

  Future<void> load() async {
    await _clearScratch();
    final prefs = _store.read<Map<String, Object?>>(_prefsKey) ?? const {};
    _enabled = prefs['enabled'] == true;
    _allowWrites = prefs['writes'] == true;
    _port = prefs['port'] as int?;
    final used = prefs['used'] as Map<String, Object?>? ?? const {};
    _activity = [
      for (final raw in _store.read<List<Object?>>(_activityKey) ?? const [])
        ?_activityFrom(raw),
    ];
    try {
      final saved = await _secrets.read(_secretKey);
      _connections = {
        for (final raw in saved == null ? const [] : jsonDecode(saved) as List)
          if (raw case {
            'kind': final String kind,
            'hash': final String hash,
            'created': final int created,
          })
            ?McpClientKind.named(kind): (
              tokenHash: hash,
              createdAt: DateTime.fromMillisecondsSinceEpoch(created),
              lastUsedAt: switch (used[kind]) {
                final int at => DateTime.fromMillisecondsSinceEpoch(at),
                _ => null,
              },
            ),
      };
    } catch (_) {
      // An unreadable keystore leaves no app connected; each connects again.
      _connections = {};
    }
    if (_enabled) await _start();
    notifyListeners();
  }

  Future<void> setEnabled(bool on) async {
    if (on == _enabled) return;
    _enabled = on;
    _moved = false;
    if (on) {
      await _start();
    } else {
      _problem = null;
      await _server.stop();
    }
    _savePrefs();
    notifyListeners();
  }

  void setAllowWrites(bool on) {
    if (on == _allowWrites) return;
    _allowWrites = on;
    _savePrefs();
    notifyListeners();
  }

  /// Gives [kind] a new token, retiring any it had, and returns it once.
  Future<String> connect(McpClientKind kind) async {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final token = 'kapy_${base64Url.encode(bytes).replaceAll('=', '')}';
    _connections = {
      ..._connections,
      kind: (tokenHash: _digest(token), createdAt: _now(), lastUsedAt: null),
    };
    await _saveConnections();
    _savePrefs();
    notifyListeners();
    return token;
  }

  /// Takes [kind]'s token away: its very next request is refused.
  Future<void> revoke(McpClientKind kind) async {
    if (!_connections.containsKey(kind)) return;
    _connections = {..._connections}..remove(kind);
    await _saveConnections();
    _savePrefs();
    notifyListeners();
  }

  /// Writes Claude's extension, which holds its token in clear, to a folder
  /// of its own under the temporary directory, to be opened at once. It is
  /// deleted when Claude first calls in, after [extensionKept] at most, when
  /// the app closes, and at the next launch if the app never got to.
  Future<File> writeClaudeExtension(List<int> bytes) async {
    discardClaudeExtension();
    final root = await (await _scratch()).create(recursive: true);
    final file = File('${(await root.createTemp()).path}/Kapy Notes.mcpb');
    _extension = file;
    _extensionExpiry = Timer(extensionKept, discardClaudeExtension);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  void discardClaudeExtension() {
    _extensionExpiry?.cancel();
    _extensionExpiry = null;
    final file = _extension;
    _extension = null;
    try {
      file?.parent.deleteSync(recursive: true);
    } on FileSystemException catch (_) {}
  }

  static Future<Directory> _temporary() async =>
      Directory('${(await getTemporaryDirectory()).path}/kapy-mcpb');

  Future<void> _clearScratch() async {
    try {
      final root = await _scratch();
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {
      // Best effort: the next launch tries again.
    }
  }

  /// Whether [entry]'s change can still be taken back: it was made this
  /// session, and nothing has changed it since.
  bool canUndo(McpActivity entry) => _undos[entry]?.possible() ?? false;

  /// Takes [entry]'s change back, once.
  void undo(McpActivity entry) {
    final undo = _undos.remove(entry);
    if (undo != null && undo.possible()) undo.run();
    notifyListeners();
  }

  void clearActivity() {
    _undos.clear();
    _activity = [];
    _store.putNow(_activityKey, const <Object?>[]);
    notifyListeners();
  }

  Future<void> _start() async {
    _problem = null;
    final saved = _port;
    final candidates = [
      ?saved,
      for (var i = 0; i < 12; i++) _firstPort + _random.nextInt(_portSpan),
    ];
    for (final port in candidates) {
      try {
        await _server.start(port);
        _moved = saved != null && port != saved;
        _port = port;
        _savePrefs();
        return;
      } on SocketException {
        continue;
      }
    }
    _problem = 'Kapy Notes couldn’t find a free port on this computer.';
  }

  String? _authenticate(String token) {
    final digest = _digest(token);
    String? found;
    for (final MapEntry(key: kind, value: connection) in _connections.entries) {
      if (_sameDigest(digest, connection.tokenHash)) found = kind.name;
    }
    return found;
  }

  void _onCall(
    String client, {
    String? activity,
    bool refused = false,
    McpUndo? undo,
  }) {
    final kind = McpClientKind.named(client);
    final connection = _connections[kind];
    if (kind == null || connection == null) return;
    if (kind == McpClientKind.claudeDesktop) discardClaudeExtension();
    final at = _now();
    _connections = {
      ..._connections,
      kind: (
        tokenHash: connection.tokenHash,
        createdAt: connection.createdAt,
        lastUsedAt: at,
      ),
    };
    if (activity != null) {
      final entry = (client: kind, text: activity, at: at, refused: refused);
      _activity = [entry, ..._activity.take(activityLimit - 1)];
      _undos.removeWhere((each, _) => !_activity.contains(each));
      if (undo != null) _undos[entry] = undo;
      _store.put(_activityKey, [
        for (final entry in _activity)
          {
            'client': entry.client.name,
            'text': entry.text,
            'at': entry.at.millisecondsSinceEpoch,
            if (entry.refused) 'refused': true,
          },
      ]);
    }
    _savePrefs(now: false);
    notifyListeners();
  }

  static McpActivity? _activityFrom(Object? raw) => switch (raw) {
    {
      'client': final String client,
      'text': final String text,
      'at': final int at,
    }
        when McpClientKind.named(client) != null =>
      (
        client: McpClientKind.named(client)!,
        text: text,
        at: DateTime.fromMillisecondsSinceEpoch(at),
        refused: raw['refused'] == true,
      ),
    _ => null,
  };

  void _savePrefs({bool now = true}) {
    final value = {
      'enabled': _enabled,
      'writes': _allowWrites,
      'port': ?_port,
      'used': {
        for (final MapEntry(:key, :value) in _connections.entries)
          if (value.lastUsedAt case final at?)
            key.name: at.millisecondsSinceEpoch,
      },
    };
    now ? _store.putNow(_prefsKey, value) : _store.put(_prefsKey, value);
  }

  Future<void> _saveConnections() => _secrets.write(
    _secretKey,
    jsonEncode([
      for (final MapEntry(:key, :value) in _connections.entries)
        {
          'kind': key.name,
          'hash': value.tokenHash,
          'created': value.createdAt.millisecondsSinceEpoch,
        },
    ]),
  );

  static String _digest(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  /// Compares two digests in time that doesn't depend on where they differ.
  static bool _sameDigest(String a, String b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) {
      difference |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return difference == 0;
  }

  @override
  void dispose() {
    discardClaudeExtension();
    _stopped = _server.stop();
    super.dispose();
  }
}
