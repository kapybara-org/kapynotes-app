import 'dart:async';
import 'dart:math';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../audio/noise_removals.dart';
import '../audio/voice_export.dart';
import '../audio/voice_player.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../core/toast.dart';
import '../data/note_attachment.dart';
import '../data/voice_prefs.dart' show speechLanguages;
import '../speech/moments.dart';
import '../speech/summary_instructions.dart';
import 'context_menu.dart';
import 'editor/voice_chip.dart';
import 'settings_rows.dart' show SettingsPie, SettingsSegmented;
import 'tag_colours.dart';
import 'tonal_button.dart';
import 'voice_note_ask.dart';

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
    this.ask,
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
  /// changes — its title, a speaker's name, a post it just wrote, a post being
  /// thrown away — is the same operation: this ref replaces the one on the
  /// note.
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

  /// Kapy AI, for questions about the recording. Null where it is off.
  final VoiceAskActions? ask;
}

/// Opens a recording: a dialog on desktop, a tall sheet on a phone.
///
/// The split follows `openSettingsDialog`, so a recording opens the same way
/// everything else in the app does.
Future<void> openVoiceNoteDialog(
  BuildContext context, {
  required NoteVoiceRef ref,
  required VoiceChipState state,
  VoicePlayer? player,
  VoiceNoteActions actions = const VoiceNoteActions(),
  DateTime? recordedAt,
}) {
  Widget build({required bool asSheet}) => VoiceNoteView(
    ref: ref,
    state: state,
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
    this.player,
    this.actions = const VoiceNoteActions(),
    this.recordedAt,
    this.asSheet = false,
  });

  final NoteVoiceRef ref;
  final VoiceChipState state;
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
    await player.play(widget.ref.hash, from: position);
  }

  late bool _onSummary;

  /// The recording as this dialog has it, which is ahead of the note for as
  /// long as the dialog is open.
  ///
  /// The dialog is a route: it is built once with a ref and is not rebuilt
  /// when the note changes underneath. Renaming it, naming a speaker or
  /// writing a post has to show up immediately, so the edit is made here and
  /// handed to [VoiceNoteActions.onChanged] to persist.
  late NoteVoiceRef _live;

  /// The transcript as rows, and when each summary point was said, worked
  /// out once per transcript and summary rather than on every build: a long
  /// recording runs to hundreds of paragraphs.
  VoiceTranscript? _laidOut;
  List<_TranscriptRow> _rows = const [];
  List<GlobalKey> _rowKeys = const [];
  VoiceSummary? _timed;
  VoiceTranscript? _timedFrom;
  List<Duration?> _moments = const [];

  /// The row the play head is in, lit while this recording is loaded.
  int? _playingRow;

  /// The rows the answer in Ask's drawer draws on, edged in green.
  Set<int> _cited = const {};
  final ScrollController _transcriptScroll = ScrollController();

  /// Search in the transcript: each match is a row and where in its text.
  bool _searching = false;
  final TextEditingController _query = TextEditingController();
  List<({int row, int start})> _matches = const [];
  int _match = 0;
  int _needle = 0;

  @override
  void initState() {
    super.initState();
    _live = widget.ref;
    // Opens on whichever side has something to read. Not remembered between
    // openings: a rule you can predict beats one that is merely sticky.
    _onSummary = widget.ref.summary != null;
    final player = widget.player;
    if (player == null) return;
    if (widget.ref.transcript case final transcript?) {
      player.setPauses(widget.ref.hash, pausesIn(transcript.segments));
    }
    player.addListener(_followPlayer);
    player.positionListenable.addListener(_followPlayer);
    _playingRow = _rowPlaying();
  }

  @override
  void dispose() {
    widget.player?.removeListener(_followPlayer);
    widget.player?.positionListenable.removeListener(_followPlayer);
    _transcriptScroll.dispose();
    _query.dispose();
    super.dispose();
  }

  NoteVoiceRef get _ref => _live;

  /// Applies an edit here and on the note, in that order.
  void _apply(NoteVoiceRef next) {
    setState(() => _live = next);
    widget.actions.onChanged?.call(next);
  }

  List<_TranscriptRow> _layout() {
    final transcript = _ref.transcript;
    if (identical(transcript, _laidOut) && _rowKeys.length == _rows.length) {
      return _rows;
    }
    _laidOut = transcript;
    final rows = <_TranscriptRow>[];
    if (transcript != null) {
      // One speaker is a memo somebody recorded alone. Labelling every
      // paragraph "Speaker 1" would be the app telling them something they
      // already know, so a transcript with nobody to tell apart has no
      // labels at all.
      final named = transcript.speakerIds.length > 1;
      int? previous;
      for (final paragraph in groupTranscriptParagraphs(transcript.segments)) {
        final speaker = named ? paragraph.first.speaker : null;
        rows.add(
          _TranscriptRow(
            paragraph: paragraph,
            text: paragraph.map((segment) => segment.t).join(' ').trim(),
            speaker: speaker,
            startsTurn: speaker != null && speaker != previous,
          ),
        );
        previous = speaker;
      }
    }
    _rows = rows;
    _rowKeys = [for (final _ in rows) GlobalKey()];
    return rows;
  }

  List<Duration?> _summaryMoments() {
    final summary = _ref.summary;
    if (summary == null) return const [];
    final transcript = _ref.transcript;
    if (identical(summary, _timed) && identical(transcript, _timedFrom)) {
      return _moments;
    }
    final paragraphs = [for (final row in _layout()) row.paragraph];
    _timed = summary;
    _timedFrom = transcript;
    _moments = [
      for (final point in summary.points) momentFor(point, paragraphs),
    ];
    return _moments;
  }

  /// The row the play head is in, or null when this recording is not the
  /// one loaded.
  int? _rowPlaying() {
    final player = widget.player;
    if (player == null || player.activeHash != _ref.hash) return null;
    final at = player.position.inMilliseconds;
    int? found;
    for (final (index, row) in _layout().indexed) {
      if (row.paragraph.first.s > at) break;
      found = index;
    }
    return found;
  }

  /// Lights the row being played, and keeps it in view while it plays.
  void _followPlayer() {
    if (!mounted) return;
    final row = _rowPlaying();
    if (row == _playingRow) return;
    setState(() => _playingRow = row);
    if (row != null && !_onSummary && widget.player!.isPlaying(_ref.hash)) {
      _reveal(row);
    }
  }

  /// Scrolls [row] into view when it is not wholly in view already. A row
  /// the list has not built yet is jumped near first, by its share of the
  /// list, and found exactly on the next frame.
  void _reveal(int row, {bool near = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_transcriptScroll.hasClients) return;
      if (row >= _rowKeys.length) return;
      final position = _transcriptScroll.position;
      final box = _rowKeys[row].currentContext?.findRenderObject();
      if (box is! RenderBox) {
        if (near) return;
        position.jumpTo(
          (position.maxScrollExtent * row / _rowKeys.length).clamp(
            0.0,
            position.maxScrollExtent,
          ),
        );
        _reveal(row, near: true);
        return;
      }
      final viewport = RenderAbstractViewport.of(box);
      final top = viewport.getOffsetToReveal(box, 0).offset;
      final bottom = viewport.getOffsetToReveal(box, 1).offset;
      if (position.pixels >= bottom && position.pixels <= top) return;
      unawaited(
        position.animateTo(
          (top - position.viewportDimension * 0.2).clamp(
            0.0,
            position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _search(String text) {
    final needle = text.trim().toLowerCase();
    final found = <({int row, int start})>[];
    if (needle.isNotEmpty) {
      for (final (index, row) in _layout().indexed) {
        final said = row.text.toLowerCase();
        // A letter whose lower case is longer would put the highlight in
        // the wrong place, so such a paragraph is left out.
        if (said.length != row.text.length) continue;
        for (var at = said.indexOf(needle); at >= 0;) {
          found.add((row: index, start: at));
          at = said.indexOf(needle, at + needle.length);
        }
      }
    }
    setState(() {
      _matches = found;
      _match = 0;
      _needle = needle.length;
    });
    if (found.isNotEmpty) _reveal(found.first.row);
  }

  void _step(int by) {
    if (_matches.isEmpty) return;
    setState(() => _match = (_match + by) % _matches.length);
    _reveal(_matches[_match].row);
  }

  void _closeSearch() {
    _query.clear();
    setState(() {
      _searching = false;
      _matches = const [];
      _needle = 0;
    });
  }

  /// The summary as bullet lines, or the transcript as paragraphs: what
  /// Insert puts in the note and Copy puts on the clipboard.
  String? _textOf({required bool summary}) {
    if (summary) {
      return _ref.summary?.points.map((point) => '• $point').join('\n');
    }
    final lines = [
      for (final row in _layout())
        if (row.text.isNotEmpty) row.text,
    ];
    return lines.isEmpty ? null : lines.join('\n');
  }

  String get _title => _ref.summary?.title ?? 'Voice note';

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final insertable = _textOf(summary: _onSummary);
    final insert = widget.actions.onInsert;
    final ask = widget.actions.ask;
    final posting = widget.actions.onRewrite != null && _ref.transcript != null;
    final top = _pageTop();
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          title: _title,
          subtitle: _subtitle(),
          onMore: (anchor) => unawaited(_showMore(anchor)),
          onClose: () => Navigator.of(context).maybePop(),
        ),
        VoiceNotePlayerRow(ref: _ref, player: widget.player),
        _SwitchRow(
          onSummary: _onSummary,
          onChanged: (summary) {
            if (summary) _closeSearch();
            setState(() => _onSummary = summary);
          },
          onSearch: _onSummary || _layout().isEmpty || _searching
              ? null
              : () => setState(() => _searching = true),
          insertLabel: _onSummary ? 'Insert summary' : 'Insert transcript',
          onInsert: insertable == null || insert == null
              ? null
              : () {
                  insert(insertable);
                  Navigator.of(context).maybePop();
                },
        ),
        Expanded(
          child: ask == null && !posting
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ?top,
                    Expanded(child: _content(palette)),
                  ],
                )
              : VoiceAsk(
                  actions: ask,
                  ref: _ref,
                  top: top,
                  page: _content(palette),
                  unavailable: ask == null ? null : _askUnavailable(ask),
                  compact: widget.asSheet,
                  summaryInView: _onSummary,
                  onPlay: (at) => unawaited(_seekTo(at)),
                  onCited: _cite,
                  onInsert: insert == null
                      ? null
                      : (text) {
                          insert(text);
                          Navigator.of(context).maybePop();
                        },
                  onCopy: (text) => unawaited(_copy(text)),
                  onWrite: posting ? _write : null,
                  onRemove: widget.actions.onChanged == null
                      ? null
                      : (take) => _apply(_ref.withoutTake(take)),
                ),
        ),
      ],
    );

    if (widget.asSheet) {
      // The keyboard lifts the whole sheet, so Ask's bar stays above it.
      final keyboard = MediaQuery.viewInsetsOf(context).bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: keyboard),
        child: FractionallySizedBox(
          heightFactor: 0.92,
          child: Container(
            decoration: BoxDecoration(
              color: palette.surfaceBackground,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
            ),
            child: SafeArea(top: false, bottom: keyboard == 0, child: body),
          ),
        ),
      );
    }
    return Dialog(
      backgroundColor: palette.surfaceBackground,
      child: SizedBox(width: 620, height: 640, child: body),
    );
  }

  /// Why Ask can't take a question about this recording, said in its bar,
  /// or null when it can.
  String? _askUnavailable(VoiceAskActions ask) {
    if (ask.hidden) return "Kapy AI doesn't read hidden notes";
    if (_ref.transcript?.segments.isNotEmpty ?? false) return null;
    return switch (widget.state) {
      VoiceChipState.transcribing ||
      VoiceChipState.waiting ||
      VoiceChipState.retrying => 'Ask once the transcript is ready',
      _ => 'Ask needs a transcript',
    };
  }

  /// Edges the rows an answer draws on, and on a computer brings the first
  /// of them into view on the transcript.
  void _cite(List<Duration> moments) {
    final starts = {for (final at in moments) at.inMilliseconds};
    final rows = {
      for (final (index, row) in _layout().indexed)
        if (starts.contains(row.paragraph.first.s)) index,
    };
    setState(() {
      _cited = rows;
      if (rows.isNotEmpty && !widget.asSheet) _onSummary = false;
    });
    if (rows.isEmpty || widget.asSheet) return;
    _reveal(rows.reduce(min));
  }

  /// "Wed 19 Nov · 8:55 · 2:03": the day and time it was recorded, with the
  /// year only when it is not this one, then how long it runs.
  String _subtitle() {
    final duration = formatVoiceDuration(_ref.duration);
    final at = widget.recordedAt;
    if (at == null) return duration;
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
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
    final year = at.year == DateTime.now().year ? '' : ' ${at.year}';
    final minute = at.minute.toString().padLeft(2, '0');
    return '${weekdays[at.weekday - 1]} ${at.day} ${months[at.month - 1]}'
        '$year · ${at.hour}:$minute · $duration';
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
      VoiceChipState.needsConsent when _ref.transcript == null => _Empty(
        message: 'Turn on transcription to create text and a summary.',
        actionLabel: 'Turn on',
        onAction: actions.onTurnOnTranscription,
      ),
      VoiceChipState.needsAccount when _ref.transcript == null => _Empty(
        message: 'Choose cloud or local transcription in Settings.',
        actionLabel: actions.onTurnOnTranscription != null
            ? 'Turn on transcription'
            : null,
        onAction: actions.onTurnOnTranscription,
      ),
      VoiceChipState.outOfMinutes => const _Empty(
        message: 'Monthly transcription limit reached.',
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
        message: 'Waiting to connect…',
      ),
      VoiceChipState.retrying => const _Empty(
        message: 'Transcription failed. Retrying soon…',
      ),
      VoiceChipState.failed => _Empty(
        message: _ref.transcript == null
            ? "Couldn't transcribe this recording."
            : "Couldn't summarise this recording.",
        caption: actions.failureReason,
        actionLabel: _ref.transcript == null ? 'Retry' : 'Try summary again',
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
    final moments = _summaryMoments();
    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 20),
      children: [
        for (final (index, point) in summary.points.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 8,
                  child: Text(
                    '•',
                    style: _reading.copyWith(color: palette.textTertiary),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: SelectableText(
                    point,
                    style: _reading.copyWith(color: palette.textPrimary),
                  ),
                ),
                if (moments[index] case final at?) ...[
                  const SizedBox(width: 10),
                  _MomentTime(at: at, onPlay: () => unawaited(_seekTo(at))),
                ],
              ],
            ),
          ),
        const SizedBox(height: 2),
        // Says where the summary came from, and — in the same breath — that
        // how it is written is something the reader chose and can change.
        // The setting is here rather than only in Settings because this is
        // where somebody decides they wanted a different kind of summary.
        Row(
          children: [
            Expanded(
              child: Text(
                'Written from the transcript',
                style: TextStyle(
                  fontSize: AppTypeScale.caption,
                  color: palette.textTertiary,
                ),
              ),
            ),
            if (widget.actions.onSaveSummaryInstruction != null)
              _QuietButton(
                label: 'Instructions',
                icon: KapyIcons.slidersRounded,
                onPressed: () => unawaited(_editSummaryInstruction()),
              ),
          ],
        ),
      ],
    );
  }

  void _say(String message) => ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(message)));

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    _say('Copied');
  }

  /// Writes a post from the transcript the way takes always have been, and
  /// keeps it on the recording.
  Future<VoiceTake> _write(VoiceTakeKind kind, String? instruction) async {
    final transcript = _ref.transcript!;
    final text = await widget.actions.onRewrite!(
      instructionFor(kind, custom: instruction),
    );
    final take = VoiceTake(
      kind: kind,
      text: text,
      engine: _ref.summary?.engine ?? transcript.engine,
      at: DateTime.now().millisecondsSinceEpoch,
      instruction: kind == VoiceTakeKind.custom ? instruction : null,
    );
    if (mounted) _apply(_ref.withTake(take));
    return take;
  }

  /// Changes how every summary from now on is written.
  Future<void> _editSummaryInstruction() async {
    final save = widget.actions.onSaveSummaryInstruction;
    if (save == null) return;
    final asked = await showInstructionSheet(
      context,
      title: 'Summary instructions',
      help:
          'These instructions apply to every recording. Summaries only use '
          'the transcript.',
      hint: defaultSummaryInstruction,
      initial: widget.actions.summaryInstruction ?? defaultSummaryInstruction,
      confirmLabel: 'Save',
      resetLabel: 'Restore default',
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
          title: const Text('Regenerate this summary?'),
          content: const Text(
            'Your new instructions are already saved. Regenerate this summary '
            'to apply them now.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Later'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Regenerate'),
            ),
          ],
        ),
      ) ??
      false;

  Widget _transcript(CalcPalette palette) {
    final transcript = _ref.transcript!;
    final rows = _layout();
    final rename = widget.actions.onChanged == null
        ? null
        : (int speaker) => unawaited(_renameSpeaker(speaker));
    return ListView.builder(
      controller: _transcriptScroll,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
            child: Text(
              'Transcribed · ${_languageName(transcript.lang)}',
              style: TextStyle(
                fontSize: AppTypeScale.caption,
                color: palette.textTertiary,
              ),
            ),
          );
        }
        final row = rows[index];
        final lit = index == _playingRow;
        final cited = _cited.contains(index);
        final start = Duration(milliseconds: row.paragraph.first.s);
        return Container(
          key: _rowKeys[index],
          margin: EdgeInsets.only(
            top: row.startsTurn && index > 0 ? 4 : 0,
            bottom: 4,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: lit
                ? palette.accent.withValues(alpha: 0.13)
                : cited
                ? palette.accent.withValues(alpha: 0.06)
                : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (row.startsTurn)
                Padding(
                  padding: const EdgeInsets.only(left: 46, bottom: 3),
                  child: _SpeakerLabel(
                    name: transcript.nameFor(row.speaker!),
                    color: speakerColor(palette, row.speaker!),
                    onPressed: rename == null
                        ? null
                        : () => rename(row.speaker!),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    // A cited row gives ten of these to its green edge, so
                    // its words stay in line with the rest.
                    width: cited ? 36 : 46,
                    child: Text(
                      formatVoiceDuration(start),
                      style: TextStyle(
                        fontSize: AppTypeScale.caption,
                        height: 20 / AppTypeScale.caption,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        fontWeight: AppWeight.font(
                          lit ? AppWeight.semibold : AppWeight.regular,
                        ),
                        fontVariations: AppWeight.wght(
                          lit ? AppWeight.semibold : AppWeight.regular,
                        ),
                        color: lit || cited
                            ? palette.accentText
                            : palette.textTertiary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      padding: EdgeInsets.only(left: cited ? 8 : 0),
                      decoration: cited
                          ? BoxDecoration(
                              border: Border(
                                left: BorderSide(
                                  color: palette.accent,
                                  width: 2,
                                ),
                              ),
                            )
                          : null,
                      // SelectableText's own onTap, not a GestureDetector
                      // around it: the selection recognisers inside are
                      // deeper in the arena and win every tap. Selecting a
                      // quote out of the transcript still works; this is
                      // only the tap.
                      child: SelectableText.rich(
                        _marked(row.text, index, palette),
                        onTap: () => unawaited(_seekTo(start)),
                        style: _reading.copyWith(color: palette.textPrimary),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// The transcript's search and speakers rows, which stay whole above Ask's
  /// drawer at its tallest. Null when the page has neither.
  Widget? _pageTop() {
    if (_onSummary || _emptyState() != null) return null;
    final transcript = _ref.transcript!;
    final speakers = transcript.speakerIds;
    if (!_searching && speakers.length < 2) return null;
    final rename = widget.actions.onChanged == null
        ? null
        : (int speaker) => unawaited(_renameSpeaker(speaker));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_searching)
          _SearchBar(
            controller: _query,
            matches: _matches.length,
            current: _match,
            searched: _needle > 0,
            onChanged: _search,
            onStep: _step,
            onClose: _closeSearch,
          ),
        if (speakers.length > 1)
          _SpeakerBar(
            transcript: transcript,
            speakers: speakers,
            onRename: rename,
          ),
      ],
    );
  }

  /// [text] with this row's search matches marked, the current one more so.
  TextSpan _marked(String text, int row, CalcPalette palette) {
    if (_needle == 0) return TextSpan(text: text);
    final spans = <TextSpan>[];
    var from = 0;
    for (final (index, match) in _matches.indexed) {
      if (match.row != row || match.start < from) continue;
      spans
        ..add(TextSpan(text: text.substring(from, match.start)))
        ..add(
          TextSpan(
            text: text.substring(match.start, match.start + _needle),
            style: TextStyle(
              backgroundColor: palette.accent.withValues(
                alpha: index == _match ? 0.55 : 0.25,
              ),
            ),
          ),
        );
      from = match.start + _needle;
    }
    spans.add(TextSpan(text: text.substring(from)));
    return TextSpan(children: spans);
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

  /// More: a menu under the button on a computer, a sheet on a phone.
  Future<void> _showMore(BuildContext anchor) async {
    final actions = widget.actions;
    final player = widget.player;
    final summary = _ref.summary;
    final phone = AppPlatform.isMobile;
    final KapyMenu menu = (
      heading: null,
      groups: [
        [
          if (summary != null && actions.onChanged != null)
            const KapyMenuAction(
              value: 'rename',
              label: 'Rename',
              icon: KapyIcons.pencilEditRounded,
            ),
          if (summary != null)
            const KapyMenuAction(
              value: 'copy-summary',
              label: 'Copy summary',
              icon: KapyIcons.copyRounded,
            ),
          if (_textOf(summary: false) != null)
            const KapyMenuAction(
              value: 'copy-transcript',
              label: 'Copy transcript',
              icon: KapyIcons.copyRounded,
            ),
          if (player != null)
            const KapyMenuAction(
              value: 'audio',
              label: 'Save audio…',
              icon: KapyIcons.downloadRounded,
            ),
        ],
        [
          if (player != null && _ref.transcript != null)
            KapyMenuAction(
              value: 'skip',
              label: 'Skip pauses',
              icon: KapyIcons.forwardRounded,
              checked: player.skipPauses,
            ),
        ],
        [
          if (actions.onTranscribeAgain != null)
            const KapyMenuAction(
              value: 'again',
              label: 'Transcribe again',
              icon: KapyIcons.refreshOutlined,
            ),
          if (summary != null && actions.onRegenerateSummary != null)
            const KapyMenuAction(
              value: 'regenerate',
              label: 'Regenerate summary',
              icon: KapyIcons.refreshOutlined,
            ),
        ],
        [
          if (actions.onDelete != null)
            const KapyMenuAction(
              value: 'delete',
              label: 'Delete voice note',
              icon: KapyIcons.deleteOutlined,
              destructive: true,
            ),
        ],
      ],
    );
    if (menu.groups.every((group) => group.isEmpty)) return;

    final String? choice;
    if (phone) {
      choice = await _showMoreSheet(menu);
    } else {
      final button = anchor.findRenderObject()! as RenderBox;
      choice = await showKapyContextMenu<String>(
        context: context,
        // Its right edge under the button's, so it opens over the window
        // rather than off its side.
        globalPosition: button.localToGlobal(
          button.size.bottomRight(Offset.zero) + const Offset(0, 4),
        ),
        preferredGlobalBounds: Offset.zero & MediaQuery.sizeOf(context),
        items: kapyMenuItems(menu, key: (value) => 'voice-more-$value'),
      );
    }
    if (!mounted) return;
    switch (choice) {
      case 'rename':
        await _rename();
      case 'copy-summary':
        await _copy(_textOf(summary: true)!);
      case 'copy-transcript':
        await _copy(_textOf(summary: false)!);
      case 'audio':
        await _exportAudio();
      case 'skip':
        player!.setSkipPauses(!player.skipPauses);
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

  Future<String?> _showMoreSheet(KapyMenu menu) => showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
    builder: (sheetContext) {
      final palette = sheetContext.palette;
      final groups = menu.groups.where((group) => group.isNotEmpty).toList();
      return DecoratedBox(
        decoration: BoxDecoration(
          color: palette.surfaceBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadii.surface),
          ),
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.body,
                      fontWeight: AppWeight.font(AppWeight.regular),
                      fontVariations: AppWeight.wght(AppWeight.regular),
                      color: palette.textPrimary,
                    ),
                  ),
                ),
                for (final (index, group) in groups.indexed) ...[
                  if (index > 0)
                    Divider(height: 9, indent: 20, color: palette.separator),
                  for (final action in group)
                    InkWell(
                      key: ValueKey('voice-more-${action.value}'),
                      onTap: () => Navigator.of(sheetContext).pop(action.value),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        child: KapyMenuActionRow(action, touch: true),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
      );
    },
  );

  /// Names the recording. Kept as the summary's title, under a mark that
  /// stops a summary written again from replacing it.
  Future<void> _rename() async {
    final summary = _ref.summary;
    if (summary == null) return;
    final asked = await showRenameDialog(context, current: summary.title);
    final title = asked?.trim();
    if (!mounted || title == null || title.isEmpty || title == summary.title) {
      return;
    }
    _apply(_ref.copyWith(summary: summary.withTitle(title)));
  }

  Future<void> _exportAudio() async {
    final player = widget.player;
    if (player == null) return;
    final outcome = await exportVoiceAudio(
      locate: () => player.fileFor(_ref.hash),
      title: _title,
    );
    if (!mounted) return;
    switch (outcome) {
      case VoiceExportOutcome.done || VoiceExportOutcome.cancelled:
        return;
      case VoiceExportOutcome.notDownloaded:
        _say(
          "The audio isn't on this device yet. Try again once you're online.",
        );
      case VoiceExportOutcome.failed:
        _say("Couldn't save the audio. Try again.");
    }
  }

  Future<bool> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this voice note?'),
        content: const Text('Removes the audio, transcript, and summary.'),
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

const TextStyle _reading = TextStyle(fontSize: 13.5, height: 20 / 13.5);

/// "English" for "en": a transcript's language by name where the app has
/// one, its code otherwise.
String _languageName(String code) =>
    speechLanguages[code.split(RegExp('[-_]')).first.toLowerCase()] ?? code;

class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    required this.subtitle,
    required this.onMore,
    required this.onClose,
  });

  final String title;
  final String subtitle;

  /// Handed the button, which the menu opens under.
  final void Function(BuildContext button) onMore;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final extent = AppPlatform.hasPointer ? 28.0 : 40.0;
    Widget button(KapyIconData icon, String tooltip, VoidCallback onPressed) =>
        IconButton(
          icon: KapyIcon(icon, size: 18),
          tooltip: tooltip,
          color: palette.textSecondary,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tightFor(width: extent, height: extent),
          style: IconButton.styleFrom(
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onPressed: onPressed,
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 18, 14, 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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
                    fontSize: 17,
                    height: 22 / 17,
                    fontWeight: AppWeight.font(AppWeight.semibold),
                    fontVariations: AppWeight.wght(AppWeight.semibold),
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption,
                    color: palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Builder(
            builder: (context) => button(
              KapyIcons.moreHorizontalRounded,
              'More',
              () => onMore(context),
            ),
          ),
          const SizedBox(width: 2),
          button(KapyIcons.closeRounded, 'Close', onClose),
        ],
      ),
    );
  }
}

