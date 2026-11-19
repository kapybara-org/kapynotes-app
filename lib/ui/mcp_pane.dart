import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import '../mcp/mcp_clients.dart';
import '../mcp/mcp_service.dart';
import 'settings_dialog.dart';
import 'settings_rows.dart';
import 'settings_search.dart';

/// Hands the MCP service to Settings, wherever it is opened from. Present
/// only on the desktops, where the server can run.
class McpScope extends InheritedNotifier<McpService> {
  const McpScope({super.key, required McpService service, required super.child})
    : super(notifier: service);

  static McpService? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<McpScope>()?.notifier;
}

const String mcpSectionLabel = 'MCP';
const KapyIconData mcpSectionIcon = KapyIcons.mcpServer;

/// The line under MCP in Settings. A phone has no server of its own, so it
/// says where assistants connect instead, as the pane does.
String get mcpSectionSummary => AppPlatform.isMobile
    ? _connectElsewhere
    : 'Let the AI apps you use read and change your notes, on this computer only';

const String _connectElsewhere =
    'Assistants connect through Kapy Notes on your Mac, Windows PC or Linux '
    'computer';

String get _computer => AppPlatform.isWindows
    ? 'this PC'
    : AppPlatform.isLinux
    ? 'this computer'
    : 'this Mac';

/// What settings search finds in the MCP pane. The words people use for it
/// lead there too: "assistants", "AI", and the apps by name.
List<SettingsSearchEntry<SettingsSection>> mcpSearchEntries(
  McpService? service,
) {
  const apps = [
    'Claude',
    'Claude Code',
    'Claude Desktop',
    'Cursor',
    'Codex',
    'VS Code',
  ];
  const words = ['assistants', 'AI', 'MCP', 'model context protocol', ...apps];
  SettingsSearchEntry<SettingsSection> entry(
    String title, {
    String? target,
    String? description,
    String? value,
    List<String> keywords = words,
  }) => SettingsSearchEntry(
    section: SettingsSection.mcp,
    sectionLabel: mcpSectionLabel,
    title: title,
    icon: mcpSectionIcon,
    target: target,
    description: description,
    value: value,
    keywords: keywords,
  );
  if (service == null) {
    return [entry('AI assistants', description: _connectElsewhere)];
  }
  return [
    entry(
      'Let assistants use Kapy Notes',
      target: 'mcp-enabled',
      value: service.enabled ? 'On' : 'Off',
    ),
    entry(
      'Allow changes',
      target: 'mcp-allow-changes',
      value: service.allowWrites ? 'On' : 'Off',
      keywords: const [
        'assistants',
        'AI',
        'MCP',
        'write',
        'edit',
        'create',
        'tag',
        'archive',
        'draw',
      ],
    ),
    entry(
      'Connect an app',
      target: 'mcp-connect',
      keywords: const [
        'assistants',
        'AI',
        'MCP',
        'connect',
        'token',
        'revoke',
        ...apps,
      ],
    ),
  ];
}

/// Settings → MCP: the switch, changes, connecting each app, and what the
/// apps did.
class McpPane extends StatefulWidget {
  const McpPane({super.key});

  @override
  State<McpPane> createState() => _McpPaneState();
}

