import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/keyring.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/mcp/mcp_clients.dart';
import 'package:kapy_notes/mcp/mcp_service.dart';
import 'package:kapy_notes/ui/mcp_pane.dart';
import 'package:kapy_notes/ui/settings_dialog.dart';
import 'package:material_ui/material_ui.dart';

import 'mcp_test_helpers.dart';

class _RealHttp extends HttpOverrides {}

void main() {
  late McpFixture f;
  late McpService service;
  late Directory scratch;
  String? clipboard;

  setUp(() async {
    f = McpFixture();
    scratch = Directory(
      '${Directory.systemTemp.createTempSync('mcp').path}/kapy-mcpb',
    );
    addTearDown(() => scratch.parent.deleteSync(recursive: true));
    service = McpService(
      store: f.store,
      secrets: MemorySecrets(),
      library: f.library,
      scratch: () async => scratch,
    );
    await service.load();
    clipboard = null;
  });

  Future<void> pumpPane(WidgetTester tester, {bool scoped = true}) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    final pane = MaterialApp(
      theme: KapyTheme.dark(),
      home: Scaffold(
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: const [McpPane()],
        ),
      ),
    );
    await tester.pumpWidget(
      scoped ? McpScope(service: service, child: pane) : pane,
    );
  }

  testWidgets('a missing keyring is named before an app is connected', (
    tester,
  ) async {
    KeyringStatus.debugReset(available: false);
    addTearDown(KeyringStatus.debugReset);
    await pumpPane(tester);
    expect(find.text(KeyringNotice.connect), findsOneWidget);
  });

  testWidgets('is off until turned on, then shows its address', (tester) async {
    await pumpPane(tester);
    expect(find.text('Off. No assistant can reach your notes'), findsOneWidget);
    final copy = find.byKey(const ValueKey('mcp-connect-claudeCode'));
    expect(
      tester
          .widget<TextButton>(
            find.descendant(of: copy, matching: find.byType(TextButton)),
          )
          .onPressed,
      isNull,
    );

    await tester.runAsync(() => service.setEnabled(true));
    await tester.pump();
    expect(find.text('On this Mac only'), findsOneWidget);
    await tester.runAsync(() => service.setEnabled(false));
  });

  testWidgets('connecting Claude Code copies its command and masks the token', (
    tester,
  ) async {
    await tester.runAsync(() => service.setEnabled(true));
    await pumpPane(tester);
    await tester.tap(find.text('Copy command'));
    await tester.pumpAndSettle();

    expect(
      clipboard,
      startsWith(
        'claude mcp add --transport http --scope user kapy-notes http://${service.address}/mcp',
      ),
    );
    final token = RegExp(r'kapy_[A-Za-z0-9_-]{43}').firstMatch(clipboard!)![0]!;
    expect(find.textContaining('kapy_'), findsOneWidget);
    expect(find.textContaining(token), findsNothing);
    expect(find.textContaining('••••'), findsOneWidget);
    expect(
      find.text(
        'Copied. Paste it in Terminal, then ask Claude about your notes',
      ),
      findsOneWidget,
    );
    await tester.runAsync(() => service.setEnabled(false));
  });

  testWidgets(
    'when Claude doesn’t open, its file is deleted and its token revoked',
    (tester) async {
      final opened = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          opened.add((call.arguments as Map)['url'] as String);
          return false;
        },
      );
      await tester.runAsync(() => service.setEnabled(true));
      await pumpPane(tester);
      final add = find.text('Add to Claude');
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(add);
        for (var i = 0; i < 100 && opened.isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();

      expect(opened.single, endsWith('/Kapy%20Notes.mcpb'));
      final file = File(Uri.parse(opened.single).toFilePath());
      expect(file.path, startsWith(scratch.path));
      expect(file.existsSync(), isFalse);
      expect(file.parent.existsSync(), isFalse);
      expect(service.connections, isEmpty);
      expect(
        find.text('Claude didn’t open. Install Claude, then try again'),
        findsOneWidget,
      );
      await tester.runAsync(() => service.setEnabled(false));
    },
  );

  testWidgets('a connected app can be revoked', (tester) async {
    await tester.runAsync(() => service.setEnabled(true));
    await tester.runAsync(() => service.connect(McpClientKind.cursor));
    await pumpPane(tester);
    expect(find.text('Waiting for the app to connect'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mcp-revoke-cursor')));
    await tester.pumpAndSettle();
    expect(service.connections, isEmpty);
    expect(find.text('Add to Cursor'), findsOneWidget);
    await tester.runAsync(() => service.setEnabled(false));
  });

  testWidgets('shows what each app did, by title, and clears', (tester) async {
    await tester.runAsync(() async {
      await service.setEnabled(true);
      final token = await service.connect(McpClientKind.codex);
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        final request = await client.postUrl(Uri.parse(service.url!));
        request.headers
          ..set('authorization', 'Bearer $token')
          ..contentType = ContentType.json;
        request.add(
          utf8.encode(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': {
                'name': 'read_note',
                'arguments': {'id': f.plain},
              },
            }),
          ),
        );
        await (await request.close()).drain<void>();
        client.close();
      }, _RealHttp());
    });
    await pumpPane(tester);
    expect(find.text('Recent activity'), findsOneWidget);
    expect(find.text('Read “Trip budget”'), findsOneWidget);
    expect(find.textContaining('Connected · used'), findsOneWidget);
    final clear = find.byKey(const ValueKey('mcp-clear-activity'));
    await tester.ensureVisible(clear);
    await tester.pumpAndSettle();
    await tester.tap(clear);
    await tester.pump();
    expect(find.text('Recent activity'), findsNothing);
    await tester.runAsync(() => service.setEnabled(false));
  });

  testWidgets('an assistant’s archive shows Undo, which brings the note back', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await service.setEnabled(true);
      service.setAllowWrites(true);
      final token = await service.connect(McpClientKind.codex);
      await HttpOverrides.runWithHttpOverrides(() async {
        final client = HttpClient();
        final request = await client.postUrl(Uri.parse(service.url!));
        request.headers
          ..set('authorization', 'Bearer $token')
          ..contentType = ContentType.json;
        request.add(
          utf8.encode(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': {
                'name': 'update_note',
                'arguments': {'id': f.plain, 'archived': true},
              },
            }),
          ),
        );
        await (await request.close()).drain<void>();
        client.close();
      }, _RealHttp());
    });
    await pumpPane(tester);
    expect(find.text('Archived “Trip budget”'), findsOneWidget);
    final undo = find.text('Undo');
    await tester.ensureVisible(undo);
    await tester.pumpAndSettle();
    await tester.tap(undo);
    await tester.pump();
    expect(f.notes.byId(f.plain)!.isArchived, isFalse);
    expect(find.text('Undo'), findsNothing);
    await tester.runAsync(() => service.setEnabled(false));
  });

  testWidgets('where the server can’t run, says where assistants connect', (
    tester,
  ) async {
    await pumpPane(tester, scoped: false);
    expect(
      find.text(
        'Assistants connect through Kapy Notes on your Mac, Windows PC or '
        'Linux computer.',
      ),
      findsOneWidget,
    );
    expect(
      mcpSearchEntries(null).single.description,
      'Assistants connect through Kapy Notes on your Mac, Windows PC or '
      'Linux computer',
    );
  });

  testWidgets('a phone has the AI apps at the end of Voice & AI, and says '
      'where they connect', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSettings(
                context,
                layoutPrefs: LayoutPrefs(f.store),
                shortcuts: ShortcutPrefs(f.store),
                rates: RatesRepository(f.store),
                notes: f.notes,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // A phone sets its headings in capitals.
    expect(find.text('AI APPS'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('settings-section-voice')));
    await tester.pumpAndSettle();
    expect(find.text('AI APPS'), findsOneWidget);
    expect(
      find.text(
        'Assistants connect through Kapy Notes on your Mac, Windows PC or '
        'Linux computer.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('settings search finds it by the words people use', (
    tester,
  ) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      McpScope(
        service: service,
        child: MaterialApp(
          theme: KapyTheme.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showSettings(
                  context,
                  layoutPrefs: LayoutPrefs(f.store),
                  shortcuts: ShortcutPrefs(f.store),
                  rates: RatesRepository(f.store),
                  notes: f.notes,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('settings-search'));
    for (final (query, target) in [
      ('assistants', 'mcp-enabled'),
      ('AI', 'mcp-enabled'),
      ('Claude', 'mcp-connect'),
      ('Cursor', 'mcp-connect'),
      ('Codex', 'mcp-connect'),
    ]) {
      await tester.enterText(field, query);
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('settings-search-result-$target')),
        findsOneWidget,
        reason: query,
      );
    }
  });
}
