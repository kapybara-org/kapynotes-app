import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../audio/voice_player.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../data/blob_store.dart';
import '../data/note_attachment.dart';
import '../speech/summarizer.dart';
import '../speech/summary_instructions.dart';
import 'editor/voice_chip.dart';

/// What the dialog can offer beyond playback, decided by the caller.
///
/// Passed in rather than worked out here because everything that decides it —
/// whether there is an account, whether consent was given, how many minutes
/// are left — lives above the editor, and the dialog should not grow a second
/// opinion about any of it.
class VoiceNoteActions {
  const VoiceNoteActions({
    this.onInsert,
    this.onDelete,
    this.onTranscribeAgain,
    this.onRegenerateSummary,
    this.onTurnOnTranscription,
    this.onSignIn,
    this.onDownload,
    this.onRetry,
    this.onChanged,
    this.onRewrite,
    this.onSaveSummaryInstruction,
    this.summaryInstruction,
    this.failureReason,
  });

  final void Function(String text)? onInsert;
  final VoidCallback? onDelete;
  final VoidCallback? onTranscribeAgain;
  final VoidCallback? onRegenerateSummary;
  final VoidCallback? onTurnOnTranscription;
  final VoidCallback? onSignIn;
  final VoidCallback? onDownload;
  final VoidCallback? onRetry;

  /// Writes the recording back to the note.
  ///
  /// One callback rather than one per edit, because everything the dialog
  /// changes — a speaker's name, a post it just wrote, a post being thrown
  /// away — is the same operation: this ref replaces the one on the note.
  final void Function(NoteVoiceRef next)? onChanged;

  /// Turns the transcript into whatever [instruction] asks for.
  ///
  /// Throws on failure, and the message is shown as written: the summariser
  /// layer already says whether the fix is signing in, downloading a model,
  /// or turning on a system setting.
  final Future<String> Function(String instruction)? onRewrite;

  /// Saves how summaries should be written from now on. Null clears it back
  /// to the app's own wording.
  final void Function(String? instruction)? onSaveSummaryInstruction;

  /// What the instruction editor opens on: the user's words if they have
  /// written any, otherwise the wording actually in use.
  final String? summaryInstruction;

  final String? failureReason;
}