/// Play, the waveform to scrub, elapsed / total, and the speed.
///
/// On a computer it is one row. On a phone the waveform takes the row beside
/// the button, and the time and speed go under it.
class VoiceNotePlayerRow extends StatefulWidget {
  const VoiceNotePlayerRow({super.key, required this.ref, this.player});

  final NoteVoiceRef ref;
  final VoicePlayer? player;

  @override
  State<VoiceNotePlayerRow> createState() => _VoiceNotePlayerRowState();
}

class _VoiceNotePlayerRowState extends State<VoiceNotePlayerRow> {
  static const List<double> _speeds = [1, 1.5, 2];

  /// Where the waveform has been dragged to on a recording that is not
  /// loaded. It only starts on release, so a drag does not restart playback
  /// on every frame of itself.
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
        final playing = player.isPlaying(widget.ref.hash);
        final opening = player.isOpening(widget.ref.hash);
        final failure = player.failureFor(widget.ref.hash);
        final total = active
            ? (player.duration ?? widget.ref.duration)
            : widget.ref.duration;
        return ValueListenableBuilder<Duration>(
          valueListenable: player.positionListenable,
          builder: (context, head, _) {
            final position = active ? head : Duration.zero;
            final scrubbing = _scrubbing;
            final fraction =
                scrubbing ??
                (active && total.inMilliseconds > 0
                    ? (position.inMilliseconds / total.inMilliseconds).clamp(
                        0.0,
                        1.0,
                      )
                    : null);
            final shown = scrubbing == null ? position : total * scrubbing;
            final touch = !AppPlatform.hasPointer;
            final size = touch ? 44.0 : 36.0;

            final play = IconButton(
              icon: VoicePlayGlyph(
                playing: playing,
                opening: opening,
                failure: failure,
                size: touch ? 18 : 16,
                color: palette.tonalForeground,
              ),
              tooltip: voicePlayButtonLabel(
                playing: playing,
                opening: opening,
                failure: failure,
              ),
              padding: EdgeInsets.zero,
              constraints: BoxConstraints.tightFor(width: size, height: size),
              style: IconButton.styleFrom(
                backgroundColor: palette.tonalBackground,
                shape: const CircleBorder(),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _toggle,
            );
            final scrubber = _Scrubber(
              peaks: widget.ref.peaks,
              fraction: fraction,
              value: formatVoiceDuration(shown),
              onTap: (at) {
                if (active) {
                  unawaited(player.seek(total * at));
                } else {
                  unawaited(_start(from: total * at));
                }
              },
              onDrag: (at) {
                if (active) {
                  unawaited(player.seek(total * at));
                } else {
                  setState(() => _scrubbing = at);
                }
              },
              onDragEnd: () {
                final at = _scrubbing;
                if (at == null) return;
                setState(() => _scrubbing = null);
                unawaited(_start(from: total * at));
              },
            );
            final time = Text(
              '${formatVoiceDuration(shown)} / ${formatVoiceDuration(total)}',
              style: TextStyle(
                fontSize: AppTypeScale.caption,
                fontFeatures: const [FontFeature.tabularFigures()],
                color: palette.textSecondary,
              ),
            );
            final speed = _SpeedPill(
              speed: player.speed,
              onPressed: () => unawaited(
                player.setSpeed(
                  _speeds[(_speeds.indexOf(player.speed) + 1) % _speeds.length],
                ),
              ),
            );

            final noise = NoiseRemovalScope.maybeOf(context) == null
                ? null
                : _NoisePill(hash: widget.ref.hash);

            if (!touch) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(22, 10, 22, 8),
                child: Row(
                  children: [
                    play,
                    const SizedBox(width: 12),
                    Expanded(child: scrubber),
                    const SizedBox(width: 12),
                    time,
                    const SizedBox(width: 12),
                    if (noise != null) ...[noise, const SizedBox(width: 8)],
                    speed,
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.fromLTRB(22, 10, 22, 8),
              child: Column(
                children: [
                  Row(
                    children: [
                      play,
                      const SizedBox(width: 12),
                      Expanded(child: scrubber),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    // The ×'s 44 pt target while noise is being removed,
                    // held all along so the sheet does not jump.
                    height: noise == null ? null : 44,
                    child: Row(
                      children: [
                        SizedBox(width: size + 12),
                        time,
                        const Spacer(),
                        if (noise != null) ...[noise, const SizedBox(width: 8)],
                        speed,
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _toggle() async {
    final player = widget.player;
    if (player == null) return;
    final hash = widget.ref.hash;
    // A press on a recording still on its way calls it off, as a pause would.
    if (player.isPlaying(hash) || player.isOpening(hash)) {
      await player.pause();
      return;
    }
    await _start();
  }

  Future<void> _start({Duration? from}) async {
    await widget.player?.play(widget.ref.hash, from: from);
  }
}

/// The chip's waveform, played part tinted, with the head as a line. A tap
/// or a drag says where, as a share of the recording.
class _Scrubber extends StatelessWidget {
  const _Scrubber({
    required this.peaks,
    required this.fraction,
    required this.value,
    required this.onTap,
    required this.onDrag,
    required this.onDragEnd,
  });

  final Uint8List? peaks;
  final double? fraction;
  final String value;
  final ValueChanged<double> onTap;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        double at(Offset point) => (point.dx / width).clamp(0.0, 1.0);
        return Semantics(
          slider: true,
          label: 'Position',
          value: value,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => onTap(at(details.localPosition)),
            onHorizontalDragStart: (details) =>
                onDrag(at(details.localPosition)),
            onHorizontalDragUpdate: (details) =>
                onDrag(at(details.localPosition)),
            onHorizontalDragEnd: (_) => onDragEnd(),
            child: CustomPaint(
              size: Size(width, 36),
              painter: VoiceWaveformPainter(
                peaks: peaks,
                progress: fraction,
                played: palette.accent,
                unplayed: palette.switchTrackOff,
                bars: (width / 4).floor().clamp(12, 100),
              ),
              foregroundPainter: fraction == null
                  ? null
                  : _HeadPainter(fraction!, palette.textPrimary),
            ),
          ),
        );
      },
    );
  }
}

class _HeadPainter extends CustomPainter {
  _HeadPainter(this.fraction, this.color);

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final x = (size.width * fraction).clamp(1.0, size.width - 1);
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_HeadPainter old) =>
      old.fraction != fraction || old.color != color;
}

/// Remove noise: one toggle before the speed. Off plays the original; on,
/// filled in sage, plays the clean copy. The first press fetches what it
/// needs if this device has never removed noise, then makes the copy, with
/// a pie and a × to stop it. Only the × stops it, so a stray tap on a phone
/// cannot throw away minutes of work.
class _NoisePill extends StatelessWidget {
  const _NoisePill({required this.hash});

  final String hash;

  @override
  Widget build(BuildContext context) {
    final noise = NoiseRemovalScope.maybeOf(context)!;
    final palette = context.palette;
    final touch = !AppPlatform.hasPointer;
    final state = noise.stateOf(hash);
    final on = state.stage == NoiseStage.on;
    final height = touch ? 30.0 : 24.0;
    final color = on ? palette.tonalForeground : palette.textSecondary;
    final words = switch (state.stage) {
      NoiseStage.downloading => 'Downloading',
      NoiseStage.removing => 'Removing noise',
      NoiseStage.off || NoiseStage.on => 'Remove noise',
    };
    final label = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state.isBusy)
            SettingsPie(fraction: min(state.progress, 0.99))
          else
            KapyIcon(KapyIcons.voiceIdRounded, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            words,
            style: TextStyle(
              fontSize: AppTypeScale.caption,
              fontWeight: AppWeight.font(AppWeight.regular),
              fontVariations: AppWeight.wght(AppWeight.regular),
              color: color,
            ),
          ),
        ],
      ),
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(7),
      side: on ? BorderSide.none : BorderSide(color: palette.controlBorder),
    );

    if (!state.isBusy) {
      return Tooltip(
        message: on
            ? 'Play the original'
            : noise.isNew(hash)
            ? 'Clears background noise. Your original is kept.'
            : 'Remove noise',
        child: Semantics(
          button: true,
          toggled: on,
          label: 'Remove noise',
          excludeSemantics: true,
          child: Material(
            color: on ? palette.tonalBackground : palette.wellBackground,
            shape: shape,
            child: InkWell(
              key: const ValueKey('voice-remove-noise'),
              customBorder: shape,
              onTap: on
                  ? () => noise.turnOff(hash)
                  : () => removeNoise(
                      Overlay.of(context, rootOverlay: true),
                      noise,
                      hash,
                    ),
              child: label,
            ),
          ),
        ),
      );
    }

    final percent = '${(state.progress * 100).floor()}%';
    final stop = Tooltip(
      message: 'Stop',
      child: Semantics(
        button: true,
        label: 'Stop',
        excludeSemantics: true,
        child: InkWell(
          key: const ValueKey('voice-remove-noise-stop'),
          onTap: () => noise.stop(hash),
          child: SizedBox(
            width: touch ? 44 : height,
            height: touch ? 44 : height,
            child: touch
                ? null
                : Center(
                    child: KapyIcon(
                      KapyIcons.closeRounded,
                      size: 12,
                      color: palette.textSecondary,
                    ),
                  ),
          ),
        ),
      ),
    );
    final pill = Material(
      color: palette.wellBackground,
      shape: shape,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            label: '$words, $percent',
            excludeSemantics: true,
            child: touch
                ? Tooltip(
                    message: 'Stop with the ×',
                    triggerMode: TooltipTriggerMode.tap,
                    child: label,
                  )
                : label,
          ),
          Container(width: 1, height: 14, color: palette.controlBorder),
          if (touch)
            SizedBox.square(
              dimension: height,
              child: Center(
                child: KapyIcon(
                  KapyIcons.closeRounded,
                  size: 12,
                  color: palette.textSecondary,
                ),
              ),
            )
          else
            stop,
        ],
      ),
    );
    if (!touch) return pill;
    // The pill keeps the row's 30 pt height; the ×'s 44 pt target lies over
    // its end, reaching a little into the label's padding.
    return SizedBox(
      height: 44,
      child: Stack(
        alignment: Alignment.centerRight,
        children: [
          pill,
          Positioned(right: 0, top: 0, bottom: 0, child: stop),
        ],
      ),
    );
  }
}

