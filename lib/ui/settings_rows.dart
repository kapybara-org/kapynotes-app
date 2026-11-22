import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import 'control_surface.dart';

/// The parts every settings pane is built from.
///
/// In a file of their own so that the panes living elsewhere — the account
/// and sharing ones — are made of the same rows, groups and headings as the
/// rest. Built out of their own forms and paragraphs, they read as a
/// different app wedged into the middle of settings.
/// How big a settings row is allowed to be.
///
/// A pointer can hit an eight-pixel gap and read eleven-point type; a thumb
/// can do neither. This is the same split [AppControlMetrics] already makes
/// for icon buttons, applied to the rows those buttons sit beside.
class SettingsMetrics {
  const SettingsMetrics._();

  static bool get _touch => !AppPlatform.hasPointer;

  static EdgeInsets get padding => _touch
      ? const EdgeInsets.symmetric(horizontal: 14, vertical: 12)
      : const EdgeInsets.symmetric(horizontal: 14, vertical: 10);

  /// The least a row is tall with a pointer: a title and its line of
  /// description, with room around them, so a pane of rows reads as a list
  /// of settings rather than a form.
  static double get minRowHeight => _touch ? 0 : 54;
  static double get gap => 12;
  static double get titleSize => _touch
      ? 15
      : AppPlatform.isWindows
      ? AppTypeScale.control
      : 14;
  static double get subtitleSize => _touch || AppPlatform.isWindows ? 13 : 12;
  static double get sectionLabelSize => _touch ? 11 : 14;
  static double get noteSize =>
      AppPlatform.isWindows ? AppTypeScale.caption : 11;
  static double get buttonLabelSize => _touch ? 12 : 13;
  static FontWeight get titleWeight =>
      AppWeight.named(AppWeight.rowTitle);
  static double get chevronSize => _touch ? 21 : 13;

  /// The height of a control at the end of a row: a button, a menu, a well.
  static double get controlHeight => _touch ? 32 : 28;

  /// Between one group and the heading of the next.
  static const double groupGap = 18;
}

/// The heading over a group, naming what the rows in it are about: a small
/// handwritten heading with a pointer, small capitals on a phone.
class SettingsLabel extends StatelessWidget {
  const SettingsLabel(this.text, {super.key, this.detail, this.caption});

  /// In sentence case. The phone sets it in capitals.
  final String text;

  /// A few words beside the heading, for a group whose rows share something
  /// the heading alone does not say.
  final String? detail;

  /// A line of its own under the heading, for a group whose heading needs a
  /// sentence rather than a few words.
  final String? caption;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final detail = this.detail;
    final caption = this.caption;
    if (AppPlatform.hasPointer) {
      // The heading yields to the line beside it when the two cannot share
      // the width; at every width they can, it keeps its natural size.
      final heading = LayoutBuilder(
        builder: (context, box) => Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(0, box.maxWidth - (detail == null ? 0 : 96)),
              ),
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: chromeStyle(
                  size: SettingsMetrics.sectionLabelSize,
                  line: 18,
                  weight: AppWeight.section,
                  color: palette.textSubheading,
                ),
              ),
            ),
            if (detail != null) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 16 / 12,
                    color: palette.textTertiary,
                  ),
                ),
              ),
            ],
          ],
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: caption == null
            ? heading
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  heading,
                  const SizedBox(height: 2),
                  Text(
                    caption,
                    style: TextStyle(
                      fontSize: 12,
                      height: 16 / 12,
                      color: palette.textTertiary,
                    ),
                  ),
                ],
              ),
      );
    }
    final label = Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: SettingsMetrics.sectionLabelSize,
        fontWeight: AppWeight.font(AppWeight.body),
        fontVariations: AppWeight.wght(AppWeight.body),
        letterSpacing: 0.65,
        color: palette.textTertiary,
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(left: 3, bottom: 7),
      child: caption == null
          ? label
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                label,
                const SizedBox(height: 4),
                Text(
                  caption,
                  style: TextStyle(
                    fontSize: SettingsMetrics.noteSize,
                    height: 1.4,
                    color: palette.textTertiary,
                  ),
                ),
              ],
            ),
    );
  }
}

