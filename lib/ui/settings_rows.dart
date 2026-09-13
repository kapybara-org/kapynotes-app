import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';

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
      : const EdgeInsets.fromLTRB(11, 8, 10, 8);

  /// A radio sits closer to its own edge than a switch does.
  static EdgeInsets get choicePadding => _touch
      ? const EdgeInsets.fromLTRB(14, 12, 14, 12)
      : const EdgeInsets.fromLTRB(11, 8, 11, 8);
  static double get iconSize => _touch ? 19 : 16;
  static double get iconSlot => _touch ? 30 : 25;
  static double get gap => _touch ? 11 : 9;
  static double get titleSize => _touch ? 14.5 : 12.5;
  static double get subtitleSize => _touch ? 12.25 : 10.75;
  static double get chevronSize => _touch ? 21 : 18;

  /// Lines the dividers up under the copy rather than under the icons.
  static double get dividerIndent => _touch ? 58 : 48;
}

/// The small capitals over a group, naming what the rows in it are about.
class SettingsLabel extends StatelessWidget {
  const SettingsLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 3, bottom: 7),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 10.5,
        fontWeight: _mediumWeight,
        letterSpacing: 0.65,
        color: context.palette.textTertiary,
      ),
    ),
  );
}

/// A card of rows with hairlines between them.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.controlBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.controlBorder, width: 0.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Column(
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0)
                Divider(
                  height: 0.5,
                  thickness: 0.5,
                  indent: SettingsMetrics.dividerIndent,
                  color: palette.separator,
                ),
              children[index],
            ],
          ],
        ),
      ),
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
      fontSize: 11,
      height: 1.4,
      color: palette.textTertiary,
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
    final subtitle = this.subtitle;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: SettingsMetrics.titleSize,
            fontWeight: _mediumWeight,
            color: titleColor ?? palette.textPrimary,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: SettingsMetrics.subtitleSize,
              color: palette.textSecondary,
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
    final row = Padding(
      padding: SettingsMetrics.padding,
      child: Row(
        children: [
          if (icon != null) ...[
            SizedBox(
              width: SettingsMetrics.iconSlot,
              child: KapyIcon(
                icon,
                size: SettingsMetrics.iconSize,
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
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: prominent ? scheme.primary : palette.controlBackground,
        foregroundColor: prominent ? scheme.onPrimary : palette.textSecondary,
        disabledForegroundColor: palette.textTertiary,
        side: prominent
            ? null
            : BorderSide(color: palette.controlBorder, width: 0.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, fontWeight: _mediumWeight),
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
    return AnimatedContainer(
      key: const ValueKey('compact-switch-indicator'),
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOutCubic,
      width: AppPlatform.hasPointer ? 34 : 44,
      height: AppPlatform.hasPointer ? 18 : 25,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: value ? scheme.primary : palette.controlBackground,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
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
            color: value ? scheme.onPrimary : palette.textTertiary,
            shape: BoxShape.circle,
          ),
          child: SizedBox.square(dimension: AppPlatform.hasPointer ? 14 : 21),
        ),
      ),
    );
  }
}
