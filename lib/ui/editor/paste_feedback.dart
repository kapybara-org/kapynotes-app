import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../keycap.dart';

/// A converted paste, kept for the feedback it gets: where it landed, the
/// note's text just after it, and what Plain text instead writes over it.
@immutable
class ConvertedPaste {
  const ConvertedPaste({
    required this.range,
    required this.text,
    required this.plainText,
  });

  /// What the paste wrote, in [text].
  final TextRange range;

  /// The note's text just after the paste. Once the note holds anything
  /// else, [range] no longer says where the paste is.
  final String text;

  /// What replaces [range] for Plain text instead: the clipboard's plain
  /// text, after whatever of the note the paste took in front of the
  /// selection, so the swap writes what Paste as plain text would have.
  final String plainText;
}

/// The sage wash over what a converted paste wrote, fading out over
/// [duration]: Paper's DUD-0 in dark and EE6-0 in light.
class PasteWash extends StatefulWidget {
  const PasteWash({super.key, required this.rows, required this.repaint});

  /// The rows the paste wrote, across the writing column, in this widget's
  /// coordinates; null while they can't be measured.
  final Rect? Function() rows;

  /// What moves those rows, such as the note scrolling.
  final Listenable repaint;

  static const duration = Duration(milliseconds: 1500);

  @override
  State<PasteWash> createState() => _PasteWashState();
}

class _PasteWashState extends State<PasteWash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: PasteWash.duration,
  )..forward();

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The selection's sage at half its strength, within a point of Paper's
    // 14% in dark and 10% in light.
    final selection = context.palette.selection;
    return CustomPaint(
      painter: _WashPainter(
        rows: widget.rows,
        fade: _fade,
        color: selection.withValues(alpha: selection.a / 2),
        repaint: Listenable.merge([_fade, widget.repaint]),
      ),
    );
  }
}

class _WashPainter extends CustomPainter {
  _WashPainter({
    required this.rows,
    required this.fade,
    required this.color,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final Rect? Function() rows;
  final Animation<double> fade;
  final Color color;

  /// How far the wash reaches past the rows, and how round it is.
  static const _outset = EdgeInsets.symmetric(horizontal: 8, vertical: 4);
  static const _radius = Radius.circular(8);

  @override
  void paint(Canvas canvas, Size size) {
    final strength = 1 - Curves.easeInCubic.transform(fade.value);
    final area = strength == 0 ? null : rows();
    if (area == null) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(_outset.inflateRect(area), _radius),
      Paint()..color = color.withValues(alpha: color.a * strength),
    );
  }

  @override
  bool shouldRepaint(_WashPainter oldDelegate) => true;

  @override
  bool hitTest(Offset position) => false;
}

/// The chip a converted paste leaves at its end and the menu it opens:
/// Keep formatting or Plain text instead, and the key that pastes plain
/// next time. Paper's direction B: DUT-0 and DV1-0 in dark, EEM-0 and
/// EEU-0 in light.
///
/// It fills its parent and hangs from [caret], the caret at the end of the
/// paste in the parent's coordinates: below it, or above when there is no
/// room below. It stays until the next keystroke or click and then, as
/// after Keep formatting, asks to go with [onDismissed].
class PasteChip extends StatefulWidget {
  const PasteChip({
    super.key,
    required this.caret,
    required this.onPlainText,
    required this.onDismissed,
    this.shortcut,
  });

  final Rect caret;
  final VoidCallback onPlainText;
  final VoidCallback onDismissed;

  /// Paste as plain text's keys as a keycap prints them; the menu teaches
  /// them unless there are none.
  final String? shortcut;

  @override
  State<PasteChip> createState() => _PasteChipState();
}

class _PasteChipState extends State<PasteChip> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is KeyDownEvent) widget.onDismissed();
    return false;
  }

  // A click on the chip is a click in the note, which keeps its caret.
  @override
  Widget build(BuildContext context) => TextFieldTapRegion(
    child: TapRegion(
      onTapOutside: (_) => widget.onDismissed(),
      child: CustomMultiChildLayout(
        delegate: _PasteChipLayout(widget.caret),
        children: [
          LayoutId(
            id: _Part.chip,
            child: _Chip(
              open: _open,
              onTap: () => setState(() => _open = !_open),
            ),
          ),
          if (_open)
            LayoutId(
              id: _Part.menu,
              child: _Menu(
                shortcut: widget.shortcut,
                onKeep: widget.onDismissed,
                onPlainText: widget.onPlainText,
              ),
            ),
        ],
      ),
    ),
  );
}

enum _Part { chip, menu }

class _PasteChipLayout extends MultiChildLayoutDelegate {
  _PasteChipLayout(this.caret);

  final Rect caret;

