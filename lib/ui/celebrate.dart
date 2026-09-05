import 'dart:math';

import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';

/// Small, brief celebrations for the moments worth one.
///
/// Deliberately drawn in an overlay rather than in the editor: the note is a
/// text field, and nothing here should be able to affect its layout, its
/// selection, or what it computes. The overlay is also why a burst survives
/// the line it came from being re-laid-out underneath it.
///
/// Everything is short and small on purpose. A checkbox is ticked dozens of
/// times a day, so the reward for one has to be closer to a nod than to a
/// fanfare — something that reads at the edge of vision and is gone before it
/// can be in the way.
class Celebrate {
  const Celebrate._();

  /// How long a burst lives. Short enough that a fast reader ticking four
  /// boxes gets four of them without them piling up.
  /// Findable in tests: whether a celebration fired, and which kind, is
  /// behaviour worth pinning down even though what it looks like is not.
  static const burstKey = ValueKey('celebration-burst');
  static const finaleKey = ValueKey('celebration-finale');

  static const _burst = Duration(milliseconds: 620);
  static const _finale = Duration(milliseconds: 1150);

  /// A handful of confetti at [origin], in global coordinates.
  ///
  /// [finale] makes the last-checkmark burst a little fuller. Kapy is kept out
  /// of checklist completion so the mascot can remain a quiet editor-idle
  /// moment rather than a reward attached to task management.
  static void at(BuildContext context, Offset origin, {bool finale = false}) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    // Someone who has asked the system for less motion has asked for this
    // too, and a burst of particles is exactly what that setting is about.
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) return;

    final palette = context.palette;
    final accent = Theme.of(context).colorScheme.primary;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _Celebration(
        origin: origin,
        palette: palette,
        accent: accent,
        finale: finale,
        onDone: () {
          if (entry.mounted) entry.remove();
        },
      ),
    );
    overlay.insert(entry);
  }
}

class _Celebration extends StatefulWidget {
  const _Celebration({
    required this.origin,
    required this.palette,
    required this.accent,
    required this.finale,
    required this.onDone,
  });

  final Offset origin;
  final CalcPalette palette;
  final Color accent;
  final bool finale;
  final VoidCallback onDone;

  @override
  State<_Celebration> createState() => _CelebrationState();
}

class _CelebrationState extends State<_Celebration>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.finale ? Celebrate._finale : Celebrate._burst,
  );

  late final List<_Fleck> _flecks;

  @override
  void initState() {
    super.initState();
    // Seeded off the origin so a burst is stable across the rebuilds the
    // overlay does while it runs, without being identical every time.
    final random = Random(widget.origin.hashCode);
    // The theme runs on two accents — one cyan for calculation, one green
    // for results — and every chip colour is that same green. Taking five of
    // them would have produced monochrome confetti; these are the colours the
    // app actually has, plus a neutral so the burst is not just two hues.
    final colors = [
      widget.palette.chipNumber,
      widget.accent,
      widget.palette.textSecondary,
    ];
    _flecks = List.generate(widget.finale ? 18 : 11, (index) {
      // Fanned upward — confetti that starts by going down reads as falling
      // debris rather than as something being thrown.
      final angle = -pi / 2 + (random.nextDouble() - 0.5) * 2.1;
      return _Fleck(
        angle: angle,
        speed: 46 + random.nextDouble() * (widget.finale ? 66 : 42),
        size: 2.2 + random.nextDouble() * 1.9,
        spin: (random.nextDouble() - 0.5) * 7,
        color: colors[index % colors.length],
        delay: random.nextDouble() * 0.12,
        flip: random.nextDouble() * pi * 2,
      );
    });
    _controller.forward().whenComplete(widget.onDone);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Positioned.fill because an overlay entry is a child of the overlay's
    // Stack: left unpositioned it takes loose constraints, and a Stack whose
    // children are all positioned then collapses to nothing and paints
    // nothing with it.
    //
    // IgnorePointer because the editor beneath must keep every pointer event
    // it would otherwise have had.
    return Positioned.fill(
      key: widget.finale ? Celebrate.finaleKey : Celebrate.burstKey,
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _FleckPainter(
                    flecks: _flecks,
                    origin: widget.origin,
                    t: _controller.value,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Fleck {
  const _Fleck({
    required this.angle,
    required this.speed,
    required this.size,
    required this.spin,
    required this.color,
    required this.delay,
    required this.flip,
  });

  final double angle;
  final double speed;
  final double size;
  final double spin;
  final Color color;
  final double delay;

  /// Where in its turn the piece starts, so they do not all show their edge
  /// on the same frame.
  final double flip;
}

class _FleckPainter extends CustomPainter {
  const _FleckPainter({
    required this.flecks,
    required this.origin,
    required this.t,
  });

  final List<_Fleck> flecks;
  final Offset origin;
  final double t;

  /// Enough to bring the flecks back down inside the life of the burst
  /// without them shooting off the top of the window first.
  static const double _gravity = 190;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (final fleck in flecks) {
      final local = ((t - fleck.delay) / (1 - fleck.delay)).clamp(0.0, 1.0);
      if (local <= 0) continue;
      final dx = cos(fleck.angle) * fleck.speed * local;
      final dy =
          sin(fleck.angle) * fleck.speed * local +
          _gravity * local * local * 0.5;
      // Held at full strength for the first half, so the burst registers
      // before it starts leaving.
      final opacity = local < 0.5 ? 1.0 : 1 - (local - 0.5) * 2;
      paint.color = fleck.color.withValues(alpha: opacity.clamp(0.0, 1.0));

      // Real confetti turns over as it falls, showing its edge and then its
      // face again. Squeezing the width on a second, faster cycle is enough
      // to read as that flip — without it these are just rotating rectangles,
      // which is the thing that gives a hand-rolled burst away.
      final flip = (cos(fleck.flip + local * 11) * 0.9).abs() + 0.1;

      canvas.save();
      canvas.translate(origin.dx + dx, origin.dy + dy);
      canvas.rotate(fleck.spin * local);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: fleck.size * flip,
            height: fleck.size * 1.7,
          ),
          const Radius.circular(1),
        ),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_FleckPainter old) => old.t != t;
}
