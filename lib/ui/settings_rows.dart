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
const _mediumWeight = FontWeight.w400;

/// How big a settings row is allowed to be.
///
/// A pointer can hit an eight-pixel gap and read eleven-point type; a thumb
/// can do neither. This is the same split [AppControlMetrics] already makes
/// for icon buttons, applied to the rows those buttons sit beside.
class SettingsMetrics {
  const SettingsMetrics._();

  static bool get _touch => !AppPlatform.hasPointer;

  static EdgeInsets get padding => _touch
      ? const EdgeInsets.fromLTRB(14, 12, 13, 12)
      : const EdgeInsets.symmetric(horizontal: 14, vertical: 10);

  /// A radio sits closer to its own edge than a switch does.
  static EdgeInsets get choicePadding => _touch
      ? const EdgeInsets.fromLTRB(14, 12, 14, 12)
      : const EdgeInsets.symmetric(horizontal: 14, vertical: 10);

  /// The least a row is tall with a pointer: a title and its line of
  /// description, with room around them, so a pane of rows reads as a list
  /// of settings rather than a form.
  static double get minRowHeight => _touch ? 0 : 54;
  static double get iconSize => _touch ? 19 : 17;
  static double get iconSlot => _touch ? 30 : 17;
  static double get iconStroke => _touch ? 1.5 : 1.7;
  static double get gap => _touch ? 11 : 12;
  static double get titleSize => _touch
      ? 14.5
      : AppPlatform.isWindows
      ? AppTypeScale.control
      : 13.5;
  static double get subtitleSize => _touch
      ? 12.25
      : AppPlatform.isWindows
      ? 12.5
      : 12;
  static double get sectionLabelSize => _touch ? 10.5 : 14;
  static double get noteSize =>
      AppPlatform.isWindows ? AppTypeScale.caption : 11;
  static double get buttonLabelSize => _touch ? 12 : 12.5;
  static FontWeight get titleWeight => _touch ? _mediumWeight : FontWeight.w600;
  static double get chevronSize => _touch ? 21 : 15;

  /// Between one group and the heading of the next.
  static double get groupGap => _touch ? 18 : 20;

  /// Lines the dividers up under the copy rather than under the icons.
  static double get dividerIndent => _touch ? 58 : 43;
}

/// The heading over a group, naming what the rows in it are about: a small
/// handwritten heading with a pointer, small capitals on a phone.
class SettingsLabel extends StatelessWidget {
  const SettingsLabel(this.text, {super.key});

  /// In sentence case. The phone sets it in capitals.
  final String text;

  @override
  Widget build(BuildContext context) {
    if (AppPlatform.hasPointer) {
      return Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Text(
          text,
          style: TextStyle(
            fontFamily: 'Shantell Sans',
            fontSize: SettingsMetrics.sectionLabelSize,
            fontWeight: FontWeight.w600,
            height: 18 / 14,
            color: context.palette.textSubheading,
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 3, bottom: 7),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: SettingsMetrics.sectionLabelSize,
          fontWeight: _mediumWeight,
          letterSpacing: 0.65,
          color: context.palette.textTertiary,
        ),
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
              indent: SettingsMetrics.dividerIndent,
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

/// A row's words: what it is, and — optionally — a line saying more.
class SettingsRowCopy extends StatelessWidget {
  const SettingsRowCopy({
    super.key,
    required this.title,
    this.subtitle,
    this.titleColor,
  });

  final String title;
  final String? subtitle;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final pointer = AppPlatform.hasPointer;
    final subtitle = this.subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: SettingsMetrics.titleSize,
            fontWeight: SettingsMetrics.titleWeight,
            height: pointer ? 18 / SettingsMetrics.titleSize : null,
            color: titleColor ?? palette.textPrimary,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 1,
            softWrap: false,
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

/// The one row every other row is a kind of: an icon, its words, and
/// whatever sits at the end.
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  final KapyIconData? icon;
  final String title;
  final String? subtitle;
  final Widget? trailing;

  /// Null leaves the row as a statement rather than a control.
  final VoidCallback? onTap;

  /// Red, for the one or two rows that cannot be taken back.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final danger = Theme.of(context).colorScheme.error;
    final icon = this.icon;
    final trailing = this.trailing;
    final row = Container(
      constraints: BoxConstraints(minHeight: SettingsMetrics.minRowHeight),
      padding: SettingsMetrics.padding,
      child: Row(
        children: [
          if (icon != null) ...[
            SizedBox(
              width: SettingsMetrics.iconSlot,
              child: KapyIcon(
                icon,
                size: SettingsMetrics.iconSize,
                strokeWidth: SettingsMetrics.iconStroke,
                color: destructive ? danger : palette.textSecondary,
              ),
            ),
            SizedBox(width: SettingsMetrics.gap),
          ],
          Expanded(
            child: SettingsRowCopy(
              title: title,
              subtitle: subtitle,
              titleColor: destructive ? danger : null,
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing],
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

/// A row that opens something: a picker, a dialog, another pane.
class SettingsNavigationRow extends StatelessWidget {
  const SettingsNavigationRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final KapyIconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => SettingsRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    onTap: onTap,
    trailing: KapyIcon(
      KapyIcons.chevronRightRounded,
      size: SettingsMetrics.chevronSize,
      strokeWidth: AppPlatform.hasPointer ? 1.8 : 1.5,
      color: context.palette.textTertiary,
    ),
  );
}

/// A row that is a switch, and flips from anywhere on it.
class SettingsToggleRow extends StatelessWidget {
  const SettingsToggleRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final KapyIconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    toggled: value,
    button: true,
    child: InkWell(
      onTap: () => onChanged(!value),
      child: SettingsRow(
        icon: icon,
        title: title,
        subtitle: subtitle,
        trailing: ExcludeSemantics(child: SettingsSwitch(value: value)),
      ),
    ),
  );
}

/// The small button at the end of a row.
class SettingsRowButton extends StatelessWidget {
  const SettingsRowButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.prominent = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final pointer = AppPlatform.hasPointer;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: Size(0, pointer ? 28 : 30),
        padding: EdgeInsets.symmetric(horizontal: pointer ? 11 : 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: prominent ? scheme.primary : palette.controlBackground,
        foregroundColor: prominent
            ? scheme.onPrimary
            : pointer
            ? palette.textSubheading
            : palette.textSecondary,
        disabledForegroundColor: palette.textTertiary,
        side: prominent
            ? null
            : pointer
            ? BorderSide(color: palette.separator)
            : BorderSide(color: palette.controlBorder, width: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(pointer ? AppRadii.control : 8),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: SettingsMetrics.buttonLabelSize,
          fontWeight: SettingsMetrics.titleWeight,
          height: pointer ? 16 / 12.5 : null,
        ),
      ),
    );
  }
}

/// The switch drawn at the end of a toggle row. Not a [Switch]: the whole row
/// is the control, and this only shows which way it is set.
class SettingsSwitch extends StatelessWidget {
  const SettingsSwitch({super.key, required this.value});

  final bool value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final scheme = Theme.of(context).colorScheme;
    final pointer = AppPlatform.hasPointer;
    return AnimatedContainer(
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
        borderRadius: BorderRadius.circular(999),
        border: pointer
            ? null
            : Border.all(
                color: value ? Colors.transparent : palette.controlBorder,
                width: 0.5,
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
                      offset: Offset(0, 1),
                      blurRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: SizedBox.square(dimension: pointer ? 16 : 21),
        ),
      ),
    );
  }
}
