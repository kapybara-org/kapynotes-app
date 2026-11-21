import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';

/// Opens [build] as a bottom sheet on a phone, and as a centred dialog on a
/// Mac or a PC. Every sharing surface opens through here, so a phone gets one
/// kind of sheet for all of them.
Future<T?> showSharingSheet<T>(
  BuildContext context,
  Widget Function(bool asSheet) build,
) {
  if (!AppPlatform.isMobile) {
    return showDialog<T>(context: context, builder: (context) => build(false));
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
    builder: (context) => build(true),
  );
}

/// A phone sheet's surface: rounded top corners, a hairline along the top,
/// the grabber, and room at the foot for the home indicator. It sizes to
/// [child] and rides up over the keyboard.
class SharingSheetFrame extends StatelessWidget {
  const SharingSheetFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.92),
        decoration: BoxDecoration(
          color: palette.cardBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadii.surface),
          ),
          border: Border(
            top: BorderSide(
              color: palette.textPrimary.withValues(alpha: 0.08),
              width: AppHairline.of(context),
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 3),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.textPrimary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const SizedBox(width: 36, height: 5),
              ),
            ),
            Flexible(child: child),
            SizedBox(
              height: media.viewInsets.bottom > 0
                  ? 8
                  : media.padding.bottom.clamp(8, 34),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks before a sharing change: a sheet on a phone, the centred alert on a
/// Mac or a PC. With [option], a box ticked to start with, whose answer comes
/// back. Null means the person said no; without [option], yes is true.
///
/// [warning] is for the one ask whose action can't be taken back.
Future<bool?> askFirst(
  BuildContext context, {
  required String title,
  required String body,
  required String action,
  String? option,
  bool warning = false,
}) {
  final ask = _AskFirst(
    title: title,
    body: body,
    action: action,
    option: option,
    warning: warning,
  );
  if (!AppPlatform.isMobile) {
    return showDialog<bool>(context: context, builder: (context) => ask);
  }
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Theme.of(context).drawerTheme.scrimColor,
    builder: (context) => SharingSheetFrame(child: ask),
  );
}

class _AskFirst extends StatefulWidget {
  const _AskFirst({
    required this.title,
    required this.body,
    required this.action,
    required this.option,
    required this.warning,
  });

  final String title;
  final String body;
  final String action;
  final String? option;
  final bool warning;

  @override
  State<_AskFirst> createState() => _AskFirstState();
}

class _AskFirstState extends State<_AskFirst> {
  bool _option = true;

  void _answer() => Navigator.of(context).pop(_option);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final error = Theme.of(context).colorScheme.error;
    final option = widget.option;
    if (!AppPlatform.isMobile) {
      final style = TextStyle(
        fontSize: AppTypeScale.control,
        height: 1.4,
        color: palette.textPrimary,
      );
      return AlertDialog(
        key: const ValueKey('sharing-ask'),
        title: Text(widget.title),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.body, style: style),
              if (option != null) ...[
                const SizedBox(height: 10),
                _OptionRow(
                  label: option,
                  value: _option,
                  style: style,
                  onChanged: (value) => setState(() => _option = value),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('sharing-ask-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            key: const ValueKey('sharing-ask-ok'),
            onPressed: _answer,
            style: widget.warning
                ? TextButton.styleFrom(foregroundColor: error)
                : null,
            child: Text(widget.action),
          ),
        ],
      );
    }

    final quiet = palette.textPrimary.withValues(alpha: 0.06);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.control),
    );
    const label = TextStyle(fontSize: 15, height: 20 / 15);
    return SingleChildScrollView(
      key: const ValueKey('sharing-ask'),
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title,
            style: TextStyle(
              fontSize: 17,
              height: 22 / 17,
              fontWeight: FontWeight.w600,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            widget.body,
            style: TextStyle(
              fontSize: 15,
              height: 22 / 15,
              color: palette.textSecondary,
            ),
          ),
          if (option != null) ...[
            const SizedBox(height: 10),
            _OptionRow(
              label: option,
              value: _option,
              style: label.copyWith(color: palette.textPrimary),
              onChanged: (value) => setState(() => _option = value),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextButton(
                  key: const ValueKey('sharing-ask-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    backgroundColor: quiet,
                    foregroundColor: palette.textPrimary,
                    textStyle: label.copyWith(fontWeight: FontWeight.w500),
                    shape: shape,
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton(
                  key: const ValueKey('sharing-ask-ok'),
                  onPressed: _answer,
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    backgroundColor: widget.warning
                        ? quiet
                        : palette.tonalBackground,
                    foregroundColor: widget.warning
                        ? error
                        : palette.tonalForeground,
                    textStyle: label.copyWith(fontWeight: FontWeight.w600),
                    shape: shape,
                  ),
                  child: Text(widget.action),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The ask's one tick box, the whole row a target.
class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.value,
    required this.style,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final TextStyle style;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
    key: const ValueKey('sharing-ask-option'),
    borderRadius: BorderRadius.circular(AppRadii.compact),
    onTap: () => onChanged(!value),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 20,
            child: Checkbox(
              value: value,
              onChanged: (value) => onChanged(value ?? false),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: style)),
        ],
      ),
    ),
  );
}