  /// Where Paper hangs the chip from the caret: its icon under it, and its
  /// top a little over half a row below.
  static const _hang = Offset(-18, 16);

  /// Between the chip and its menu.
  static const double _gap = 6;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(size);
    final chip = layoutChild(_Part.chip, loose);
    final below = caret.bottom + _hang.dy;
    final top = below + chip.height <= size.height
        ? below
        : caret.top - _hang.dy - chip.height;
    final left = _within(caret.left + _hang.dx, size.width - chip.width);
    positionChild(_Part.chip, Offset(left, top));
    if (!hasChild(_Part.menu)) return;
    final menu = layoutChild(_Part.menu, loose);
    final under = top + chip.height + _gap;
    positionChild(
      _Part.menu,
      Offset(
        _within(left, size.width - menu.width),
        under + menu.height <= size.height ? under : top - _gap - menu.height,
      ),
    );
  }

  static double _within(double x, double max) => math.max(0, math.min(x, max));

  @override
  bool shouldRelayout(_PasteChipLayout oldDelegate) =>
      oldDelegate.caret != caret;
}

/// Chrome type on a 16px line.
TextStyle _type(double size, FontWeight weight, Color color) => TextStyle(
  fontSize: size,
  height: 16 / size,
  leadingDistribution: TextLeadingDistribution.even,
  fontWeight: AppWeight.font(AppWeight.axisOf(weight)),
  fontVariations: AppWeight.wght(AppWeight.axisOf(weight)),
  color: color,
);

class _Chip extends StatelessWidget {
  const _Chip({required this.open, required this.onTap});

  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      expanded: open,
      label: 'Formatted',
      hint: 'Paste options',
      excludeSemantics: true,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: const ValueKey('paste-chip'),
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 24,
            padding: const EdgeInsets.only(left: 8, right: 7),
            decoration: BoxDecoration(
              color: palette.controlBackground,
              border: Border.all(color: palette.selectedBorder),
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 5,
              children: [
                KapyIcon(
                  KapyIcons.clipboardOutlined,
                  size: 13,
                  color: palette.textSecondary,
                ),
                Text(
                  'Formatted',
                  style: _type(
                    AppTypeScale.small,
                    FontWeight.w500,
                    palette.textSubheading,
                  ),
                ),
                KapyIcon(
                  KapyIcons.chevronDownRounded,
                  size: 11,
                  color: palette.textTertiary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Menu extends StatefulWidget {
  const _Menu({
    required this.shortcut,
    required this.onKeep,
    required this.onPlainText,
  });

  final String? shortcut;
  final VoidCallback onKeep;
  final VoidCallback onPlainText;

  @override
  State<_Menu> createState() => _MenuState();
}

class _MenuState extends State<_Menu> {
  /// Keep formatting is lit until the pointer reaches Plain text instead.
  bool _plainLit = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final shortcut = widget.shortcut;
    return Container(
      key: const ValueKey('paste-menu'),
      width: 250,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: palette.controlBackground,
        border: Border.all(color: palette.separator),
        borderRadius: BorderRadius.circular(AppRadii.surface),
        boxShadow: [
          BoxShadow(
            color: palette.shadowAt(0x80),
            offset: const Offset(0, 12),
            blurRadius: 28,
            spreadRadius: -14,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MenuRow(
            key: const ValueKey('paste-keep-formatting'),
            label: 'Keep formatting',
            ticked: true,
            lit: !_plainLit,
            onHover: () => setState(() => _plainLit = false),
            onTap: widget.onKeep,
          ),
          _MenuRow(
            key: const ValueKey('paste-plain-text'),
            label: 'Plain text instead',
            ticked: false,
            lit: _plainLit,
            onHover: () => setState(() => _plainLit = true),
            onTap: widget.onPlainText,
          ),
          if (shortcut != null) ...[
            Container(
              height: 1,
              margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              color: palette.separator,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              child: Row(
                spacing: 6,
                children: [
                  Text(
                    'Next time, paste plain with',
                    style: _type(
                      AppTypeScale.small,
                      FontWeight.w400,
                      palette.textTertiary,
                    ),
                  ),
                  Keycap(shortcut),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    super.key,
    required this.label,
    required this.ticked,
    required this.lit,
    required this.onHover,
    required this.onTap,
  });

  final String label;
  final bool ticked;
  final bool lit;
  final VoidCallback onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      button: true,
      checked: ticked,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(),
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: lit ? palette.selectedBackground : null,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: Row(
              spacing: 9,
              children: [
                SizedBox(
                  width: 14,
                  child: ticked
                      ? KapyIcon(
                          KapyIcons.checkRounded,
                          size: 14,
                          color: palette.accentText,
                        )
                      : null,
                ),
                Text(
                  label,
                  style: _type(14, FontWeight.w400, palette.textPrimary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