/// A card of rows with hairlines between them.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final pointer = AppPlatform.hasPointer;
    final rows = Column(
      children: [
        for (var index = 0; index < children.length; index++) ...[
          if (index > 0)
            Divider(
              height: pointer ? 1 : 0.5,
              thickness: pointer ? 1 : 0.5,
              color: palette.separator,
            ),
          children[index],
        ],
      ],
    );
    if (!pointer) return KapyControlSurface(child: rows);
    // The outline is drawn inside the card's box, as the design measures it,
    // so the rows sit a hairline in from it.
    return KapyControlSurface(
      radius: AppRadii.surface,
      padding: const EdgeInsets.all(1),
      color: palette.cardBackground,
      borderColor: palette.controlBorder,
      child: rows,
    );
  }
}

/// The small print under a group: what it is for, or what it costs.
///
/// Below the rows rather than above them, so a pane reads as its controls
/// first. An [icon] marks the one note on a pane worth stopping for.
class SettingsNote extends StatelessWidget {
  const SettingsNote(this.text, {super.key, this.icon});

  final String text;
  final KapyIconData? icon;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = TextStyle(
      fontSize: SettingsMetrics.noteSize,
      height: 1.4,
      color: AppPlatform.isWindows
          ? palette.textSecondary
          : palette.textTertiary,
    );
    final icon = this.icon;
    return Padding(
      padding: const EdgeInsets.fromLTRB(3, 6, 3, 0),
      child: icon == null
          ? Text(text, style: style)
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1, right: 6),
                  child: KapyIcon(icon, size: 12, color: palette.textTertiary),
                ),
                Expanded(child: Text(text, style: style)),
              ],
            ),
    );
  }
}

/// The dot beside a setting that is no longer at its default.
class SettingsChangedDot extends StatelessWidget {
  const SettingsChangedDot({super.key});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    key: const ValueKey('settings-changed-dot'),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary,
      shape: BoxShape.circle,
    ),
    child: const SizedBox.square(dimension: 6),
  );
}

/// A row's words: what it is, and — optionally — a line saying more.
class SettingsRowCopy extends StatelessWidget {
  const SettingsRowCopy({
    super.key,
    required this.title,
    this.subtitle,
    this.titleColor,
    this.changed = false,
    this.tag,
  });

  final String title;
  final String? subtitle;
  final Color? titleColor;

  /// Marks the setting as moved off its default.
  final bool changed;

  /// Where the setting applies, when that is narrower than everywhere:
  /// "Mac and Windows".
  final String? tag;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final pointer = AppPlatform.hasPointer;
    final subtitle = this.subtitle;
    final tag = this.tag;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: chromeStyle(
                  size: SettingsMetrics.titleSize,
                  line: pointer ? 18 : null,
                  weight: AppWeight.rowTitle,
                  color: titleColor ?? palette.textPrimary,
                ),
              ),
            ),
            if (changed) ...[
              const SizedBox(width: 7),
              const SettingsChangedDot(),
            ],
            if (tag != null) ...[
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  tag,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: TextStyle(fontSize: 11, color: palette.textTertiary),
                ),
              ),
            ],
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: pointer ? 1 : 2,
            softWrap: !pointer,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: SettingsMetrics.subtitleSize,
              height: pointer ? 16 / SettingsMetrics.subtitleSize : null,
              color: pointer ? palette.textDescription : palette.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// The one row every other row is a kind of: its words, and whatever sits