/// Opens a recording: a dialog on desktop, a tall sheet on a phone.
///
/// The split follows `openSettingsDialog`, so a recording opens the same way
/// everything else in the app does.
Future<void> openVoiceNoteDialog(
  BuildContext context, {
  required NoteVoiceRef ref,
  required VoiceChipState state,
  required BlobStore blobs,
  VoicePlayer? player,
  VoiceNoteActions actions = const VoiceNoteActions(),
  DateTime? recordedAt,
}) {
  Widget build({required bool asSheet}) => VoiceNoteView(
    ref: ref,
    state: state,
    blobs: blobs,
    player: player,
    actions: actions,
    recordedAt: recordedAt,
    asSheet: asSheet,
  );

  if (!AppPlatform.isMobile) {
    return showDialog<void>(
      context: context,
      builder: (context) => build(asSheet: false),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
    builder: (context) => build(asSheet: true),
  );
}

class VoiceNoteView extends StatefulWidget {
  const VoiceNoteView({
    super.key,
    required this.ref,
    required this.state,
    required this.blobs,
    this.player,
    this.actions = const VoiceNoteActions(),
    this.recordedAt,
    this.asSheet = false,
  });

  final NoteVoiceRef ref;
  final VoiceChipState state;
  final BlobStore blobs;
  final VoicePlayer? player;
  final VoiceNoteActions actions;
  final DateTime? recordedAt;
  final bool asSheet;

  @override
  State<VoiceNoteView> createState() => _VoiceNoteViewState();
}

class _VoiceNoteViewState extends State<VoiceNoteView> {
  /// Moves playback of *this* recording to [position], starting it if it is
  /// not the one loaded.
  ///
  /// Both halves were wrong before. A tap on a transcript line went straight
  /// to the player, which seeks whatever it happens to be holding — so with
  /// another note's recording playing it moved that one instead. And with
  /// nothing playing it moved nothing, which is the more likely case: reading
  /// the transcript first and tapping the line you want to hear is the point
  /// of having timings at all.
  Future<void> _seekTo(Duration position) async {
    final player = widget.player;
    if (player == null) return;
    if (player.activeHash == widget.ref.hash) {
      await player.seek(position);
      return;
    }
    final file = await widget.blobs.fileFor(widget.ref.hash);
    if (file == null) return;
    await player.play(widget.ref.hash, file, from: position);
  }

  late bool _onSummary;

  /// The recording as this dialog has it, which is ahead of the note for as
  /// long as the dialog is open.
  ///
  /// The dialog is a route: it is built once with a ref and is not rebuilt
  /// when the note changes underneath. Naming a speaker or writing a post
  /// has to show up immediately, so the edit is made here and handed to
  /// [VoiceNoteActions.onChanged] to persist.
  late NoteVoiceRef _live;

  /// The rewrite being written, if one is. Only ever one at a time: they
  /// cost a model call and two at once would race to be saved.
  VoiceTakeKind? _rewriting;
  String? _rewriteError;

  @override
  void initState() {
    super.initState();
    _live = widget.ref;
    // Opens on whichever tab has something to read. Not remembered between
    // openings: a rule you can predict beats one that is merely sticky.
    _onSummary = widget.ref.summary != null;
  }

  NoteVoiceRef get _ref => _live;

  /// Applies an edit here and on the note, in that order.
  void _apply(NoteVoiceRef next) {
    setState(() => _live = next);
    widget.actions.onChanged?.call(next);
  }

  /// The text **Insert into note** puts in, one line per point or paragraph.
  String? get _insertableText {
    if (_onSummary) {
      final summary = _ref.summary;
      if (summary == null) return null;
      return summary.points.map((point) => '• $point').join('\n');
    }
    final transcript = _ref.transcript;
    if (transcript == null || transcript.segments.isEmpty) return null;
    return groupTranscriptParagraphs(transcript.segments)
        .map((paragraph) => paragraph.map((s) => s.t).join(' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: _ref.summary?.title ?? 'Voice note',
          subtitle: _subtitle(),
          onClose: () => Navigator.of(context).maybePop(),
        ),
        VoiceNotePlayerRow(
          ref: _ref,
          player: widget.player,
          blobs: widget.blobs,
        ),
        _Tabs(
          onSummary: _onSummary,
          hasSummary: _ref.summary != null,
          onChanged: (value) => setState(() => _onSummary = value),
        ),
        Expanded(child: _content(palette)),
        _Footer(
          onInsert: _insertableText == null || widget.actions.onInsert == null
              ? null
              : () {
                  widget.actions.onInsert!(_insertableText!);
                  Navigator.of(context).maybePop();
                },
          onMenu: _showOverflow,
        ),
      ],
    );

    if (widget.asSheet) {
      return FractionallySizedBox(
        heightFactor: 0.92,
        child: Container(
          decoration: BoxDecoration(
            color: palette.surfaceBackground,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(top: false, child: body),
        ),
      );
    }
    return Dialog(
      backgroundColor: palette.surfaceBackground,
      child: SizedBox(width: 560, height: 640, child: body),
    );
  }

  String _subtitle() {
    final at = widget.recordedAt;
    final duration = formatVoiceDuration(_ref.duration);
    if (at == null) return duration;
    return '${_formatDate(at)} · $duration';
  }

  Widget _content(CalcPalette palette) {
    final empty = _emptyState();
    if (empty != null) return empty;
    return _onSummary ? _summary(palette) : _transcript(palette);
  }

  /// Every reason there is nothing to read, each a sentence and one button.
  Widget? _emptyState() {
    final actions = widget.actions;
    return switch (widget.state) {
      VoiceChipState.needsConsent => _Empty(
        message: 'Turn on transcription to get text and a summary.',
        actionLabel: 'Turn on',
        onAction: actions.onTurnOnTranscription,
      ),
      VoiceChipState.needsAccount => _Empty(
        message: 'Sign in to get text and a summary.',
        actionLabel: actions.onSignIn != null ? 'Sign in' : null,
        onAction: actions.onSignIn,
      ),
      VoiceChipState.outOfMinutes => const _Empty(
        message: "You've used this month's minutes.",
      ),
      VoiceChipState.transcribing => const _Empty(
        message: 'Transcribing…',
        busy: true,
      ),
      VoiceChipState.summarising => const _Empty(
        message: 'Summarising…',
        busy: true,
      ),
      VoiceChipState.waiting => const _Empty(
        message: 'Waiting for connection.',
      ),
      VoiceChipState.retrying => const _Empty(
        message: "Transcription didn't go through. Trying again soon.",
      ),
      VoiceChipState.failed => _Empty(
        message: "Couldn't transcribe this recording.",
        caption: actions.failureReason,
        actionLabel: 'Retry',
        onAction: actions.onRetry,
      ),
      _ when _onSummary && _ref.summary == null => _Empty(
        message: 'No summary yet.',
        actionLabel: actions.onSignIn != null ? 'Sign in' : null,
        onAction: actions.onSignIn,
      ),
      _ when !_onSummary && _ref.transcript == null => _Empty(
        message: 'No transcript yet.',
        actionLabel: actions.onSignIn != null ? 'Sign in' : null,
        onAction: actions.onSignIn,
      ),
      _ => null,
    };
  }

  Widget _summary(CalcPalette palette) {
    final summary = _ref.summary!;
    final takes = _ref.takes.reversed.toList(growable: false);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      children: [
        for (final point in summary.points)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('•  ', style: TextStyle(color: palette.textSecondary)),
                Expanded(
                  child: SelectableText(
                    point,
                    style: TextStyle(color: palette.textPrimary, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 10),
        // Says where the summary came from, and — in the same breath — that
        // how it is written is something the reader chose and can change.
        // The setting is here rather than only in Settings because this is
        // where somebody decides they wanted a different kind of summary.
        Row(
          children: [
            Expanded(
              child: Text(
                'Written from the transcript',
                style: TextStyle(fontSize: 11, color: palette.textTertiary),
              ),
            ),
            if (widget.actions.onSaveSummaryInstruction != null)
              _QuietButton(
                label: 'Change how',
                onPressed: () => unawaited(_editSummaryInstruction()),
              ),
          ],
        ),
        if (_ref.transcript != null && widget.actions.onRewrite != null) ...[
          const SizedBox(height: 18),
          Divider(height: 1, color: palette.separator),
          const SizedBox(height: 16),
          Text(
            'MAKE SOMETHING FROM THIS',
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w600,
              color: palette.textTertiary,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kind in VoiceTakeKind.values)
                _RewriteChip(
                  label: switch (kind) {
                    VoiceTakeKind.x => 'Post for X',
                    VoiceTakeKind.linkedin => 'Post for LinkedIn',
                    VoiceTakeKind.custom => 'Your own words…',
                  },
                  busy: _rewriting == kind,
                  // One at a time: each costs a model call, and two racing
                  // would both try to be the newest take.
                  onPressed: _rewriting != null
                      ? null
                      : () => unawaited(_rewrite(kind)),
                ),
            ],
          ),
          if (_rewriteError case final String reason) ...[
            const SizedBox(height: 10),
            Text(
              reason,
              style: TextStyle(fontSize: 12, color: palette.textSecondary),
            ),
          ],
          for (final take in takes) ...[
            const SizedBox(height: 12),
            _TakeCard(
              take: take,
              onCopy: () => unawaited(_copy(take.text)),
              onRemove: () => _apply(_ref.withoutTake(take)),
              onAgain: _rewriting != null
                  ? null
                  : () => unawaited(
                      _rewrite(take.kind, custom: take.instruction),
                    ),
            ),
          ],
        ],
      ],
    );
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(const SnackBar(content: Text('Copied')));
  }

  /// Writes one take, and keeps it.
  ///
  /// A custom instruction is asked for first, pre-filled with whatever was
  /// asked last time so that trying a wording again is an edit rather than a
  /// retype.
  Future<void> _rewrite(VoiceTakeKind kind, {String? custom}) async {
    final rewrite = widget.actions.onRewrite;
    final transcript = _ref.transcript;
    if (rewrite == null || transcript == null) return;

    var instruction = instructionFor(kind, custom: custom);
    if (kind == VoiceTakeKind.custom) {
      final asked = await _askForInstruction(
        initial: custom ?? _lastCustomInstruction ?? '',
      );
      if (asked == null || asked.trim().isEmpty) return;
      instruction = asked.trim();
      _lastCustomInstruction = instruction;
    }

    setState(() {
      _rewriting = kind;
      _rewriteError = null;
    });
    try {
      final text = await rewrite(instruction);
      if (!mounted) return;
      _apply(
        _ref.withTake(
          VoiceTake(
            kind: kind,
            text: text,
            engine: _ref.summary?.engine ?? transcript.engine,
            at: DateTime.now().millisecondsSinceEpoch,
            instruction: kind == VoiceTakeKind.custom ? instruction : null,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _rewriteError = _describe(error));
    } finally {
      if (mounted) setState(() => _rewriting = null);
    }
  }

  /// Kept for the session rather than saved: a one-off instruction is one
  /// somebody is still trying out, and the saved one is the summary's.
  String? _lastCustomInstruction;

  static String _describe(Object error) => switch (error) {
    SummarizerUnavailable(:final message) => message,
    _ => 'That did not work. Try again in a moment.',
  };

  Future<String?> _askForInstruction({required String initial}) =>
      showInstructionSheet(
        context,
        title: 'What should it write?',
        help:
            'Ask for anything the transcript can answer: a message, a to-do '
            'list, a shorter version. It only uses what you said.',
        hint: 'Write a short message to my team about this.',
        initial: initial,
        confirmLabel: 'Write it',
      );

  /// Changes how every summary from now on is written.
  Future<void> _editSummaryInstruction() async {
    final save = widget.actions.onSaveSummaryInstruction;
    if (save == null) return;
    final asked = await showInstructionSheet(
      context,
      title: 'How summaries are written',
      help:
          'This is what the model is told. It applies to every recording you '
          'summarise. Whatever you write, it will only use what you actually '
          'said.',
      hint: defaultSummaryInstruction,
      initial: widget.actions.summaryInstruction ?? defaultSummaryInstruction,
      confirmLabel: 'Save',
      resetLabel: 'Use the standard one',
      resetTo: defaultSummaryInstruction,
    );
    if (asked == null || !mounted) return;
    save(asked.trim().isEmpty ? null : asked);
    // Redoing it is the only way to see what changed, and the dialog cannot
    // watch the note it is written to — so this closes and lets the chip say
    // "Summarising…" as it goes.
    final regenerate = widget.actions.onRegenerateSummary;
    if (regenerate == null) return;
    final redo = await _confirmRedo();
    if (!mounted || !redo) return;
    regenerate();
    Navigator.of(context).maybePop();
  }

  Future<bool> _confirmRedo() async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Write this one again?'),
          content: const Text(
            'The new instructions are saved either way. This rewrites the '
            'summary of this recording with them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not now'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Write it again'),
            ),
          ],
        ),
      ) ??
      false;

  Widget _transcript(CalcPalette palette) {
    final transcript = _ref.transcript!;
    final paragraphs = groupTranscriptParagraphs(transcript.segments);
    final speakers = transcript.speakerIds;
    // One speaker is a memo somebody recorded alone. Labelling every
    // paragraph "Speaker 1" would be the app telling them something they
    // already know, in the place they came to read their own words — so a
    // transcript with nobody to tell apart looks exactly as it always has.
    final named = speakers.length > 1;

    // Precomputed rather than worked out per row: a long recording runs to
    // hundreds of paragraphs and the builder must stay cheap.
    var previous = -1;
    final rows = <_TranscriptRow>[];
    for (final paragraph in paragraphs) {
      final speaker = paragraph.first.speaker;
      rows.add(
        _TranscriptRow(
          paragraph: paragraph,
          speaker: named ? speaker : null,
          startsTurn: named && speaker != null && speaker != previous,
        ),
      );
      previous = speaker ?? -1;
    }

    final list = ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Transcribed · ${transcript.lang}',
              style: TextStyle(fontSize: 11, color: palette.textTertiary),
            ),
          );
        }
        final row = rows[index];
        return Padding(
          padding: EdgeInsets.only(bottom: 12, top: row.startsTurn ? 4 : 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (row.startsTurn)
                Padding(
                  padding: const EdgeInsets.only(left: 48, bottom: 4),
                  child: _SpeakerLabel(
                    name: transcript.nameFor(row.speaker!),
                    color: speakerColor(palette, row.speaker!),
                    onPressed: widget.actions.onChanged == null
                        ? null
                        : () => unawaited(_renameSpeaker(row.speaker!)),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 48,
                    child: Text(
                      formatVoiceDuration(
                        Duration(milliseconds: row.paragraph.first.s),
                      ),
                      style: TextStyle(
                        fontSize: 11,
                        color: palette.textTertiary,
                      ),
                    ),
                  ),
                  Expanded(
                    // SelectableText's own onTap, not a GestureDetector
                    // around it: the selection recognisers inside are deeper
                    // in the arena and win every tap, so the wrapper this
                    // used to have was never called once. Selecting a quote
                    // out of the transcript still works; this is only the
                    // tap.
                    child: SelectableText(
                      row.paragraph
                          .map((segment) => segment.t)
                          .join(' ')
                          .trim(),
                      onTap: () => unawaited(
                        _seekTo(Duration(milliseconds: row.paragraph.first.s)),
                      ),
                      style: TextStyle(color: palette.textPrimary, height: 1.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    if (!named) return list;
    return Column(
      children: [
        _SpeakerBar(
          transcript: transcript,
          speakers: speakers,
          onRename: widget.actions.onChanged == null
              ? null
              : (speaker) => unawaited(_renameSpeaker(speaker)),
        ),
        Expanded(child: list),
      ],
    );
  }

  Future<void> _renameSpeaker(int speaker) async {
    final transcript = _ref.transcript;
    if (transcript == null) return;
    final name = await showSpeakerNameDialog(
      context,
      current: transcript.speakers[speaker] ?? '',
      fallback: 'Speaker ${speaker + 1}',
    );
    if (name == null || !mounted) return;
    _apply(_ref.copyWith(transcript: transcript.renaming(speaker, name)));
  }

  Future<void> _showOverflow() async {
    final actions = widget.actions;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (actions.onTranscribeAgain != null)
              ListTile(
                title: const Text('Transcribe again'),
                onTap: () => Navigator.of(context).pop('again'),
              ),
            if (_onSummary && actions.onRegenerateSummary != null)
              ListTile(
                title: const Text('Regenerate summary'),
                onTap: () => Navigator.of(context).pop('regenerate'),
              ),
            if (actions.onDelete != null)
              ListTile(
                title: const Text('Delete voice note'),
                onTap: () => Navigator.of(context).pop('delete'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'again':
        actions.onTranscribeAgain?.call();
      case 'regenerate':
        actions.onRegenerateSummary?.call();
      case 'delete':
        if (await _confirmDelete()) {
          actions.onDelete?.call();
          if (mounted) Navigator.of(context).maybePop();
        }
    }
  }

  Future<bool> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this voice note?'),
        content: const Text(
          'The recording, transcript and summary are removed from the note.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }
}

/// Groups segments into readable paragraphs.
///
/// A transcript arrives as hundreds of short spans, which is right for seeking
/// and unreadable as prose. Breaks go where a speaker paused for more than a
/// second and a half, or every six segments so a monologue still gets air.
List<List<TranscriptSegment>> groupTranscriptParagraphs(
  List<TranscriptSegment> segments, {
  int gapMs = 1500,
  int maxSegments = 6,
}) {
  final paragraphs = <List<TranscriptSegment>>[];
  var current = <TranscriptSegment>[];
  for (final segment in segments) {
    final tooLong = current.length >= maxSegments;
    final afterPause = current.isNotEmpty && segment.s - current.last.e > gapMs;
    if (tooLong || afterPause) {
      paragraphs.add(current);
      current = <TranscriptSegment>[];
    }
    current.add(segment);
  }
  if (current.isNotEmpty) paragraphs.add(current);
  return paragraphs;
}

String _formatDate(DateTime at) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${at.day} ${months[at.month - 1]} ${at.year}';
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle, this.onClose});

  final String title;
  final String subtitle;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 12, color: palette.textSecondary),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 18),
            tooltip: 'Close',
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// Play, scrub, elapsed/total, and the speed cycle.
class VoiceNotePlayerRow extends StatefulWidget {
  const VoiceNotePlayerRow({
    super.key,
    required this.ref,
    required this.blobs,
    this.player,
  });

  final NoteVoiceRef ref;
  final BlobStore blobs;
  final VoicePlayer? player;

  @override
  State<VoiceNotePlayerRow> createState() => _VoiceNotePlayerRowState();
}

class _VoiceNotePlayerRowState extends State<VoiceNotePlayerRow> {
  static const List<double> _speeds = [1, 1.5, 2];

  /// Where the thumb has been dragged to on a recording that is not playing.
  ///
  /// A slider needs somewhere to put the value while the finger is down, and
  /// on an untouched recording there is no play head to put it in yet.
  double? _scrubbing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final player = widget.player;
    if (player == null) return const SizedBox(height: 8);

    // Two listeners, because they move at different rates. The outer one is
    // play, pause, speed and which recording is loaded — a handful of events.
    // The inner one is the play head, four times a second, and it rebuilds
    // this row alone rather than everything watching the player.
    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final active = player.activeHash == widget.ref.hash;
        final total = active
            ? (player.duration ?? widget.ref.duration)
            : widget.ref.duration;
        return ValueListenableBuilder<Duration>(
          valueListenable: player.positionListenable,
          builder: (context, head, _) {
            final position = active ? head : Duration.zero;
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(
                      player.isPlaying(widget.ref.hash)
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                    ),
                    tooltip: player.isPlaying(widget.ref.hash)
                        ? 'Pause'
                        : 'Play',
                    onPressed: _toggle,
                  ),
                  Expanded(
                    child: Slider(
                      value:
                          _scrubbing ??
                          (total.inMilliseconds == 0
                              ? 0
                              : (position.inMilliseconds / total.inMilliseconds)
                                    .clamp(0.0, 1.0)),
                      // Scrubbing a recording nobody has started is a request to
                      // hear it from there, which is worth more than a disabled
                      // slider. It only becomes one on release, so a drag does not
                      // restart playback on every frame of itself.
                      onChanged: active
                          ? (value) => player.seek(total * value)
                          : (value) => setState(() => _scrubbing = value),
                      onChangeEnd: active
                          ? null
                          : (value) {
                              setState(() => _scrubbing = null);
                              unawaited(_start(from: total * value));
                            },
                    ),
                  ),
                  Text(
                    '${formatVoiceDuration(_scrubbing == null ? position : total * _scrubbing!)}'
                    ' / ${formatVoiceDuration(total)}',
                    style: TextStyle(
                      fontSize: 11,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: palette.textSecondary,
                    ),
                  ),
                  TextButton(
                    onPressed: () {
                      final next =
                          _speeds[(_speeds.indexOf(player.speed) + 1) %
                              _speeds.length];
                      player.setSpeed(next);
                    },
                    child: Text('${_trim(player.speed)}×'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  static String _trim(double speed) =>
      speed == speed.roundToDouble() ? speed.toStringAsFixed(0) : '$speed';

  Future<void> _toggle() async {
    final player = widget.player;
    if (player == null) return;
    if (player.isPlaying(widget.ref.hash)) {
      await player.pause();
      return;
    }
    await _start();
  }

  Future<void> _start({Duration? from}) async {
    final player = widget.player;
    if (player == null) return;
    final file = await widget.blobs.fileFor(widget.ref.hash);
    if (file == null) return;
    await player.play(widget.ref.hash, file, from: from);
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({
    required this.onSummary,
    required this.hasSummary,
    required this.onChanged,
  });

  final bool onSummary;
  final bool hasSummary;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    Widget tab(String label, bool selected, VoidCallback onTap) => Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                width: 2,
                color: selected ? palette.textPrimary : Colors.transparent,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: selected ? palette.textPrimary : palette.textSecondary,
            ),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          tab('Summary', onSummary, () => onChanged(true)),
          tab('Transcript', !onSummary, () => onChanged(false)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.message,
    this.caption,
    this.actionLabel,
    this.onAction,
    this.busy = false,
  });

  final String message;
  final String? caption;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: palette.textSecondary),
            ),
            if (busy) ...[
              const SizedBox(height: 16),
              const SizedBox(
                width: 160,
                child: LinearProgressIndicator(minHeight: 2),
              ),
            ],
            if (caption != null) ...[
              const SizedBox(height: 8),
              Text(
                caption!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: palette.textTertiary),
              ),
            ],
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 12),
              TextButton(onPressed: onAction, child: Text(actionLabel!)),
            ],
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({this.onInsert, this.onMenu});

  final VoidCallback? onInsert;
  final VoidCallback? onMenu;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Row(
        children: [
          TextButton(
            onPressed: onInsert,
            child: const Text('Insert into note'),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded, size: 20),
            tooltip: 'More',
            onPressed: onMenu,
          ),
        ],
      ),
    );
  }
}

