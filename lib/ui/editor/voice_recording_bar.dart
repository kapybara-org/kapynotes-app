import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../audio/voice_recording_controller.dart';
import '../../core/theme.dart';
import '../compact_icon_button.dart';
import 'voice_chip.dart';

/// The strip that replaces the formatting row while a recording is running.
///
/// It takes the footer's place rather than floating over the note, because a
/// recording is a thing the note is doing, not a modal state of the app — and
/// because anything overlaying the text would cover the words being described.
class VoiceRecordingBar extends StatefulWidget {
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

  @override
  State<VoiceRecordingBar> createState() => _VoiceRecordingBarState();
}

class _VoiceRecordingBarState extends State<VoiceRecordingBar> {
  /// Four seconds at the recorder's 10 Hz sampling cadence.
  ///
  /// Fixed for the whole session, so a thirty-minute recording costs exactly
  /// the same to draw as its first second.
  static const int _historyLength = 40;

  late final List<double> _levels = List.filled(
    _historyLength,
    0,
    growable: true,
  );
  late int _sampleSequence = widget.session.sampleSequence;
  late String _noteId = widget.session.noteId;

  @override
  void initState() {
    super.initState();
    if (_sampleSequence > 0) _pushLevel(widget.session.level);
  }

  @override
  void didUpdateWidget(VoiceRecordingBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final session = widget.session;
    if (session.noteId != _noteId || session.sampleSequence < _sampleSequence) {
      _levels.fillRange(0, _levels.length, 0);
      _noteId = session.noteId;
      _sampleSequence = 0;
    }
    if (session.sampleSequence != _sampleSequence) {
      _pushLevel(session.level);
      _sampleSequence = session.sampleSequence;
    }
  }

  void _pushLevel(double value) {
    _levels.removeAt(0);
    _levels.add(value.clamp(0.0, 1.0));
  }