/// at the end.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.subtitle,
    this.tag,
    this.trailing,
    this.wide = false,
    this.below,
    this.changed = false,
    this.onReset,
    this.onTap,
    this.destructive = false,
  });

  final String title;
  final String? subtitle;
  final String? tag;
  final Widget? trailing;

  /// Whether [trailing] is too wide to sit beside the words on a phone or in
  /// a narrow window, where it goes under them instead.
  final bool wide;

  /// Anything the row shows under its words: a download's progress.
  final Widget? below;

  /// Whether the setting is off its default, which puts a dot by its name and
  /// — given [onReset] — the button that puts it back.
  final bool changed;
  final VoidCallback? onReset;

  /// Null leaves the row as a statement rather than a control.
  final VoidCallback? onTap;

  /// Red, for the one or two rows that cannot be taken back.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    if (!wide || !AppPlatform.hasPointer) return _row(context, under: wide);
    return LayoutBuilder(
      builder: (context, constraints) =>
          _row(context, under: constraints.maxWidth < 560),
    );
  }

  Widget _row(BuildContext context, {required bool under}) {
    final danger = Theme.of(context).colorScheme.error;
    final onReset = changed ? this.onReset : null;
    final control = this.trailing;
    final trailing = onReset == null
        ? control
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SettingsResetButton(onPressed: onReset),
              if (control != null && !under) ...[
                const SizedBox(width: 4),
                control,
              ],
            ],
          );
    final below = this.below;
    final row = Container(
      constraints: BoxConstraints(minHeight: SettingsMetrics.minRowHeight),
      padding: SettingsMetrics.padding,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: SettingsRowCopy(
                  title: title,
                  subtitle: subtitle,
                  tag: tag,
                  changed: changed,
                  titleColor: destructive ? danger : null,
                ),
              ),
              if (under && onReset != null) ...[
                SizedBox(width: SettingsMetrics.gap),
                SettingsResetButton(onPressed: onReset),
              ] else if (!under && trailing != null) ...[
                SizedBox(width: SettingsMetrics.gap),
                trailing,
              ],
            ],
          ),
          if (under && control != null) ...[
            const SizedBox(height: 10),
            control,
          ],
          if (below != null) ...[const SizedBox(height: 10), below],
        ],
      ),
    );
    final onTap = this.onTap;
    if (onTap == null) return row;
    return Semantics(
      button: true,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// A row that is a switch, and flips from anywhere on it.
class SettingsToggleRow extends StatelessWidget {
  const SettingsToggleRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.tag,
    this.changed = false,
    this.onReset,
  });

  final String title;
  final String subtitle;
  final String? tag;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool changed;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final onChanged = this.onChanged;
    final row = SettingsRow(
      title: title,
      subtitle: subtitle,
      tag: tag,
      changed: changed,
      onReset: onReset,
      trailing: ExcludeSemantics(
        child: SettingsSwitch(value: value, enabled: onChanged != null),
      ),
    );
    return Semantics(
      toggled: value,
      button: true,
      enabled: onChanged != null,
      child: onChanged == null
          ? row
          : InkWell(onTap: () => onChanged(!value), child: row),
    );
  }
}

/// The small button at the end of a row.
class SettingsRowButton extends StatelessWidget {
  const SettingsRowButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.prominent = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;

  /// The sage tint, for the one action a row is there to offer: Get Pro.
  final bool prominent;

  /// Red, for an action that cannot be taken back.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final danger = Theme.of(context).colorScheme.error;
    final pointer = AppPlatform.hasPointer;
    final (background, foreground, border) = prominent
        ? (palette.tonalBackground, palette.tonalForeground, null)
        : destructive
        ? (
            danger.withValues(alpha: 0.1),
            danger,
            danger.withValues(alpha: 0.25),
          )
        : (
            palette.controlBackground,
            palette.textPrimary,
            palette.controlBorder,
          );
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: Size(0, SettingsMetrics.controlHeight),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: background,
        foregroundColor: foreground,
        disabledForegroundColor: palette.textTertiary,
        side: border == null
            ? null
            : BorderSide(
                color: border,
                width: pointer ? 1 : AppHairline.of(context),
              ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: SettingsMetrics.buttonLabelSize,
          fontWeight: AppWeight.font(AppWeight.body),
          fontVariations: AppWeight.wght(AppWeight.body),
          height: pointer ? 16 / 12.5 : null,
        ),
      ),
    );
  }
}