/// One paragraph of the transcript, and whether it opens somebody's turn.
///
/// Worked out once for the whole transcript rather than in the builder: a
/// long recording runs to hundreds of these and a list that recomputes who
/// spoke last on every scroll frame is a list that stutters.
class _TranscriptRow {
  const _TranscriptRow({
    required this.paragraph,
    required this.speaker,
    required this.startsTurn,
  });

  final List<TranscriptSegment> paragraph;
  final int? speaker;
  final bool startsTurn;
}

/// A colour per speaker, from the palette the app already has.
///
/// Reuses the chip colours rather than inventing new ones, so a transcript
/// looks like the rest of the app in both themes and nobody has to pick five
/// more colours that work on paper and in the dark.
Color speakerColor(CalcPalette palette, int speaker) {
  final wheel = [
    palette.chipNumber,
    palette.chipCurrency,
    palette.chipUnit,
    palette.chipBoolean,
    palette.chipOther,
  ];
  return wheel[speaker % wheel.length];
}

/// Says how many people are in the recording, and offers their names.
///
/// Only ever shown when there is more than one, because that is the only
/// case where any of it is news.
class _SpeakerBar extends StatelessWidget {
  const _SpeakerBar({
    required this.transcript,
    required this.speakers,
    this.onRename,
  });