class _McpPaneState extends State<McpPane> {
  /// The app just connected, with what it was given and what to do next.
  McpClientKind? _open;
  String? _snippet;
  String? _token;
  String? _hint;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final service = McpScope.maybeOf(context);
    if (service == null) {
      return const SettingsNote('$_connectElsewhere.');
    }
    final activity = service.activity;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SettingsLabel('Access'),
        SettingsGroup(
          children: [
            SettingsToggleRow(
              key: const ValueKey('mcp-enabled'),
              title: 'Let assistants use Kapy Notes',
              subtitle: _status(service),
              value: service.enabled,
              onChanged: (on) => unawaited(service.setEnabled(on)),
            ),
            SettingsToggleRow(
              key: const ValueKey('mcp-allow-changes'),
              title: 'Allow changes',
              subtitle:
                  'Write and edit notes, tag, pin, archive, change tasks and '
                  'draw. Never deletes notes or touches Hidden Notes',
              value: service.allowWrites,
              onChanged: service.enabled ? service.setAllowWrites : null,
            ),
          ],
        ),
        SettingsNote(
          'Hidden notes never reach an assistant. Archived notes can be read, '
          'not changed, and drawings show by name only. Kapy Notes needs to '
          '${AppPlatform.isLinux ? 'be running' : 'be open; it can stay in the menu bar'}.',
        ),
        const SizedBox(height: SettingsMetrics.groupGap),
        const SettingsLabel('Connect an app', key: ValueKey('mcp-connect')),
        SettingsGroup(
          children: [
            for (final kind in McpClientKind.values)
              if (kind != McpClientKind.claudeDesktop || !AppPlatform.isLinux)
                _clientRow(service, kind),
          ],
        ),
        const SettingsNote(
          'ChatGPT’s desktop app reaches MCP servers from OpenAI’s cloud, so it '
          'can’t use one on this computer.',
        ),
        if (activity.isNotEmpty) ...[
          const SizedBox(height: SettingsMetrics.groupGap),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(child: SettingsLabel('Recent activity')),
              TextButton(
                key: const ValueKey('mcp-clear-activity'),
                onPressed: service.clearActivity,
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  padding: const EdgeInsets.fromLTRB(6, 0, 4, 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  foregroundColor: context.palette.textTertiary,
                ),
                child: const Text('Clear', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          SettingsGroup(
            children: [
              for (final entry in activity.take(8))
                _ActivityRow(
                  entry: entry,
                  onUndo: service.canUndo(entry)
                      ? () => service.undo(entry)
                      : null,
                ),
            ],
          ),
        ],
      ],
    );
  }

  String _status(McpService service) {
    if (!service.enabled) return 'Off. No assistant can reach your notes';
    if (service.problem case final problem?) return problem;
    final address = service.address!;
    if (service.moved) {
      return 'Moved to $address because the old port was taken. Connect '
          'your apps again';
    }
    return 'On $_computer only · $address';
  }

  Widget _clientRow(McpService service, McpClientKind kind) {
    final connection = service.connections[kind];
    final open = _open == kind;
    final snippet = open ? _snippet : null;
    final used = connection?.lastUsedAt;
    final subtitle = open
        ? _hint!
        : used != null
        ? 'Connected · used ${_ago(used)}'
        : connection != null
        ? 'Waiting for its first request'
        : _idle(kind);
    final Widget trailing;
    if (open && snippet != null) {
      trailing = SettingsRowButton(
        label: 'Copy again',
        prominent: true,
        onPressed: () =>
            unawaited(Clipboard.setData(ClipboardData(text: snippet))),
      );
    } else if (connection != null && !open) {
      trailing = SettingsRowButton(
        key: ValueKey('mcp-revoke-${kind.name}'),
        label: 'Revoke',
        onPressed: () => unawaited(service.revoke(kind)),
      );
    } else {
      trailing = SettingsRowButton(
        key: ValueKey('mcp-connect-${kind.name}'),
        label: _action(kind),
        onPressed: service.running && !_busy
            ? () => unawaited(_connect(service, kind))
            : null,
      );
    }
    return SettingsRow(
      title: kind.label,
      subtitle: subtitle,
      trailing: trailing,
      below: snippet == null
          ? null
          : _Well(text: McpClientSetup.masked(snippet, _token!)),
    );
  }

  static String _idle(McpClientKind kind) => switch (kind) {
    McpClientKind.claudeCode => 'Paste one command in Terminal',
    McpClientKind.cursor => 'Opens Cursor to confirm',
    McpClientKind.claudeDesktop => 'Installs as a Claude extension',
    McpClientKind.codex => 'For ~/.codex/config.toml',
    McpClientKind.vsCode => 'Opens VS Code to confirm',
    McpClientKind.other => 'Any app that connects to MCP over HTTP',
  };

  static String _action(McpClientKind kind) => switch (kind) {
    McpClientKind.claudeCode => 'Copy command',
    McpClientKind.cursor => 'Add to Cursor',
    McpClientKind.claudeDesktop => 'Add to Claude',
    McpClientKind.codex => 'Copy config',
    McpClientKind.vsCode => 'Add to VS Code',
    McpClientKind.other => 'Copy JSON',
  };

  Future<void> _connect(McpService service, McpClientKind kind) async {
    setState(() => _busy = true);
    try {
      final token = await service.connect(kind);
      final url = service.url;
      if (url == null) return;
      final setup = McpClientSetup(url: url, token: token);
      String? snippet;
      final String hint;
      switch (kind) {
        case McpClientKind.claudeCode:
          snippet = setup.claudeCode;
          hint =
              'Copied. Paste it in Terminal, then ask Claude about your notes';
        case McpClientKind.codex:
          snippet = setup.codex;
          hint = 'Copied. Add it to ~/.codex/config.toml, then start Codex';
        case McpClientKind.other:
          snippet = setup.json;
          hint = 'Copied. Add it where the app keeps its MCP servers';
        case McpClientKind.cursor || McpClientKind.vsCode:
          final link = kind == McpClientKind.cursor
              ? setup.cursor
              : setup.vsCode;
          if (await _launch(link)) {
            hint = 'Opened ${kind.label}. Confirm there to finish';
          } else {
            snippet = setup.json;
            hint = '${kind.label} didn’t open, so its JSON is copied instead';
          }
        case McpClientKind.claudeDesktop:
          final file = await service.writeClaudeExtension(
            setup.claudeExtension(version: '1.0.0'),
          );
          if (await _launch(Uri.file(file.path))) {
            hint = 'Claude opens to install it';
          } else {
            service.discardClaudeExtension();
            await service.revoke(kind);
            hint = 'Claude didn’t open. Install Claude, then try again';
          }
      }
      if (snippet != null) {
        await Clipboard.setData(ClipboardData(text: snippet));
      }
      if (!mounted) return;
      setState(() {
        _open = kind;
        _snippet = snippet;
        _token = token;
        _hint = hint;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Future<bool> _launch(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }

  static String _ago(DateTime at) {
    final elapsed = DateTime.now().difference(at);
    if (elapsed.inMinutes < 1) return 'just now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes} min ago';
    if (elapsed.inDays < 1) return '${elapsed.inHours} h ago';
    return '${elapsed.inDays} d ago';
  }
}

/// A config as it was copied, with its token cut short on screen.
class _Well extends StatelessWidget {
  const _Well({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
      decoration: BoxDecoration(
        color: palette.wellBackground,
        border: Border.all(color: palette.controlBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: AppFonts.mono,
          fontSize: 11,
          height: 1.5,
          color: palette.textPrimary,
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.entry, this.onUndo});

  final McpActivity entry;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              entry.client.label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: palette.textPrimary,
              ),
            ),
          ),
          if (entry.refused)
            Padding(
              padding: const EdgeInsets.only(top: 5, right: 6),
              child: Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: palette.clay,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          Expanded(
            child: Text(
              entry.text,
              style: TextStyle(fontSize: 12.5, color: palette.textDescription),
            ),
          ),
          if (onUndo != null)
            TextButton(
              onPressed: onUndo,
              style: TextButton.styleFrom(
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                foregroundColor: palette.textPrimary,
              ),
              child: const Text('Undo', style: TextStyle(fontSize: 12)),
            ),
          const SizedBox(width: 10),
          Text(
            _McpPaneState._ago(entry.at),
            style: TextStyle(fontSize: 11.5, color: palette.textTertiary),
          ),
        ],
      ),
    );
  }
}
