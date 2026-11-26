import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:material_ui/material_ui.dart';

import '../../audio/voice_player.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/note_attachment.dart';
import '../context_menu.dart';
import 'note_image_layout.dart';
import 'placeholder_scale.dart';

/// How tall a recording's card is: its name over its player, 60px with a
/// pointer and 68pt on a phone.
///
/// The same whatever the recording holds: a card that grew once a title
/// arrived would reflow the note under whoever was reading it.
double get noteVoiceChipHeight => AppPlatform.hasPointer ? 60 : 68;

/// The widest a card gets with a pointer, so the recordings in a note line up.
const double _cardMaxWidth = 460;

/// The card's corners, a photo's and a video's.
const double _cardRadius = 10;

/// The waveform's width and bars, which no state changes, so a recording
/// that gets its title moves nothing on its card.
const double _waveWidth = 160;
const int _waveBars = 32;

/// Between the play button, the two lines and the ×.
const double _gap = 12;

/// Between the waveform and the length.
const double _waveGap = 10;

/// The card's measurements: Paper's with a pointer, and the phone's larger
/// ones. Top to bottom they fill the card inside its 1px border.
class _CardMetrics {
  const _CardMetrics({
    required this.left,
    required this.play,
    required this.glyph,
    required this.top,
    required this.nameSize,
    required this.nameLine,
    required this.chevron,
    required this.gap,
    required this.lineSize,
    required this.line,
    required this.bottom,
  });

  /// From the border to the play button.
  final double left;
  final double play;
  final double glyph;

  /// Above the name's line.
  final double top;
  final double nameSize;
  final double nameLine;
  final double chevron;

  /// Between the name's line and the player's.
  final double gap;
  final double lineSize;
  final double line;

  /// Under the player's line.
  final double bottom;
}

const _pointerMetrics = _CardMetrics(
  left: 10,
  play: 40,
  glyph: 16,
  top: 10,
  nameSize: 13,
  nameLine: 17,
  chevron: 13,
  gap: 5,
  lineSize: 12,
  line: 16,
  bottom: 10,
);

const _touchMetrics = _CardMetrics(
  left: 12,
  play: 44,
  glyph: 18,
  top: 11,
  nameSize: 15,
  nameLine: 20,
  chevron: 15,
  gap: 6,
  lineSize: 13,
  line: 18,
  bottom: 11,
);

/// What a recording says on its usual way to its summary's title.
const _transcribing = 'Transcribing…';
const _summarising = 'Summarising…';

/// What the chip says about a recording beyond the recording itself.
enum VoiceChipState {
  /// Nothing more is coming — no account, or transcription is off.
  idle,

  /// Queued, but the device is offline.
  waiting,

  /// The server could not do it last time and the queue will ask again.
  ///
  /// Its own state because "Transcribing…" over a request that already
  /// failed is the app telling somebody to wait for work that is not
  /// happening, and "Couldn't transcribe" is not yet true either.
  retrying,

  /// In progress.
  transcribing,

  /// A transcript arrived and is being summarised.
  summarising,

  /// Done, and the chip shows the summary's title.
  done,

  /// Something went wrong and the user can retry.
  failed,

  /// The month's minutes are gone.
  outOfMinutes,

  /// The user has not agreed to transcription yet.
  needsConsent,

  /// Nobody is signed in, so there is no account to transcribe against.
  needsAccount,
}

/// A hover hint, when there is something to hint at.
///
/// Only the pointer opens it: a press-and-hold belongs to the chip's own menu,
/// so the tooltip must not put a recogniser of its own in the way. Nested,
/// only the innermost one answers, so each part of the row can name its own
/// action.
Widget _hoverHint(String? message, Widget child) => message == null
    ? child
    : PlaceholderTooltip(
        message: message,
        triggerMode: TooltipTriggerMode.manual,
        child: child,
      );

