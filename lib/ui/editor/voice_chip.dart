
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/note_attachment.dart';
import 'note_image_layout.dart';

/// How tall a recording sits in the text.
///
/// Fixed, and the same whatever the recording holds: a chip that grew once a
/// transcript arrived would reflow the note under whoever was reading it.
const double noteVoiceChipHeight = 56;

/// What the chip says about a recording beyond the recording itself.
enum VoiceChipState {
  /// Nothing more is coming — no account, or transcription is off.
  idle,

  /// Queued, but the device is offline.
  waiting,

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
}

/// A recording, sitting in the body of a note.
///
/// Drawn as one row rather than a player: a note holding six recordings should
/// read as a note, not as six media players stacked up. The waveform is the
/// only picture, it is precomputed to 100 bytes, and it repaints inside its own
/// boundary while playback moves so the text above it does nothing.
class NoteVoiceChip extends StatelessWidget {
  const NoteVoiceChip({
    super.key,
    required this.ref,
    required this.state,
    required this.progress,
    required this.playing,
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

  final VoidCallback? onPlayPause;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;
  final ValueChanged<double>? onSeekFraction;

  String get _label {
    final summary = ref.summary;
    return switch (state) {
      VoiceChipState.done when summary != null => summary.title,
      VoiceChipState.done => 'Voice note',
      VoiceChipState.transcribing => 'Transcribing…',
      VoiceChipState.summarising => 'Summarising…',
      VoiceChipState.waiting => 'Waiting for connection',
      VoiceChipState.failed => "Couldn't transcribe",
      VoiceChipState.outOfMinutes => 'Out of minutes',
      VoiceChipState.needsConsent => 'Voice note',
      VoiceChipState.idle => summary?.title ?? 'Voice note',
    };
  }

  /// A state the user could act on is drawn in the secondary colour rather
  /// than as an error: a recording that failed to transcribe is still a
  /// perfectly good recording, and nothing has been lost.
  bool get _isTransient =>
      state == VoiceChipState.transcribing ||
      state == VoiceChipState.summarising ||
      state == VoiceChipState.waiting;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: '$_label, ${formatVoiceDuration(ref.duration)}',
      button: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: noteImageGap),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          onSecondaryTapDown: onRemove == null
              ? null
              : (details) => _showMenu(context, details.globalPosition),
          onLongPressStart: onRemove == null
              ? null
              : (details) => _showMenu(context, details.globalPosition),
          child: Container(
            height: noteVoiceChipHeight,
            decoration: BoxDecoration(
              color: palette.controlBackground,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: palette.controlBorder),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _PlayButton(playing: playing, onPressed: onPlayPause),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: _isTransient
                              ? palette.textSecondary
                              : palette.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 20,
                        child: RepaintBoundary(
                          child: _Waveform(
                            peaks: ref.peaks,
                            progress: progress,
                            played: palette.textPrimary,
                            unplayed: palette.textTertiary,
                            onSeekFraction: onSeekFraction,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatVoiceDuration(ref.duration),
                  style: TextStyle(
                    fontSize: 11,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: palette.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'open', height: 36, child: Text('Open')),
        PopupMenuItem(value: 'remove', height: 36, child: Text('Remove')),
      ],
    );
    if (choice == 'open') onOpen?.call();
    if (choice == 'remove') onRemove?.call();
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, this.onPressed});

  final bool playing;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      label: playing ? 'Pause' : 'Play',
      child: SizedBox(
        width: 36,
        height: 36,
        child: Material(
          color: palette.selectedBackground,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Icon(
              playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              size: 20,
              color: palette.textPrimary,
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
  });

  final Uint8List? peaks;
  final ValueListenable<double?> progress;
  final Color played;
  final Color unplayed;
  final ValueChanged<double>? onSeekFraction;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: onSeekFraction == null
            ? null
            : (details) => onSeekFraction!(
                (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0),
              ),
        child: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (context, value, _) => CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: VoiceWaveformPainter(
              peaks: peaks,
              progress: value,
              played: played,
              unplayed: unplayed,
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
  });

  final Uint8List? peaks;
  final double? progress;
  final Color played;
  final Color unplayed;

  @override
  void paint(Canvas canvas, Size size) {
    final levels = peaks;
    // A recording from a client that never wrote peaks, or one still being
    // adopted: a flat line reads as "no waveform", not as silence.
    final count = levels == null || levels.isEmpty ? 0 : levels.length;
    if (count == 0 || size.width <= 0) return;

    final barWidth = size.width / count;
    final head = (progress ?? 0) * size.width;
    final paint = Paint()..strokeCap = StrokeCap.round;

    for (var i = 0; i < count; i++) {
      final level = levels![i] / 255;
      // A floor, so silence is still a visible line rather than a gap.
      final height = (size.height * level).clamp(2.0, size.height);
      final x = i * barWidth + barWidth / 2;
      paint
        ..strokeWidth = barWidth * 0.6
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
      old.unplayed != unplayed;
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