/// Removes the noise from [hash] for a press on the button, and says how it
/// went once it has, on [overlay], because the window may have closed by
/// then.
Future<void> removeNoise(
  OverlayState overlay,
  NoiseRemovals noise,
  String hash,
) async {
  final fresh = noise.isNew(hash);
  final problem = await noise.turnOn(hash);
  if (!overlay.mounted) return;
  if (problem == null) {
    if (fresh && noise.stateOf(hash).stage == NoiseStage.on) {
      Toast.showOn(overlay, 'Noise removed. Your original is kept.');
    }
    return;
  }
  final again =
      problem == NoiseProblem.failed ||
      problem == NoiseProblem.couldNotDownload;
  Toast.showOn(
    overlay,
    switch (problem) {
      NoiseProblem.couldNotDownload =>
        "Couldn't download noise removal. Check your connection.",
      NoiseProblem.notDownloaded =>
        "This recording hasn't downloaded yet. Try again when you're online.",
      NoiseProblem.noSpace =>
        'Not enough space on this device to remove the noise.',
      NoiseProblem.failed => "Couldn't remove the noise.",
    },
    isError: true,
    action: again ? 'Try again' : null,
    onAction: again ? () => unawaited(removeNoise(overlay, noise, hash)) : null,
  );
}

/// 1× → 1.5× → 2×.
class _SpeedPill extends StatelessWidget {
  const _SpeedPill({required this.speed, required this.onPressed});