/// A recording, sitting in the body of a note.
///
/// A card with the recording's name first and its player under it: the name
/// and its arrow say the card opens, the way a note in the list does, and
/// play stays one press away. A note holding six recordings should still read
/// as a note, so the waveform is the only picture. It is precomputed to 100
/// bytes, and it repaints inside its own boundary while playback moves so the
/// words around it do nothing.
class NoteVoiceChip extends StatefulWidget {
  const NoteVoiceChip({
    super.key,
    required this.ref,
    required this.state,
    required this.progress,
    required this.playing,
    this.opening = false,
    this.failure,
    this.onPlayPause,
    this.onOpen,
    this.onRemove,
    this.onSeekFraction,
  });

  final NoteVoiceRef ref;
  final VoiceChipState state;

  /// 0 to 1 while this recording is the one playing, else null.
  final ValueListenable<double?> progress;
  final bool playing;

  /// Pressed, and still on its way: a recording from another device whose
  /// audio is being fetched.
  final bool opening;

  /// Why the last press did not start this recording, if it did not.
  final VoicePlaybackFailure? failure;

  final VoidCallback? onPlayPause;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;
  final ValueChanged<double>? onSeekFraction;

  /// Whether the recording goes by its summary's title.
  bool get _titled =>
      ref.summary != null &&
      (state == VoiceChipState.done || state == VoiceChipState.idle);

  /// What the recording is called: its summary's title, and "Voice note"
  /// until it has one. Never a status, so the arrow after it always follows
  /// the thing a click opens.
  String get _name => _titled ? ref.summary!.title : 'Voice note';

  /// What has become of the recording, when that is more than its name.
  String? get _status => switch (state) {
    VoiceChipState.done || VoiceChipState.idle => null,
    VoiceChipState.transcribing => _transcribing,
    VoiceChipState.summarising => _summarising,
    VoiceChipState.waiting => 'Waiting for connection',
    VoiceChipState.retrying => 'Trying again soon',
    VoiceChipState.failed when ref.transcript != null => "Couldn't summarise",
    VoiceChipState.failed => "Couldn't transcribe",
    VoiceChipState.outOfMinutes => 'Out of minutes',
    // Local transcription may finish while a cloud summary is waiting for
    // sign-in. Keep the words readable instead of asking to transcribe them
    // a second time.
    VoiceChipState.needsConsent || VoiceChipState.needsAccount
        when ref.transcript != null =>
      'Transcript ready',
    // Both say what to do rather than what is wrong, because both are one
    // tap from being fixed and the chip is where the person is looking.
    VoiceChipState.needsConsent => 'Turn on transcription',
    VoiceChipState.needsAccount => 'Turn on transcription',
  };

  /// What clicking the card does, which its words do not say.
  ///
  /// Named after what is on the other side of the click rather than after the
  /// recording's state: someone hovering is asking where this goes. Every
  /// hint the card gives is here, so they change together with the window
  /// they open.
  String? get _openHint {
    if (onOpen == null) return null;
    if (ref.summary != null) return 'Open the summary and transcript';
    if (ref.transcript != null) return 'Open the transcript';
    return switch (state) {
      VoiceChipState.needsConsent => 'Turn transcription on in Settings',
      VoiceChipState.needsAccount => 'Choose transcription in Settings',
      VoiceChipState.failed => 'Try transcribing again',
      _ => 'Open this recording',
    };
  }

  /// A state the user could act on is drawn in the muted colour rather than
  /// as an error: a recording that failed to transcribe is still a perfectly
  /// good recording, and nothing has been lost.
  bool get _isTransient =>
      state == VoiceChipState.transcribing ||
      state == VoiceChipState.summarising ||
      state == VoiceChipState.waiting ||
      state == VoiceChipState.retrying;

  @override
  State<NoteVoiceChip> createState() => _NoteVoiceChipState();
}

class _NoteVoiceChipState extends State<NoteVoiceChip> {
  bool _hovered = false;
  bool _pressed = false;

