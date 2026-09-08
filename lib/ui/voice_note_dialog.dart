import 'package:material_ui/material_ui.dart';

import '../audio/voice_player.dart';
import '../core/platform.dart';
import '../core/theme.dart';
import '../data/blob_store.dart';
import '../data/note_attachment.dart';
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
  late bool _onSummary;

  @override
  void initState() {
    super.initState();
    // Opens on whichever tab has something to read. Not remembered between
    // openings: a rule you can predict beats one that is merely sticky.
    _onSummary = widget.ref.summary != null;
  }

  NoteVoiceRef get _ref => widget.ref;

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
        VoiceNotePlayerRow(ref: _ref, player: widget.player, blobs: widget.blobs),
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
        const SizedBox(height: 12),
        Text(
          'Made from the transcript',
          style: TextStyle(fontSize: 11, color: palette.textTertiary),
        ),
      ],
    );
  }

  Widget _transcript(CalcPalette palette) {
    final transcript = _ref.transcript!;
    final paragraphs = groupTranscriptParagraphs(transcript.segments);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      itemCount: paragraphs.length + 1,
      itemBuilder: (context, index) {
        if (index == paragraphs.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Transcribed · ${transcript.lang}',
              style: TextStyle(fontSize: 11, color: palette.textTertiary),
            ),
          );
        }
        final paragraph = paragraphs[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                child: Text(
                  formatVoiceDuration(
                    Duration(milliseconds: paragraph.first.s),
                  ),
                  style: TextStyle(fontSize: 11, color: palette.textTertiary),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => widget.player?.seek(
                    Duration(milliseconds: paragraph.first.s),
                  ),
                  child: SelectableText(
                    paragraph.map((segment) => segment.t).join(' ').trim(),
                    style: TextStyle(color: palette.textPrimary, height: 1.5),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
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
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
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
                    fontWeight: FontWeight.w600,
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

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final player = widget.player;
    if (player == null) return const SizedBox(height: 8);

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final active = player.activeHash == widget.ref.hash;
        final total = active ? (player.duration ?? widget.ref.duration) : widget.ref.duration;
        final position = active ? player.position : Duration.zero;
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
                tooltip: player.isPlaying(widget.ref.hash) ? 'Pause' : 'Play',
                onPressed: _toggle,
              ),
              Expanded(
                child: Slider(
                  value: total.inMilliseconds == 0
                      ? 0
                      : (position.inMilliseconds / total.inMilliseconds)
                            .clamp(0.0, 1.0),
                  onChanged: active
                      ? (value) => player.seek(total * value)
                      : null,
                ),
              ),
              Text(
                '${formatVoiceDuration(position)} / ${formatVoiceDuration(total)}',
                style: TextStyle(
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: palette.textSecondary,
                ),
              ),
              TextButton(
                onPressed: () {
                  final next =
                      _speeds[(_speeds.indexOf(player.speed) + 1) % _speeds.length];
                  player.setSpeed(next);
                },
                child: Text('${_trim(player.speed)}×'),
              ),
            ],
          ),
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
    final file = await widget.blobs.fileFor(widget.ref.hash);
    if (file == null) return;
    await player.play(widget.ref.hash, file);
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