  final double speed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = speed == speed.roundToDouble()
        ? speed.toStringAsFixed(0)
        : '$speed';
    return Tooltip(
      message: 'Playback speed',
      child: Material(
        color: palette.wellBackground,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(7),
          side: BorderSide(color: palette.controlBorder),
        ),
        child: InkWell(
          onTap: onPressed,
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(7),
          ),
          child: Container(
            height: AppPlatform.hasPointer ? 24 : 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            child: Text(
              '$label×',
              style: TextStyle(
                fontSize: AppTypeScale.caption,
                fontWeight: AppWeight.font(AppWeight.regular),
                fontVariations: AppWeight.wght(AppWeight.regular),
                color: palette.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Summary | Transcript, then search on the transcript side and Insert,
/// which says what it puts in the note.
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.onSummary,
    required this.onChanged,
    required this.insertLabel,
    this.onSearch,
    this.onInsert,
  });

  final bool onSummary;
  final ValueChanged<bool> onChanged;
  final String insertLabel;
  final VoidCallback? onSearch;
  final VoidCallback? onInsert;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final pointer = AppPlatform.hasPointer;
    final segmented = SettingsSegmented<bool>(
      options: const [true, false],
      selected: onSummary,
      labelFor: (summary) => summary ? 'Summary' : 'Transcript',
      keyFor: (summary) =>
          ValueKey(summary ? 'voice-summary' : 'voice-transcript'),
      onSelected: onChanged,
    );
    final extent = pointer ? 28.0 : 40.0;
    final colour = onInsert == null ? palette.textTertiary : palette.accentText;
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 6, 16, 2),
      child: Row(
        children: [
          // On a phone the track shares its width between the two, so it is
          // given one; beside a pointer it fits its labels.
          if (pointer) segmented else SizedBox(width: 176, child: segmented),
          // What is left goes to search and Insert, which keep to the right
          // and shrink rather than overflow on a narrow phone.
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onSearch != null)
                      IconButton(
                        icon: const KapyIcon(KapyIcons.searchRounded, size: 18),
                        tooltip: 'Search transcript',
                        color: palette.textSecondary,
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints.tightFor(
                          width: extent,
                          height: extent,
                        ),
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onPressed: onSearch,
                      ),
                    const SizedBox(width: 4),
                    Semantics(
                      button: true,
                      enabled: onInsert != null,
                      child: InkWell(
                        onTap: onInsert,
                        borderRadius: BorderRadius.circular(7),
                        child: Container(
                          height: pointer ? 26 : 36,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          alignment: Alignment.center,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              KapyIcon(
                                KapyIcons.noteAddRounded,
                                size: 16,
                                color: colour,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                insertLabel,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: AppWeight.font(AppWeight.regular),
                                  fontVariations: AppWeight.wght(
                                    AppWeight.regular,
                                  ),
                                  color: colour,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// When a summary point was said, plain and muted, and a tap plays it.
class _MomentTime extends StatelessWidget {
  const _MomentTime({required this.at, required this.onPlay});

  final Duration at;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final time = formatVoiceDuration(at);
    return Tooltip(
      message: 'Play from $time',
      child: InkWell(
        onTap: onPlay,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            time,
            style: TextStyle(
              fontSize: AppTypeScale.caption,
              height: 20 / AppTypeScale.caption,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: context.palette.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

/// Find in the transcript: the words, how many there are, and steps
/// through them. Return goes to the next one and Escape closes it.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.matches,
    required this.current,
    required this.searched,
    required this.onChanged,
    required this.onStep,
    required this.onClose,
  });

  final TextEditingController controller;
  final int matches;
  final int current;
  final bool searched;
  final ValueChanged<String> onChanged;
  final ValueChanged<int> onStep;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    Widget step(KapyIconData icon, String tooltip, int by) => IconButton(
      icon: KapyIcon(icon, size: 16),
      tooltip: tooltip,
      color: palette.textSecondary,
      visualDensity: VisualDensity.compact,
      onPressed: matches == 0 ? null : () => onStep(by),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 8, 14, 4),
      child: CallbackShortcuts(
        bindings: {const SingleActivator(LogicalKeyboardKey.escape): onClose},
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                autofocus: true,
                onChanged: onChanged,
                onSubmitted: (_) => onStep(1),
                style: TextStyle(
                  fontSize: AppTypeScale.small,
                  color: palette.textPrimary,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Find in transcript',
                  prefixIcon: KapyIcon(
                    KapyIcons.searchRounded,
                    size: 16,
                    color: palette.textTertiary,
                  ),
                  prefixIconConstraints: const BoxConstraints.tightFor(
                    width: 32,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
            if (searched) ...[
              const SizedBox(width: 8),
              Text(
                matches == 0 ? 'No matches' : '${current + 1} of $matches',
                style: TextStyle(
                  fontSize: AppTypeScale.caption,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: palette.textTertiary,
                ),
              ),
            ],
            step(KapyIcons.chevronUpRounded, 'Previous match', -1),
            step(KapyIcons.chevronDownRounded, 'Next match', 1),
            IconButton(
              icon: const KapyIcon(KapyIcons.closeRounded, size: 16),
              tooltip: 'Close search',
              color: palette.textSecondary,
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// Why there is nothing to read yet, where the words would be.
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
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 14, 22, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy) ...[const _BusyPie(), const SizedBox(width: 8)],
                Flexible(
                  child: Text(
                    message,
                    style: _reading.copyWith(color: palette.textSecondary),
                  ),
                ),
              ],
            ),
            if (caption case final caption?) ...[
              const SizedBox(height: 4),
              Text(
                caption,
                style: TextStyle(
                  fontSize: AppTypeScale.caption,
                  color: palette.textTertiary,
                ),
              ),
            ],
            if (actionLabel case final label? when onAction != null) ...[
              const SizedBox(height: 10),
              TonalButton(label: label, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}

/// The app's 14 px clock face, filling round while the work goes on. Still,
/// a quarter full, when the system asks for less motion.
class _BusyPie extends StatefulWidget {
  const _BusyPie();

  @override
  State<_BusyPie> createState() => _BusyPieState();
}

class _BusyPieState extends State<_BusyPie>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turn = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _turn.stop();
    } else if (!_turn.isAnimating) {
      unawaited(_turn.repeat());
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return const SettingsPie(fraction: 0.25);
    }
    // Short of full: a full face is the allowance pie's "used up".
    return AnimatedBuilder(
      animation: _turn,
      builder: (context, _) => SettingsPie(fraction: _turn.value * 0.95),
    );
  }
}

/// One paragraph of the transcript, its text, and whether it opens
/// somebody's turn.
///
/// Worked out once for the whole transcript rather than in the builder: a
/// long recording runs to hundreds of these and a list that recomputes who
/// spoke last on every scroll frame is a list that stutters.
class _TranscriptRow {
  const _TranscriptRow({
    required this.paragraph,
    required this.text,
    required this.speaker,
    required this.startsTurn,
  });

  final List<TranscriptSegment> paragraph;
  final String text;
  final int? speaker;
  final bool startsTurn;
}

/// A colour per speaker: two from the tag wheel that tell apart in every
/// theme, taken in turn.
///
/// Not the chip colours, which Riverbank sets all to one sage, so the dots
/// could not tell Me from Arjun.
Color speakerColor(CalcPalette palette, int speaker) =>
    (speaker.isEven ? TagColour.teal : TagColour.mustard).dot(palette);

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
    final quiet = TextStyle(
      fontSize: AppTypeScale.caption,
      color: palette.textTertiary,
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 22),
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: palette.separator)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('${speakers.length} speakers', style: quiet),
          for (final speaker in speakers)
            _SpeakerLabel(
              name: transcript.nameFor(speaker),
              color: speakerColor(palette, speaker),
              boxed: true,
              onPressed: onRename == null ? null : () => onRename!(speaker),
            ),
          if (onRename != null) Text('Tap a name to change it.', style: quiet),
        ],
      ),
    );
  }
}

/// A speaker's name, with the dot that ties it to their paragraphs: in a
/// box in the speaker row, bare over a paragraph.
class _SpeakerLabel extends StatelessWidget {
  const _SpeakerLabel({
    required this.name,
    required this.color,
    this.boxed = false,
    this.onPressed,
  });

  final String name;
  final Color color;
  final bool boxed;
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
            fontSize: AppTypeScale.caption,
            fontWeight: AppWeight.font(AppWeight.regular),
            fontVariations: AppWeight.wght(AppWeight.regular),
            color: palette.textSecondary,
          ),
        ),
      ],
    );
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(boxed ? 6 : AppRadii.control),
      side: boxed ? BorderSide(color: palette.controlBorder) : BorderSide.none,
    );
    final padded = Container(
      height: boxed ? 22 : null,
      padding: EdgeInsets.symmetric(horizontal: boxed ? 8 : 4, vertical: 2),
      decoration: ShapeDecoration(
        shape: shape,
        color: boxed ? palette.wellBackground : null,
      ),
      child: label,
    );
    if (onPressed == null) return padded;
    return Semantics(
      button: true,
      label: 'Rename $name',
      child: InkWell(onTap: onPressed, customBorder: shape, child: padded),
    );
  }
}

/// A quiet text action, for things beside a caption rather than under it.
class _QuietButton extends StatelessWidget {
  const _QuietButton({required this.label, this.icon, this.onPressed});

  final String label;
  final KapyIconData? icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(AppRadii.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon case final icon?) ...[
              KapyIcon(icon, size: 15, color: palette.textSecondary),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: AppTypeScale.caption,
                fontWeight: AppWeight.font(AppWeight.regular),
                fontVariations: AppWeight.wght(AppWeight.regular),
                color: palette.textSecondary,
              ),
            ),
          ],
        ),
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
                style: TextStyle(
                  fontSize: AppTypeScale.small,
                  color: palette.textSecondary,
                ),
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

/// Asks for the recording's name, starting from the one it has.
Future<String?> showRenameDialog(
  BuildContext context, {
  required String current,
}) {
  final controller = TextEditingController(text: current)
    ..selection = TextSelection(baseOffset: 0, extentOffset: current.length);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Rename recording'),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: 80,
        decoration: const InputDecoration(counterText: ''),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
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