/// A row's current choice where the choice opens a list: "Last opened note",
/// with the chevron that says a list is behind it.
class SettingsMenuButton extends StatelessWidget {
  const SettingsMenuButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.leading,
    this.chevron = true,
  });

  final String label;
  final VoidCallback onPressed;

  /// What goes before the label: a theme's accent.
  final Widget? leading;

  /// Whether a list is behind it. A time is chosen from one too, but reads
  /// as a field.
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 220),
      child: TextButton(
        onPressed: onPressed,
        style: TextButton.styleFrom(
          minimumSize: Size(0, SettingsMetrics.controlHeight),
          padding: EdgeInsets.only(left: 10, right: chevron ? 8 : 10),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: palette.wellBackground,
          foregroundColor: palette.textPrimary,
          side: BorderSide(color: palette.controlBorder),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.control),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading case final leading?) ...[
              leading,
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: SettingsMetrics.buttonLabelSize),
              ),
            ),
            if (chevron) ...[
              const SizedBox(width: 6),
              KapyIcon(
                KapyIcons.chevronDownRounded,
                size: 13,
                color: palette.textTertiary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// What a row is set to, said quietly at its end, with a chevron where the
/// row opens somewhere.
class SettingsValue extends StatelessWidget {
  const SettingsValue(this.label, {super.key, this.chevron = true});

  final String label;
  final bool chevron;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: SettingsMetrics.buttonLabelSize,
              color: palette.textDescription,
            ),
          ),
        ),
        if (chevron) ...[
          const SizedBox(width: 6),
          KapyIcon(
            KapyIcons.chevronRightRounded,
            size: SettingsMetrics.chevronSize,
            color: palette.textTertiary,
          ),
        ],
      ],
    );
  }
}

/// Puts one setting back to its default.
class SettingsResetButton extends StatelessWidget {
  const SettingsResetButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final extent = AppPlatform.hasPointer ? 24.0 : 34.0;
    return IconButton(
      key: const ValueKey('settings-reset'),
      onPressed: onPressed,
      tooltip: 'Back to default',
      icon: const KapyIcon(KapyIcons.undoRounded, size: 14),
      color: context.palette.textTertiary,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: extent, height: extent),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.compact),
        ),
      ),
    );
  }
}

/// A choice between a few options a word can name — Light or Dark, Plain or
/// Ruled — set side by side in a sunken track.
class SettingsSegmented<T> extends StatelessWidget {
  const SettingsSegmented({
    super.key,
    required this.options,
    required this.selected,
    required this.labelFor,
    required this.keyFor,
    required this.onSelected,
    this.styleFor,
    this.enabledFor,
  });

  final List<T> options;
  final T selected;
  final String Function(T option) labelFor;

  /// Each option gets a key of its own, so a test can pick one by name.
  final Key Function(T option) keyFor;
  final ValueChanged<T> onSelected;

  /// A label set in what it names, as each writing font is.
  final TextStyle Function(T option)? styleFor;