  /// What the bar says it is doing. The distinction that matters is between a
  /// pause the user chose and one a phone call forced: only the second needs
  /// telling, because only it requires an action to undo.
  String get _status {
    final session = widget.session;
    if (session.finishing) return 'Saving voice note…';
    if (session.interrupted) return 'Recording interrupted';
    if (session.paused) return 'Recording paused';
    final left = VoiceRecordingController.maxDuration - session.elapsed;
    if (session.elapsed >= VoiceRecordingController.warnAfter) {
      return '${formatVoiceDuration(left)} left';
    }
    return 'Recording';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final session = widget.session;
    final active =
        !session.paused && !session.interrupted && !session.finishing;
    final elapsed = formatVoiceDuration(session.elapsed);
    final barHeight = AppControlMetrics.scaleBar(
      context,
      AppControlMetrics.footerHeight,
    );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: '$_status, $elapsed',
      liveRegion: session.interrupted || session.finishing,
      child: Container(
        height: barHeight,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: palette.surfaceBackground.withValues(alpha: 0.98),
          border: Border(top: BorderSide(color: palette.separator, width: 0.5)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 440;
            return Row(
              children: [
                _RecordingDot(level: session.level, active: active),
                const SizedBox(width: 8),
                if (!compact) ...[
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Text(
                      _status,
                      key: const ValueKey('recording-status'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTypeScale.control,
                        fontWeight: FontWeight.w600,
                        color: active
                            ? palette.textPrimary
                            : palette.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: _LiveWaveform(
                    levels: List.unmodifiable(_levels),
                    active: active,
                    finishing: session.finishing,
                    status: _status,
                    showStatus: compact,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  elapsed,
                  key: const ValueKey('recording-elapsed'),
                  style: TextStyle(
                    fontSize: AppTypeScale.control,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w600,
                    color: palette.textPrimary,
                  ),
                ),
                if (!session.finishing) ...[
                  const SizedBox(width: 8),
                  _RecordingActions(
                    paused: session.paused || session.interrupted,
                    onPause: widget.onPause,
                    onResume: widget.onResume,
                    onCancel: widget.onCancel,
                    onStop: widget.onStop,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The recording light responds to the same level as the waveform but never
/// blinks, so it confirms the microphone without becoming a distraction.
class _RecordingDot extends StatelessWidget {
  const _RecordingDot({required this.level, required this.active});

  final double level;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final recording = Theme.of(context).colorScheme.error;
    final response = active ? level.clamp(0.0, 1.0) : 0.0;
    return SizedBox.square(
      dimension: 12,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          curve: Curves.easeOut,
          width: 8 + response * 3,
          height: 8 + response * 3,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? recording : palette.textTertiary,
            boxShadow: active
                ? [
                    BoxShadow(
                      color: recording.withValues(
                        alpha: 0.16 + response * 0.22,
                      ),
                      blurRadius: 4 + response * 4,
                    ),
                  ]
                : null,
          ),
        ),
      ),
    );
  }
}

class _LiveWaveform extends StatelessWidget {
  const _LiveWaveform({
    required this.levels,
    required this.active,
    required this.finishing,
    required this.status,
    required this.showStatus,
  });

  final List<double> levels;
  final bool active;
  final bool finishing;
  final String status;
  final bool showStatus;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final recording = Theme.of(context).colorScheme.error;
    final showOverlay = finishing || (showStatus && !active);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      height: AppControlMetrics.footerButtonExtent - 8,
      decoration: BoxDecoration(
        color: active
            ? recording.withValues(alpha: 0.055)
            : palette.controlBackground.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active
              ? recording.withValues(alpha: 0.12)
              : palette.controlBorder.withValues(alpha: 0.72),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: RepaintBoundary(
              child: CustomPaint(
                key: const ValueKey('recording-waveform'),
                painter: RecordingWaveformPainter(
                  levels: levels,
                  color: recording,
                  active: active,
                ),
              ),
            ),
          ),
          if (showOverlay)
            ColoredBox(
              color: palette.controlBackground.withValues(alpha: 0.88),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (finishing) ...[
                      SizedBox.square(
                        dimension: AppControlMetrics.iconInline,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.75,
                          color: palette.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 7),
                    ],
                    if (showStatus)
                      Flexible(
                        child: Text(
                          status,
                          key: const ValueKey('recording-status'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTypeScale.caption,
                            fontWeight: FontWeight.w600,
                            color: palette.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _RecordingActions extends StatelessWidget {
  const _RecordingActions({
    required this.paused,
    this.onPause,
    this.onResume,
    this.onCancel,
    this.onStop,
  });

  final bool paused;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;
  final VoidCallback? onStop;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _ActionSlot(
        child: CompactIconButton(
          extent: AppControlMetrics.footerButtonExtent,
          icon: Icon(
            paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
            size: AppControlMetrics.footerIconAction,
          ),
          tooltip: paused ? 'Resume recording' : 'Pause recording',
          onPressed: paused ? onResume : onPause,
          foregroundColor: context.palette.textPrimary,
        ),
      ),
      _ActionSlot(
        child: CompactIconButton(
          extent: AppControlMetrics.footerButtonExtent,
          icon: Icon(
            Icons.delete_outline_rounded,
            size: AppControlMetrics.footerIconAction,
          ),
          tooltip: 'Discard recording',
          onPressed: onCancel,
          foregroundColor: context.palette.textSecondary,
        ),
      ),
      _StopButton(onPressed: onStop),
    ],
  );
}

class _ActionSlot extends StatelessWidget {
  const _ActionSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(right: AppControlMetrics.footerButtonGap),
    child: child,
  );
}

class _StopButton extends StatelessWidget {
  const _StopButton({this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final extent = AppControlMetrics.footerButtonExtent;
    final recording = Theme.of(context).colorScheme.error;
    return Tooltip(
      message: 'Stop and keep recording',
      child: Semantics(
        button: true,
        label: 'Stop and keep recording',
        child: IconButton(
          key: const ValueKey('recording-stop'),
          onPressed: onPressed,
          icon: Icon(
            Icons.stop_rounded,
            size: AppControlMetrics.footerIconAction,
          ),
          color: recording,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tightFor(width: extent, height: extent),
          visualDensity: VisualDensity.standard,
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size.square(extent)),
            maximumSize: WidgetStatePropertyAll(Size.square(extent)),
            tapTargetSize: AppControlMetrics.iconButtonTapTargetSize,
            foregroundColor: WidgetStatePropertyAll(recording),
            backgroundColor: WidgetStateProperty.resolveWith((states) {
              final alpha = states.contains(WidgetState.pressed)
                  ? 0.22
                  : states.contains(WidgetState.hovered) ||
                        states.contains(WidgetState.focused)
                  ? 0.17
                  : 0.12;
              return recording.withValues(alpha: alpha);
            }),
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ),
    );
  }
}

/// A bounded, live microphone history. New sound is brightest on the right;
/// older sound recedes so the direction is legible without an animated cursor.
class RecordingWaveformPainter extends CustomPainter {
  RecordingWaveformPainter({
    required this.levels,
    required this.color,
    required this.active,
  });

  final List<double> levels;
  final Color color;
  final bool active;

  @override
  void paint(Canvas canvas, Size size) {
    if (levels.isEmpty || size.width <= 0 || size.height <= 0) return;
    final slot = size.width / levels.length;
    final strokeWidth = math.min(3.0, math.max(1.0, slot * 0.52));
    final usableHeight = math.max(2.0, size.height - 2);
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = strokeWidth;

    for (var index = 0; index < levels.length; index++) {
      final level = levels[index].clamp(0.0, 1.0);
      // Square root expansion makes ordinary speech visible without making a
      // loud syllable slam into the edge of the meter.
      final height = 2 + math.sqrt(level) * (usableHeight - 2);
      final age = (index + 1) / levels.length;
      final alpha = (0.18 + age * 0.72) * (active ? 1 : 0.42);
      final x = slot * index + slot / 2;
      paint.color = color.withValues(alpha: alpha);
      canvas.drawLine(
        Offset(x, (size.height - height) / 2),
        Offset(x, (size.height + height) / 2),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(RecordingWaveformPainter oldDelegate) {
    return !identical(levels, oldDelegate.levels) ||
        color != oldDelegate.color ||
        active != oldDelegate.active;
  }
}