  /// The play button, the waveform and the × each do their own thing, so a
  /// press on one must not light the card as if it were opening. They note
  /// their pointer as it goes down, before the card hears of it.
  int? _controlPointer;
  bool _pressOnControl = false;

  void _setHovered(bool hovered) {
    if (mounted && _hovered != hovered) setState(() => _hovered = hovered);
  }

  void _setPressed(bool pressed) {
    if (mounted && _pressed != pressed) setState(() => _pressed = pressed);
  }

  Widget _control(Widget child) => Listener(
    onPointerDown: (event) => _controlPointer = event.pointer,
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final chip = widget;
    final card = _gestures(context, _card(context));
    return Semantics(
      label: [
        chip._name,
        if (chip._titled) 'voice note',
        formatVoiceDuration(chip.ref.duration),
        ?chip._status,
      ].join(', '),
      hint: chip._openHint,
      button: true,
      customSemanticsActions: chip.onRemove == null
          ? null
          : {
              const CustomSemanticsAction(label: 'Remove voice note'):
                  chip.onRemove!,
            },
      child: Padding(
        padding: const EdgeInsets.only(bottom: noteImageGap),
        child: AppPlatform.hasPointer
            ? Align(
                alignment: Alignment.centerLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: _cardMaxWidth),
                  child: card,
                ),
              )
            : card,
      ),
    );
  }

  /// Paper's recording card: the play button, then the name and its arrow
  /// over the waveform in sage up to the play head and the length. With a
  /// pointer it is at most 460 wide and carries a ×; on a phone it is the
  /// column's width and removed from its long-press menu.
  Widget _card(BuildContext context) {
    final chip = widget;
    final palette = context.palette;
    final touch = !AppPlatform.hasPointer;
    final metrics = touch ? _touchMetrics : _pointerMetrics;
    final removable = chip.onRemove != null && !touch;
    final lit = chip.onOpen != null && (_hovered || _pressed);
    final status = chip._status;
    final statusStyle = _style(
      palette,
      metrics.lineSize,
      metrics.line,
      AppWeight.body,
      chip._isTransient ? palette.textTertiary : palette.textMuted,
    );
    return Container(
      key: const ValueKey('voice-chip-card'),
      height: noteVoiceChipHeight,
      padding: EdgeInsets.only(left: metrics.left, right: removable ? 6 : 14),
      decoration: BoxDecoration(
        color: !lit
            ? palette.controlBackground
            : _pressed
            ? palette.selectedBackground
            : palette.hover,
        borderRadius: BorderRadius.circular(_cardRadius),
        border: Border.all(
          color: lit ? palette.keycapBorder : palette.controlBorder,
        ),
      ),
      child: Row(
        children: [
          _control(
            _PlayButton(
              playing: chip.playing,
              opening: chip.opening,
              failure: chip.failure,
              onPressed: chip.onPlayPause,
              size: metrics.play,
              glyph: metrics.glyph,
            ),
          ),
          const SizedBox(width: _gap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: metrics.top),
                SizedBox(
                  height: metrics.nameLine,
                  child: _nameLine(
                    palette,
                    metrics,
                    touch ? status : null,
                    statusStyle,
                  ),
                ),
                _playerLine(
                  context,
                  metrics,
                  touch ? null : status,
                  statusStyle,
                ),
              ],
            ),
          ),
          if (removable) ...[
            const SizedBox(width: _gap),
            _control(_removeButton(palette)),
          ],
        ],
      ),
    );
  }

  /// The name and its arrow. A phone has no room for a status after the
  /// length, so there it sits at the end of this line instead, at least 2
  /// after the arrow's box: the box is mostly air on that side, so the arrow
  /// still reads 7 clear of the words, and the longest status fits a 320
  /// card.
  Widget _nameLine(
    CalcPalette palette,
    _CardMetrics metrics,
    String? status,
    TextStyle statusStyle,
  ) {
    final name = Text(
      widget._name,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: _style(
        palette,
        metrics.nameSize,
        metrics.nameLine,
        AppWeight.rowTitle,
        palette.textPrimary,
      ),
    );
    final arrow = Padding(
      padding: const EdgeInsets.only(left: 3),
      child: KapyIcon(
        KapyIcons.chevronRightRounded,
        size: metrics.chevron,
        color: widget.onOpen != null && _hovered
            ? palette.textSecondary
            : palette.textTertiary,
      ),
    );
    if (status == null) {
      return ExcludeSemantics(
        child: Row(
          children: [
            Flexible(child: name),
            arrow,
          ],
        ),
      );
    }
    return ExcludeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [name, arrow]),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 2),
              child: Text(
                status,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: statusStyle,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The waveform, the length, and with a pointer the status after it.
  ///
  /// The waveform's target runs from under the name to the card's bottom
  /// edge, a larger one than its bars. While the recording plays the length
  /// reads as the time so far and the total. On a phone the length keeps the
  /// room that takes, so starting playback never narrows the waveform.
  Widget _playerLine(
    BuildContext context,
    _CardMetrics metrics,
    String? status,
    TextStyle statusStyle,
  ) {
    final chip = widget;
    final palette = context.palette;
    final touch = !AppPlatform.hasPointer;
    final lengthStyle = _style(
      palette,
      metrics.lineSize,
      metrics.line,
      AppWeight.rowTitle,
      palette.textSecondary,
    ).copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final total = formatVoiceDuration(chip.ref.duration);
    final length = ValueListenableBuilder<double?>(
      valueListenable: chip.progress,
      builder: (context, progress, _) => Text(
        progress == null
            ? total
            : '${formatVoiceDuration(chip.ref.duration * progress)} / $total',
        maxLines: 1,
        softWrap: false,
        style: lengthStyle,
      ),
    );
    final waveform = SizedBox(
      width: _waveWidth,
      height: metrics.gap + metrics.line + metrics.bottom,
      child: _control(
        RepaintBoundary(
          child: _Waveform(
            peaks: chip.ref.peaks,
            progress: chip.progress,
            played: Theme.of(context).colorScheme.primary,
            unplayed: palette.quoteBar,
            onSeekFraction: chip.onSeekFraction,
            bars: _waveBars,
            band: EdgeInsets.only(top: metrics.gap, bottom: metrics.bottom),
          ),
        ),
      ),
    );
    final words = Padding(
      padding: EdgeInsets.only(top: metrics.gap),
      child: SizedBox(
        height: metrics.line,
        child: ExcludeSemantics(
          child: touch
              ? Stack(
                  children: [
                    Visibility.maintain(
                      visible: false,
                      child: Text(
                        '$total / $total',
                        maxLines: 1,
                        softWrap: false,
                        style: lengthStyle,
                      ),
                    ),
                    length,
                  ],
                )
              : Row(
                  children: [
                    length,
                    if (status != null) ...[
                      Text(' · ', style: statusStyle),
                      Flexible(
                        child: Text(
                          status,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: statusStyle,
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (touch) Flexible(child: waveform) else waveform,
        const SizedBox(width: _waveGap),
        if (touch) words else Expanded(child: words),
      ],
    );
  }

  /// The card's words, at [size] on lines [line] tall.
  TextStyle _style(
    CalcPalette palette,
    double size,
    double line,
    double weight,
    Color color,
  ) => TextStyle(
    fontFamily: AppFonts.ui,
    fontFamilyFallback: AppFonts.uiFallback,
    fontSize: size,
    height: line / size,
    fontWeight: AppWeight.font(weight),
    fontVariations: AppWeight.wght(weight),
    color: color,
  );

  /// What the whole card answers to: a click opens the recording, and a
  /// secondary click or a long press offers to remove it.
  Widget _gestures(BuildContext context, Widget child) {
    final chip = widget;
    final opens = chip.onOpen != null;
    return MouseRegion(
      // A recording is not text, and every part of the card does something.
      cursor:
          chip.onOpen == null &&
              chip.onPlayPause == null &&
              chip.onSeekFraction == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => _setHovered(true),
      onExit: (_) => _setHovered(false),
      child: _hoverHint(
        chip._openHint,
        Listener(
          onPointerDown: (event) =>
              _pressOnControl = event.pointer == _controlPointer,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: opens
                ? (_) {
                    if (!_pressOnControl) _setPressed(true);
                  }
                : null,
            onTapUp: opens ? (_) => _setPressed(false) : null,
            onTapCancel: opens ? () => _setPressed(false) : null,
            onTap: chip.onOpen,
            onSecondaryTapDown: chip.onRemove == null
                ? null
                : (details) => _showMenu(context, details.globalPosition),
            onLongPressStart: chip.onRemove == null
                ? null
                : (details) => _showMenu(context, details.globalPosition),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _removeButton(CalcPalette palette) => PlaceholderTooltip(
    message: 'Remove voice note',
    child: IconButton(
      key: const ValueKey('remove-voice-note'),
      onPressed: widget.onRemove,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 28, height: 28),
      icon: KapyIcon(
        KapyIcons.closeRounded,
        size: 16,
        color: palette.textSecondary,
      ),
    ),
  );

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final choice = await showKapyContextMenu<String>(
      context: context,
      globalPosition: position,
      items: const [
        PopupMenuItem(value: 'open', height: 36, child: Text('Open')),
        PopupMenuItem(value: 'remove', height: 36, child: Text('Remove')),
      ],
    );
    if (choice == 'open') widget.onOpen?.call();
    if (choice == 'remove') widget.onRemove?.call();
  }
}

/// What a play button is called, which is what pressing it does next.
///
/// Shared by the chip and the recording's dialog so the two never describe
/// the same recording differently. After a failure the press still tries
/// again, and the name says why the last one did not work.
String voicePlayButtonLabel({
  required bool playing,
  required bool opening,
  VoicePlaybackFailure? failure,
}) {
  if (playing) return 'Pause';
  if (opening) return 'Cancel';
  return switch (failure) {
    VoicePlaybackFailure.notDownloaded => "Couldn't download. Try again",
    VoicePlaybackFailure.unreadable => "Couldn't play this recording",
    null => 'Play',
  };
}

/// The face of a play button: a spinner while the recording is on its way,
/// otherwise the icon for what a press does.
class VoicePlayGlyph extends StatelessWidget {
  const VoicePlayGlyph({
    super.key,
    required this.playing,
    required this.opening,
    this.failure,
    this.size,
    this.color,
  });

  final bool playing;
  final bool opening;
  final VoicePlaybackFailure? failure;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    if (opening) {
      final icon = IconTheme.of(context);
      return Center(
        child: SizedBox.square(
          dimension: (size ?? icon.size ?? 24) * 0.8,
          child: CircularProgressIndicator(
            strokeWidth: 1.75,
            color: color ?? icon.color,
          ),
        ),
      );
    }
    return KapyIcon(
      playing
          ? KapyIcons.pauseRounded
          : switch (failure) {
              VoicePlaybackFailure.notDownloaded => KapyIcons.cloudOffRounded,
              VoicePlaybackFailure.unreadable => KapyIcons.warningRounded,
              null => KapyIcons.playRounded,
            },
      size: size,
      color: color,
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({
    required this.playing,
    required this.opening,
    this.failure,
    this.onPressed,
    required this.size,
    required this.glyph,
  });

  final bool playing;
  final bool opening;
  final VoicePlaybackFailure? failure;
  final VoidCallback? onPressed;

  /// The tonal circle the recording's window plays from, at the card's size,
  /// and its glyph, centred in it rather than stretched to fill it.
  final double size;
  final double glyph;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = voicePlayButtonLabel(
      playing: playing,
      opening: opening,
      failure: failure,
    );
    return Semantics(
      button: true,
      label: label,
      child: _hoverHint(
        onPressed == null ? null : label,
        SizedBox.square(
          dimension: size,
          child: Material(
            color: palette.tonalBackground,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: Center(
                child: VoicePlayGlyph(
                  playing: playing,
                  opening: opening,
                  failure: failure,
                  size: glyph,
                  color: palette.tonalForeground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Waveform extends StatelessWidget {
  const _Waveform({
    required this.peaks,
    required this.progress,
    required this.played,
    required this.unplayed,
    this.onSeekFraction,
    this.bars,
    this.band = EdgeInsets.zero,
  });

  final Uint8List? peaks;
  final ValueListenable<double?> progress;
  final Color played;
  final Color unplayed;
  final ValueChanged<double>? onSeekFraction;
  final int? bars;

  /// Where in its box the bars are drawn. A press anywhere in the box skips.
  final EdgeInsets band;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => _hoverHint(
        onSeekFraction == null ? null : 'Skip to a point',
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: onSeekFraction == null
              ? null
              : (details) => onSeekFraction!(
                  (details.localPosition.dx / constraints.maxWidth).clamp(
                    0.0,
                    1.0,
                  ),
                ),
          child: Padding(
            padding: band,
            child: ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (context, value, _) => CustomPaint(
                size: Size(
                  constraints.maxWidth - band.horizontal,
                  constraints.maxHeight - band.vertical,
                ),
                painter: VoiceWaveformPainter(
                  peaks: peaks,
                  progress: value,
                  played: played,
                  unplayed: unplayed,
                  bars: bars,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws the 100 precomputed levels as bars, filled up to the play head.
class VoiceWaveformPainter extends CustomPainter {
  VoiceWaveformPainter({
    required this.peaks,
    required this.progress,
    required this.played,
    required this.unplayed,
    this.bars,
  });

  final Uint8List? peaks;
  final double? progress;
  final Color played;
  final Color unplayed;

  /// Drawn as this many 3px bars with 2px between them, each as loud as the
  /// loudest level it stands for, rather than one hairline per level.
  final int? bars;

  @override
  void paint(Canvas canvas, Size size) {
    final levels = peaks;
    // A recording from a client that never wrote peaks, or one still being
    // adopted: a flat line reads as "no waveform", not as silence.
    if (levels == null || levels.isEmpty || size.width <= 0) return;
    final count = bars ?? levels.length;

    final barWidth = size.width / count;
    final head = (progress ?? 0) * size.width;
    final paint = Paint()..strokeCap = StrokeCap.round;

    for (var i = 0; i < count; i++) {
      final from = i * levels.length ~/ count;
      final to = math.max(from + 1, (i + 1) * levels.length ~/ count);
      final level = levels.sublist(from, to).reduce(math.max) / 255;
      // A floor, so silence is still a visible line rather than a gap.
      final height = (size.height * level).clamp(2.0, size.height);
      final x = i * barWidth + barWidth / 2;
      paint
        ..strokeWidth = bars == null ? barWidth * 0.6 : barWidth - 2
        ..color = progress != null && x <= head ? played : unplayed;
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(VoiceWaveformPainter old) =>
      old.progress != progress ||
      old.peaks != peaks ||
      old.played != played ||
      old.unplayed != unplayed ||
      old.bars != bars;
}

/// `m:ss`, or `h:mm:ss` past an hour. Recordings are capped at thirty minutes,
/// so the third case is only reachable by a note from another client.
String formatVoiceDuration(Duration duration) {
  final seconds = duration.inSeconds;
  final s = (seconds % 60).toString().padLeft(2, '0');
  final m = (seconds ~/ 60) % 60;
  final h = seconds ~/ 3600;
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
  return '$m:$s';
}
