import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// The apps Settings walks through connecting, each with the one way of
/// connecting that suits it best.
enum McpClientKind {
  claudeCode('Claude Code'),
  cursor('Cursor'),
  claudeDesktop('Claude Desktop'),
  codex('Codex'),
  vsCode('VS Code'),
  other('Another app');

  const McpClientKind(this.label);

  final String label;

  static McpClientKind? named(String? name) =>
      values.where((kind) => kind.name == name).firstOrNull;
}

/// What each app is given to connect: the server's name in its config, the
/// address and the client's token.
class McpClientSetup {
  const McpClientSetup({required this.url, required this.token});

  static const String serverName = 'kapy-notes';

  final String url;
  final String token;

  String get _bearer => 'Bearer $token';

  Map<String, Object?> get _http => {
    'type': 'http',
    'url': url,
    'headers': {'Authorization': _bearer},
  };

  String get claudeCode =>
      'claude mcp add --transport http --scope user $serverName $url '
      '--header "Authorization: $_bearer"';

  /// Cursor's install link: the server's entry, base64 in `config`.
  Uri get cursor => Uri.parse(
    'cursor://anysphere.cursor-deeplink/mcp/install'
    '?name=$serverName'
    '&config=${Uri.encodeQueryComponent(base64.encode(utf8.encode(jsonEncode({'url': url, 'headers': {'Authorization': _bearer}}))))}',
  );

  /// VS Code's install link: the server's entry, URL-encoded JSON.
  Uri get vsCode => Uri.parse(
    'vscode:mcp/install?${Uri.encodeComponent(jsonEncode({'name': serverName, ..._http}))}',
  );

  /// A table for `~/.codex/config.toml`.
  String get codex =>
      '[mcp_servers.$serverName]\n'
      'url = "$url"\n'
      'http_headers = { Authorization = "$_bearer" }\n';

  /// The `mcpServers` entry most other apps read.
  String get json => const JsonEncoder.withIndent('  ').convert({
    'mcpServers': {serverName: _http},
  });

  /// A Claude Desktop extension: a manifest and a small relay that Claude
  /// runs on the Node it ships with, carrying MCP between Claude's stdio and
  /// this server. Claude's own install dialog takes it from there.
  Uint8List claudeExtension({required String version}) {
    final manifest = utf8.encode(
      const JsonEncoder.withIndent('  ').convert({
        'manifest_version': '0.3',
        'name': serverName,
        'display_name': 'Kapy Notes',
        'version': version,
        'description':
            'Read your Kapy Notes notes and tasks, and add to them. Kapy Notes '
            'needs to be open on this computer.',
        'author': {'name': 'Kapybara', 'url': 'https://kapynotes.com'},
        'homepage': 'https://kapynotes.com',
        'server': {
          'type': 'node',
          'entry_point': 'server/index.js',
          'mcp_config': {
            'command': 'node',
            'args': [r'${__dirname}/server/index.js'],
            'env': {'KAPY_NOTES_URL': url, 'KAPY_NOTES_TOKEN': token},
          },
        },
        'compatibility': {
          'platforms': ['darwin', 'win32'],
          'runtimes': {'node': '>=18.0.0'},
        },
      }),
    );
    final relay = utf8.encode(_relay);
    final archive = Archive()
      ..add(ArchiveFile('manifest.json', manifest.length, manifest))
      ..add(ArchiveFile('server/index.js', relay.length, relay));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Every way of writing the token shown on screen: its first few
  /// characters and its last three, so the one on screen can't be copied off
  /// it and the one on the clipboard is whole.
  static String masked(String text, String token) => text.replaceAll(
    token,
    '${token.substring(0, 5)}••••••••••••${token.substring(token.length - 3)}',
  );
}

const String _relay = r'''// Kapy Notes for Claude Desktop. Carries MCP messages between Claude and
// Kapy Notes, which answers on this computer only (127.0.0.1).
const url = process.env.KAPY_NOTES_URL;
const token = process.env.KAPY_NOTES_TOKEN;
let queue = Promise.resolve();
let buffer = '';

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  buffer += chunk;
  let newline;
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, newline).trim();
    buffer = buffer.slice(newline + 1);
    if (line) queue = queue.then(() => forward(line));
  }
});
process.stdin.on('end', () => queue.then(() => process.exit(0)));

async function forward(line) {
  let id = null;
  try {
    id = JSON.parse(line).id ?? null;
  } catch {}
  let response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Accept: 'application/json, text/event-stream',
        Authorization: 'Bearer ' + token,
      },
      body: line,
    });
  } catch {
    return fail(id, 'Kapy Notes isn’t open. Open it (it can stay in the menu bar) and try again.');
  }
  const text = (await response.text()).trim();
  if (text) return process.stdout.write(text + '\n');
  if (response.status === 401) {
    return fail(id, 'Kapy Notes no longer knows this connection. Add it to Claude again from Kapy Notes, Settings, MCP.');
  }
  if (!response.ok) fail(id, 'Kapy Notes answered ' + response.status + '.');
}

function fail(id, message) {
  if (id === null) return;
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id, error: { code: -32000, message } }) + '\n');
}
''';
