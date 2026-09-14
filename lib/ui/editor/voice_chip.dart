import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../audio/voice_player.dart';
import '../../core/theme.dart';
import '../../data/note_attachment.dart';
import '../context_menu.dart';
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
    : Tooltip(
        message: message,
        triggerMode: TooltipTriggerMode.manual,
        child: child,
      );

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

  String get _label {
    final summary = ref.summary;
    return switch (state) {
      VoiceChipState.done when summary != null => summary.title,
      VoiceChipState.done => 'Voice note',
      VoiceChipState.transcribing => 'Transcribing…',
      VoiceChipState.summarising => 'Summarising…',
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
      VoiceChipState.idle => summary?.title ?? 'Voice note',
    };
  }

  /// What clicking the row does, which the label does not say.
  ///
  /// Named after what is on the other side of the click rather than after the
  /// recording's state: someone hovering is asking where this goes.
  String? get _openHint {
    if (onOpen == null) return null;
    if (ref.transcript != null) return 'Read the transcript';
    return switch (state) {
      VoiceChipState.needsConsent => 'Turn transcription on in Settings',
      VoiceChipState.needsAccount => 'Choose transcription in Settings',
      VoiceChipState.failed when ref.transcript != null =>
        'Read the transcript or try the summary again',
      VoiceChipState.failed => 'Try transcribing again',
      _ => 'Open this recording',
    };
  }

  /// A state the user could act on is drawn in the secondary colour rather
  /// than as an error: a recording that failed to transcribe is still a
  /// perfectly good recording, and nothing has been lost.
  bool get _isTransient =>
      state == VoiceChipState.transcribing ||
      state == VoiceChipState.summarising ||
      state == VoiceChipState.waiting ||
      state == VoiceChipState.retrying;

  String? get _summaryPreview {
    final summary = ref.summary;
    if (summary == null) return null;
    final points = summary.points
        .map((point) => point.trim())
        .where((point) => point.isNotEmpty)
        .join(' ');
    return points.isEmpty ? summary.title.trim() : points;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: '$_label, ${formatVoiceDuration(ref.duration)}',
      button: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: noteImageGap),
        child: MouseRegion(
          // A recording is not text, and every part of the row does something.
          cursor:
              onOpen == null && onPlayPause == null && onSeekFraction == null
              ? MouseCursor.defer
              : SystemMouseCursors.click,
          child: _hoverHint(
            _openHint,
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onOpen,
              onSecondaryTapDown: onRemove == null
                  ? null
                  : (details) => _showMenu(context, details.globalPosition),
              onLongPressStart: onRemove == null
                  ? null
                  : (details) => _showMenu(context, details.globalPosition),
              child: Stack(
                children: [
                  Container(
                    height: noteVoiceChipHeight,
                    decoration: BoxDecoration(
                      color: palette.controlBackground,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: palette.controlBorder),
                    ),
                    padding: EdgeInsets.only(
                      left: 8,
                      right: onRemove == null ? 8 : 34,
                    ),
                    child: Row(
                      children: [
                        _PlayButton(
                          playing: playing,
                          opening: opening,
                          failure: failure,
                          onPressed: onPlayPause,
                        ),
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
                                  fontSize: AppTypeScale.small,
                                  color: _isTransient
                                      ? palette.textSecondary
                                      : palette.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              if (_summaryPreview case final preview?)
                                Text(
                                  preview,
                                  key: const ValueKey('voice-summary-preview'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppTypeScale.caption,
                                    color: palette.textSecondary,
                                  ),
                                )
                              else
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
                            fontSize: AppTypeScale.caption,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: palette.textSecondary,
                          ),
                        ),
                        if (_summaryPreview != null) ...[
                          const SizedBox(width: 4),
                          Text(
                            '...',
                            key: const ValueKey('voice-summary-more'),
                            style: TextStyle(
                              fontSize: AppTypeScale.caption,
                              color: palette.textTertiary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (onRemove != null)
                    Positioned(
                      top: 2,
                      right: 2,
                      child: Tooltip(
                        message: 'Remove voice note',
                        child: IconButton(
                          key: const ValueKey('remove-voice-note'),
                          onPressed: onRemove,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(
                            width: 28,
                            height: 28,
                          ),
                          icon: KapyIcon(
                            KapyIcons.closeRounded,
                            size: 16,
                            color: palette.textSecondary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final choice = await showKapyContextMenu<String>(
      context: context,
      globalPosition: position,
      items: const [
        PopupMenuItem(value: 'open', height: 36, child: Text('Open')),
        PopupMenuItem(value: 'remove', height: 36, child: Text('Remove')),
      ],
    );
    if (choice == 'open') onOpen?.call();
    if (choice == 'remove') onRemove?.call();
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
  });

  final bool playing;
  final bool opening;
  final VoicePlaybackFailure? failure;
  final VoidCallback? onPressed;

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
        SizedBox(
          width: 36,
          height: 36,
          child: Material(
            color: palette.selectedBackground,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onPressed,
              child: VoicePlayGlyph(
                playing: playing,
                opening: opening,
                failure: failure,
                size: 20,
                // Quieter rather than red: a recording that did not start is
                // still a perfectly good recording.
                color: failure == null && !opening
                    ? palette.textPrimary
                    : palette.textSecondary,
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
  });

  final Uint8List? peaks;
  final ValueListenable<double?> progress;
  final Color played;
  final Color unplayed;
  final ValueChanged<double>? onSeekFraction;

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