  final VoiceTranscript transcript;
  final List<int> speakers;
  final void Function(int speaker)? onRename;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.separator)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${speakers.length} speakers',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final speaker in speakers)
                _SpeakerLabel(
                  name: transcript.nameFor(speaker),
                  color: speakerColor(palette, speaker),
                  onPressed: onRename == null ? null : () => onRename!(speaker),
                ),
            ],
          ),
          if (onRename != null) ...[
            const SizedBox(height: 8),
            Text(
              'Tap a name to change it.',
              style: TextStyle(fontSize: 11, color: palette.textTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

/// A speaker's name, with the dot that ties it to their paragraphs.
class _SpeakerLabel extends StatelessWidget {
  const _SpeakerLabel({
    required this.name,
    required this.color,
    this.onPressed,
  });

  final String name;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          name,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: palette.textSecondary,
          ),
        ),
      ],
    );
    if (onPressed == null) return label;
    return Semantics(
      button: true,
      label: 'Rename $name',
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: label,
        ),
      ),
    );
  }
}

/// A quiet text action, for things beside a caption rather than under it.
class _QuietButton extends StatelessWidget {
  const _QuietButton({required this.label, this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: palette.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// One thing the transcript can be turned into.
class _RewriteChip extends StatelessWidget {
  const _RewriteChip({required this.label, required this.busy, this.onPressed});

  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: palette.controlBackground,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: palette.controlBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy) ...[
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: palette.textTertiary,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: enabled ? palette.textPrimary : palette.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A post the model wrote, ready to be copied out.
class _TakeCard extends StatelessWidget {
  const _TakeCard({
    required this.take,
    required this.onCopy,
    required this.onRemove,
    this.onAgain,
  });

  final VoiceTake take;
  final VoidCallback onCopy;
  final VoidCallback onRemove;
  final VoidCallback? onAgain;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 12),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.controlBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  take.kind.label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: palette.textSecondary,
                  ),
                ),
              ),
              if (onAgain != null)
                IconButton(
                  onPressed: onAgain,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Write it again',
                  icon: Icon(
                    Icons.refresh,
                    size: 16,
                    color: palette.textTertiary,
                  ),
                ),
              IconButton(
                onPressed: onCopy,
                visualDensity: VisualDensity.compact,
                tooltip: 'Copy',
                icon: Icon(
                  Icons.copy_all_outlined,
                  size: 16,
                  color: palette.textTertiary,
                ),
              ),
              IconButton(
                onPressed: onRemove,
                visualDensity: VisualDensity.compact,
                tooltip: 'Remove',
                icon: Icon(Icons.close, size: 16, color: palette.textTertiary),
              ),
            ],
          ),
          // The instruction, so a card somebody comes back to still says what
          // was asked for. Only the custom ones carry it; a preset would only
          // be repeating its own label.
          if (take.instruction case final String asked) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                asked,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontStyle: FontStyle.italic,
                  color: palette.textTertiary,
                ),
              ),
            ),
          ],
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: SelectableText(
              take.text,
              style: TextStyle(color: palette.textPrimary, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for a name for one speaker.
///
/// An empty answer clears the name rather than storing an empty one, so
/// somebody who changes their mind gets the number back.
Future<String?> showSpeakerNameDialog(
  BuildContext context, {
  required String current,
  required String fallback,
}) {
  final controller = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Who is this?'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 40,
        decoration: InputDecoration(hintText: fallback, counterText: ''),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('Clear'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Asks for an instruction, in the user's own words.
///
/// Shared by the two places that need one — how summaries are written, and a
/// one-off rewrite — because they differ only in their words. The field is
/// pre-filled with what is actually in use rather than a description of it,
/// so editing one line does what it looks like it does.
Future<String?> showInstructionSheet(
  BuildContext context, {
  required String title,
  required String help,
  required String hint,
  required String initial,
  required String confirmLabel,
  String? resetLabel,
  String? resetTo,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) {
      final palette = context.palette;
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                help,
                style: TextStyle(fontSize: 12, color: palette.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: 4,
                maxLines: 8,
                maxLength: instructionMaxChars,
                decoration: InputDecoration(
                  hintText: hint,
                  border: const OutlineInputBorder(),
                  counterText: '',
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (resetLabel != null && resetTo != null)
            TextButton(
              onPressed: () => controller.text = resetTo,
              child: Text(resetLabel),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
}
