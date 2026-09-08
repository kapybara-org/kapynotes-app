import 'package:material_ui/material_ui.dart';

import '../../audio/voice_recording_controller.dart';
import '../../core/theme.dart';
import 'voice_chip.dart';

/// The strip that replaces the formatting row while a recording is running.
///
/// It takes the footer's place rather than floating over the note, because a
/// recording is a thing the note is doing, not a modal state of the app — and
/// because anything overlaying the text would cover the words being described.
class VoiceRecordingBar extends StatelessWidget {
  const VoiceRecordingBar({
    super.key,
    required this.session,
    this.onPause,
    this.onResume,
    this.onStop,
    this.onCancel,
  });

  final VoiceRecordingSession session;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onStop;
  final VoidCallback? onCancel;

  /// What the bar says it is doing. The distinction that matters is between a
  /// pause the user chose and one a phone call forced: only the second needs
  /// telling, because only it requires an action to undo.
  String get _status {
    if (session.finishing) return 'Saving…';
    if (session.interrupted) return 'Interrupted — resume to carry on';
    if (session.paused) return 'Paused';
    final left = VoiceRecordingController.maxDuration - session.elapsed;
    if (session.elapsed >= VoiceRecordingController.warnAfter) {
      return '${formatVoiceDuration(left)} left';
    }
    return 'Recording';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final active = !session.paused && !session.interrupted && !session.finishing;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        border: Border(top: BorderSide(color: palette.separator)),
      ),
      child: Row(
        children: [
          _Dot(active: active),
          const SizedBox(width: 8),
          Text(
            formatVoiceDuration(session.elapsed),
            style: TextStyle(
              fontSize: 13,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: palette.textSecondary),
            ),
          ),
          if (!session.finishing) ...[
            _BarButton(
              icon: session.paused || session.interrupted
                  ? Icons.play_arrow_rounded
                  : Icons.pause_rounded,
              tooltip: session.paused || session.interrupted ? 'Resume' : 'Pause',
              onPressed: session.paused || session.interrupted ? onResume : onPause,
            ),
            _BarButton(
              icon: Icons.close_rounded,
              tooltip: 'Discard',
              onPressed: onCancel,
            ),
            _BarButton(
              icon: Icons.check_rounded,
              tooltip: 'Stop and keep',
              onPressed: onStop,
            ),
          ],
        ],
      ),
    );
  }
}

/// The recording light. Steady rather than blinking: a pulse in the corner of
/// the eye is exactly the sort of thing this app does not do.
class _Dot extends StatelessWidget {
  const _Dot({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: active
            ? Theme.of(context).colorScheme.error
            : palette.textTertiary,
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({required this.icon, required this.tooltip, this.onPressed});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      color: context.palette.textPrimary,
    );
  }
}
