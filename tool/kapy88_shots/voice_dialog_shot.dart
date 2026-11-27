import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:kapy_notes/audio/voice_player.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/editor/voice_chip.dart';
import 'package:kapy_notes/ui/voice_note_dialog.dart';
import 'package:material_ui/material_ui.dart';

class _Backend implements VoicePlayerBackend {
  @override
  Future<Duration?> load(File file) async => const Duration(seconds: 123);
  @override
  Future<void> play() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setSpeed(double value) async {}
  @override
  Future<void> stop() async {}
  @override
  Stream<Duration> get positions => const Stream.empty();
  @override
  Stream<void> get completions => const Stream.empty();
  @override
  Future<void> dispose() async {}
}

TranscriptSegment _seg(int s, int e, String t, int speaker) =>
    TranscriptSegment(s: s, e: e, t: t, speaker: speaker);

final _transcript = VoiceTranscript(
  lang: 'en',
  engine: 'cloud',
  at: DateTime(2026, 11, 19, 9).millisecondsSinceEpoch,
  speakers: const {0: 'Me', 1: 'Arjun'},
  segments: [
    _seg(0, 6500, 'Thanks for jumping on. I wanted to go through the pricing page before Friday.', 0),
    _seg(8200, 29000, 'Sure. The main thing is the annual plan. People should see it first, with the monthly price underneath.', 1),
    _seg(31000, 36500, 'So annual on the left, highlighted, and monthly as the second option?', 0),
    _seg(38400, 60000, 'Yes. And can we split the first invoice across two months? Finance said the first one is too big for most teams.', 1),
    _seg(62000, 73000, "I'll check with billing. If we can, I'll add a line under the price that says so.", 0),
    _seg(75000, 99000, "Good. Also the 40-seat tier. I'd show the price per seat, not the total.", 1),
    _seg(102000, 118000, "Makes sense. I'll send you the deck tomorrow morning, and the page by Friday.", 0),
    _seg(120000, 123000, 'Perfect, thanks.', 1),
  ],
);

final _summary = VoiceSummary(
  engine: 'cloud',
  at: DateTime(2026, 11, 19, 9, 1).millisecondsSinceEpoch,
  title: 'Pricing page plan with Arjun',
  points: const [
    'Show the annual plan first, with the monthly price under it.',
    'Ask billing whether the first invoice can be split across two months.',
    'Show the 40-seat tier as a price per seat, not a total.',
    'Send Arjun the deck tomorrow morning; the page is due Friday.',
  ],
);

NoteVoiceRef _ref(String shot) {
  final bare = shot.contains('transcribing') || shot.contains('failed');
  return NoteVoiceRef(
    offset: 0,
    hash: 'a',
    key: Uint8List(32),
    bytes: 2048,
    durationMs: 123000,
    transcript: bare ? null : _transcript,
    summary: bare ? null : _summary,
    takes: bare
        ? const []
        : [
            VoiceTake(
              kind: VoiceTakeKind.custom,
              text: 'Quick update: the pricing page leads with the annual plan, the 40-seat tier shows a price per seat, and I am checking whether the first invoice can be split. Page is due Friday.',
              engine: 'cloud',
              at: DateTime(2026, 11, 19, 9, 5).millisecondsSinceEpoch,
              instruction: 'Write a short message for my team',
            ),
          ],
  );
}

VoiceChipState _state(String shot) {
  if (shot.contains('transcribing')) return VoiceChipState.transcribing;
  if (shot.contains('failed')) return VoiceChipState.failed;
  return VoiceChipState.done;
}

void main() {
  final shot = Platform.environment['KAPY88_SHOT'] ?? 'desktop-summary';
  final dark = Platform.environment['KAPY88_DARK'] != '0';
  WidgetsFlutterBinding.ensureInitialized();
  if (shot.startsWith('phone')) {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
  }
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: KapyTheme.light(),
      darkTheme: KapyTheme.dark(),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      home: _Home(shot: shot),
    ),
  );
}

class _Home extends StatefulWidget {
  const _Home({required this.shot});
  final String shot;
  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  final _player = VoicePlayer(
    backend: _Backend(),
    files: (hash) async => File('/tmp/$hash.m4a'),
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _open());
  }

  Future<void> _open() async {
    final shot = widget.shot;
    unawaited(
      openVoiceNoteDialog(
        context,
        ref: _ref(shot),
        state: _state(shot),
        player: _player,
        recordedAt: DateTime(2026, 11, 19, 8, 55),
        actions: VoiceNoteActions(
          onInsert: (_) {},
          onDelete: () {},
          onTranscribeAgain: () {},
          onRegenerateSummary: () {},
          onTurnOnTranscription: () {},
          onRetry: () {},
          onChanged: (_) {},
          onRewrite: (_) async => '',
          onSaveSummaryInstruction: (_) {},
          summaryInstruction: null,
          failureReason: shot.contains('failed')
              ? 'This recording has no speech in it.'
              : null,
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (shot.contains('transcript')) _tap((w) => w is Text && w.data == 'Transcript');
    if (shot.contains('menu')) _tap((w) => w is IconButton && w.tooltip == 'More');
  }

  void _tap(bool Function(Widget) test) {
    Element? found;
    void visit(Element e) {
      if (found != null) return;
      if (test(e.widget)) {
        found = e;
        return;
      }
      e.visitChildren(visit);
    }
    WidgetsBinding.instance.rootElement!.visitChildren(visit);
    final box = found?.renderObject as RenderBox?;
    if (box == null) return;
    final at = box.localToGlobal(box.size.center(Offset.zero));
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(position: at, pointer: 88));
    GestureBinding.instance.handlePointerEvent(PointerUpEvent(position: at, pointer: 88));
  }

  @override
  Widget build(BuildContext context) =>
      Scaffold(backgroundColor: context.palette.editorBackground);
}
