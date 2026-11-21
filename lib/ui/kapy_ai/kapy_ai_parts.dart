import 'package:material_ui/material_ui.dart';

import '../../ai/kapy_ai.dart';
import '../../core/platform.dart';
import '../../core/theme.dart';
import '../compact_icon_button.dart';

/// The pieces every part of Kapy AI is drawn with: the few colours the
/// palette does not already name in both themes, its type, its buttons and
/// its words for this device.

/// The Kapy AI tokens that are not a single palette colour in both themes.
extension KapyAiColors on CalcPalette {
  bool get _dark => brightness == Brightness.dark;

  /// The picker and a chat under the pointer: #2A2722 dark, #FCFAF4 light.
  Color get kapyMenu => _dark ? controlBackground : editorBackground;

  /// The question bubble, the chip, a pressed button and the open chat:
  /// #35312B dark, #EFEADD light.
  Color get kapyHighlight => _dark ? separator : controlBackground;

  /// Errors and Delete: #D98A7A dark, #B4533F light. The theme's error red is
  /// the alarm of a failed save; this is the quieter red of the design.
  Color get kapyRed =>
      _dark ? const Color(0xFFD98A7A) : const Color(0xFFB4533F);
}

/// Figtree at [size] on a [line] px line.
TextStyle kapyText(
  double size,
  double line,
  Color color, {
  FontWeight weight = FontWeight.w400,
}) => TextStyle(
  fontFamily: AppFonts.ui,
  fontFamilyFallback: AppFonts.uiFallback,
  fontSize: size,
  height: line / size,
  fontWeight: weight,
  color: color,
);

/// What this device is called in a sentence: "Answers stay on this Mac".
String get kapyDeviceWord => AppPlatform.isMacOS
    ? 'Mac'
    : AppPlatform.isIOS
    ? 'iPhone'
    : AppPlatform.isAndroid
    ? 'phone'
    : 'computer';

/// Gigabytes to one decimal, the way the download is spoken of: "2.6".
String kapyGigabytes(int bytes) => (bytes / 1000000000).toStringAsFixed(1);

const kapyMonths = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// [chats] whose title holds [query], newest first, under Today, Yesterday,
/// Previous 7 days and then each month, with its year when it is not this
/// one. The panel's chats and the phone's page group them the same way.
Map<String, List<KapyChat>> kapyChatGroups(
  List<KapyChat> chats, {
  required String query,
  required DateTime now,
}) {
  final words = query.trim().toLowerCase();
  final today = DateTime(now.year, now.month, now.day);
  String groupOf(DateTime when) {
    final days = today
        .difference(DateTime(when.year, when.month, when.day))
        .inDays;
    if (days <= 0) return 'Today';
    if (days == 1) return 'Yesterday';
    if (days <= 7) return 'Previous 7 days';
    final month = kapyMonths[when.month - 1];
    return when.year == now.year ? month : '$month ${when.year}';
  }

  final groups = <String, List<KapyChat>>{};
  for (final chat
      in chats
          .where((chat) => chat.title.toLowerCase().contains(words))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt))) {
    (groups[groupOf(chat.updatedAt)] ??= []).add(chat);
  }
  return groups;
}

/// "9 Oct", with the year only when it is not this one.
String kapyDay(DateTime day, DateTime now) => [
  '${day.day} ${kapyMonths[day.month - 1].substring(0, 3)}',
  if (day.year != now.year) '${day.year}',
].join(' ');

KapyIconData kapyModelIcon(KapyModelKind kind) => switch (kind) {
  KapyModelKind.device => KapyIcons.computerOutlined,
  KapyModelKind.cloud => KapyIcons.cloudRounded,
  KapyModelKind.codex ||
  KapyModelKind.claudeCode => KapyIcons.commandLineOutlined,
  KapyModelKind.openRouter => KapyIcons.keyOutlined,
};

KapyIconData kapyAccountIcon(KapyAccountKind kind) => switch (kind) {
  KapyAccountKind.codex ||
  KapyAccountKind.claudeCode => KapyIcons.commandLineOutlined,
  KapyAccountKind.openRouter => KapyIcons.keyOutlined,
};

/// The account's own name, as its rows and notices say it.
String kapyAccountName(KapyAccountKind kind) => switch (kind) {
  KapyAccountKind.codex => 'Codex',
  KapyAccountKind.claudeCode => 'Claude Code',
  KapyAccountKind.openRouter => 'Your key',
};

/// The 28 px button of a notice, a confirmation and the key field: sage when
/// it is the one thing to do, a red tint for Delete, an outline otherwise.
class KapyAiButton extends StatelessWidget {
  const KapyAiButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.filled = false,
    this.destructive = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool filled;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final (background, foreground) = filled
        ? (palette.totalPillBackground, palette.totalPillText)
        : destructive
        ? (palette.kapyRed.withValues(alpha: 0.16), palette.kapyRed)
        : (Colors.transparent, palette.textSubheading);
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 28),
        fixedSize: const Size.fromHeight(28),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: background,
        foregroundColor: foreground,
        disabledForegroundColor: palette.textTertiary,
        side: filled || destructive
            ? null
            : BorderSide(color: palette.separator),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: kapyText(13, 16, foreground, weight: FontWeight.w500),
      ),
    );
  }
}

/// A 32 px icon action of the panel's header, and the toolbar's.
class KapyAiIconButton extends StatelessWidget {
  const KapyAiIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected = false,
    this.extent = 32,
    this.iconSize = 17,
    this.radius = 10,
    this.color,
    this.selectedBackground,
  });

  final KapyIconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final double extent;
  final double iconSize;
  final double radius;
  final Color? color;

  /// The surface while [selected]; the panel's highlight unless given.
  final Color? selectedBackground;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return CompactIconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      selected: selected,
      extent: extent,
      radius: radius,
      selectedBackground: selectedBackground ?? palette.kapyHighlight,
      foregroundColor: color ?? palette.textSecondary,
      icon: KapyIcon(icon, size: iconSize, strokeWidth: 1.8),
    );
  }
}