  /// Whether an option can be chosen. One that cannot is still shown, dimmed,
  /// so the choice reads the same everywhere.
  final bool Function(T option)? enabledFor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final pointer = AppPlatform.hasPointer;
    Widget segment(T option) {
      final chosen = option == selected;
      final enabled = enabledFor?.call(option) ?? true;
      return Semantics(
        button: true,
        selected: chosen,
        enabled: enabled,
        inMutuallyExclusiveGroup: true,
        child: InkWell(
          key: keyFor(option),
          onTap: enabled && !chosen ? () => onSelected(option) : null,
          borderRadius: BorderRadius.circular(AppRadii.compact),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            height: pointer ? 26 : 30,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: chosen ? palette.segmentSelected : null,
              borderRadius: BorderRadius.circular(AppRadii.compact),
              boxShadow: chosen
                  ? [
                      BoxShadow(
                        color: palette.shadowAt(0x33),
                        offset: const Offset(0, 1),
                        blurRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: Text(
              labelFor(option),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (styleFor?.call(option) ?? const TextStyle()).copyWith(
                fontSize: SettingsMetrics.buttonLabelSize,
                height: 1.2,
                color: chosen
                    ? palette.textPrimary
                    : enabled
                    ? palette.textDescription
                    : palette.textTertiary.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.wellBackground,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: palette.controlBorder),
      ),
      child: Row(
        mainAxisSize: pointer ? MainAxisSize.min : MainAxisSize.max,
        children: [
          for (final option in options) ...[
            if (option != options.first) const SizedBox(width: 2),
            if (pointer)
              Flexible(child: segment(option))
            else
              Expanded(child: segment(option)),
          ],
        ],
      ),
    );
  }
}

/// A value stepped down or up a notch at a time: note text size.
class SettingsStepper extends StatelessWidget {
  const SettingsStepper({
    super.key,
    required this.label,
    required this.onDecrease,
    required this.onIncrease,
  });

  final String label;

  /// Null at the end of the range.
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final height = AppPlatform.hasPointer ? 30.0 : 34.0;
    Widget step(
      KapyIconData icon,
      String tooltip,
      Key key,
      VoidCallback? onTap,
    ) => Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: SizedBox(
          width: 30,
          height: height - 2,
          child: Center(
            child: KapyIcon(
              icon,
              size: 14,
              color: onTap == null
                  ? palette.textTertiary.withValues(alpha: 0.5)
                  : palette.textSecondary,
            ),
          ),
        ),
      ),
    );
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: palette.wellBackground,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(color: palette.controlBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          step(
            KapyIcons.removeRounded,
            'Smaller',
            const ValueKey('stepper-down'),
            onDecrease,
          ),
          Container(
            constraints: const BoxConstraints(minWidth: 44),
            height: height - 2,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              border: Border.symmetric(
                vertical: BorderSide(color: palette.controlBorder),
              ),
            ),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: AppPlatform.monoFontFallback.first,
                fontFamilyFallback: AppPlatform.monoFontFallback,
                fontSize: 12,
                fontWeight: AppWeight.font(AppWeight.body),
                fontVariations: AppWeight.wght(AppWeight.body),
                fontFeatures: const [FontFeature.tabularFigures()],
                color: palette.textPrimary,
              ),
            ),
          ),
          step(
            KapyIcons.addRounded,
            'Larger',
            const ValueKey('stepper-up'),
            onIncrease,
          ),
        ],
      ),
    );
  }
}

/// How much of an allowance is gone, as a 14 px clock face filling in: the
/// smallest mark that still reads as a proportion.
class SettingsPie extends StatelessWidget {
  const SettingsPie({super.key, required this.fraction});

  /// Null while it is not known yet, which draws the empty face.
  final double? fraction;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size.square(14),
    painter: _PiePainter(
      fraction: (fraction ?? 0).clamp(0.0, 1.0),
      fill: (fraction ?? 0) >= 1
          ? Theme.of(context).colorScheme.error
          : Theme.of(context).colorScheme.primary,
      track: context.palette.textTertiary,
    ),
  );
}

class _PiePainter extends CustomPainter {
  const _PiePainter({
    required this.fraction,
    required this.fill,
    required this.track,
  });

  final double fraction;
  final Color fill;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    canvas.drawCircle(
      center,
      radius - 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = track,
    );
    if (fraction <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius - 3),
      -math.pi / 2,
      2 * math.pi * fraction,
      true,
      Paint()..color = fill,
    );
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.fraction != fraction || old.fill != fill || old.track != track;
}

/// The switch drawn at the end of a toggle row. Not a [Switch]: the whole row
/// is the control, and this only shows which way it is set.
class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({super.key, required this.value, this.enabled = true});

  final bool value;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final pointer = AppPlatform.hasPointer;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: AnimatedContainer(
        key: const ValueKey('compact-switch-indicator'),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        width: pointer ? 34 : 44,
        height: pointer ? 20 : 25,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value
              ? scheme.primary
              : pointer
              ? palette.switchTrackOff
              : palette.controlBackground,
          borderRadius: BorderRadius.circular(AppRadii.pill),
          border: pointer
              ? null
              : Border.all(
                  color: value ? Colors.transparent : palette.controlBorder,
                  width: AppHairline.of(context),
                ),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: value
                  ? (pointer ? palette.switchThumb : scheme.onPrimary)
                  : palette.textTertiary,
              shape: BoxShape.circle,
              boxShadow: pointer && value
                  ? [
                      BoxShadow(
                        color: palette.shadowAt(0x40),
                        offset: const Offset(0, 1),
                        blurRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: SizedBox.square(dimension: pointer ? 16 : 21),
          ),
        ),
      ),
    );
  }
}
