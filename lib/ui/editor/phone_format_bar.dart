import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../core/toast.dart';
import '../kapy_ai/kapy_ai_parts.dart';

/// One button on the [PhoneFormatBar].
///
/// A null [onPressed] dims the button, which still takes the tap and does
/// nothing: a thumb that lands on it must not fall through to the note.
class FormatBarAction {
  const FormatBarAction({
    required this.key,
    required this.label,
    this.icon,
    this.glyph,
    required this.onPressed,
    this.active = false,
  }) : assert((icon == null) != (glyph == null));

  final String key;
  final String label;
  final KapyIconData? icon;

  /// A character drawn in place of an icon: the "/" that Commands is known by.
  final String? glyph;
  final VoidCallback? onPressed;

  /// The caret or selection is already in what this button makes.
  final bool active;
}

/// The row above a phone's software keyboard while a note is being written:
/// one tap per markdown action, scrolling sideways, with the key that puts
/// the keyboard away fixed on the right.
///
/// Its buttons are plain gesture targets, so a tap never takes focus from the
/// note or ends its selection, and the bar is a [TapRegion] of [tapGroup] so
/// the note's own tap-outside handling treats it as part of the note.
class PhoneFormatBar extends StatefulWidget {
  const PhoneFormatBar({
    super.key,
    required this.actions,
    required this.tapGroup,
    required this.onDismissKeyboard,
  });

  final List<FormatBarAction> actions;
  final Object tapGroup;
  final VoidCallback onDismissKeyboard;

  static const double height = 44;
  static const double _target = 44;
  static const double _tile = 38;

  @override
  State<PhoneFormatBar> createState() => _PhoneFormatBarState();
}

class _PhoneFormatBarState extends State<PhoneFormatBar> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Brings a button that has just lit up into view: Code, inside a code
  /// block, is past the end of a row that opens at Attach.
  @override
  void didUpdateWidget(PhoneFormatBar old) {
    super.didUpdateWidget(old);
    final before = {
      for (final action in old.actions)
        if (action.active) action.key,
    };
    final index = widget.actions.indexWhere(
      (action) => action.active && !before.contains(action.key),
    );
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final position = _scroll.position;
      final left = index * PhoneFormatBar._target;
      final right = left + PhoneFormatBar._target;
      if (left < position.pixels) {
        _scroll.jumpTo(left);
      } else if (right > position.pixels + position.viewportDimension) {
        _scroll.jumpTo(right - position.viewportDimension);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    // Notices keep above it, at the same width, rather than cover it.
    return ToastClearance(
      child: TapRegion(
        groupId: widget.tapGroup,
        child: Container(
          key: const ValueKey('phone-format-bar'),
          height: PhoneFormatBar.height + bottomInset,
          padding: EdgeInsets.only(bottom: bottomInset),
          decoration: BoxDecoration(
            color: palette.kapyMenu,
            border: Border(top: BorderSide(color: palette.separator)),
          ),
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  key: const ValueKey('phone-format-scroll'),
                  controller: _scroll,
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: Row(
                    children: [
                      for (final action in widget.actions)
                        _BarButton(key: ValueKey(action.key), action: action),
                    ],
                  ),
                ),
              ),
              Container(width: 1, height: 22, color: palette.separator),
              _BarButton(
                key: const ValueKey('dismiss-keyboard'),
                width: 48,
                action: FormatBarAction(
                  key: 'dismiss-keyboard',
                  label: 'Hide keyboard',
                  icon: KapyIcons.keyboardOutlined,
                  onPressed: widget.onDismissKeyboard,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({super.key, required this.action, this.width = 44});

  final FormatBarAction action;
  final double width;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final foreground = action.active
        ? palette.tonalForeground
        : palette.textSecondary;
    final color = action.onPressed == null
        ? foreground.withValues(alpha: 0.32)
        : foreground;
    return Semantics(
      button: true,
      selected: action.active,
      enabled: action.onPressed != null,
      label: action.label,
      excludeSemantics: true,
      onTap: action.onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: action.onPressed ?? () {},
        child: SizedBox(
          width: width,
          height: PhoneFormatBar._target,
          child: Center(
            child: Container(
              width: PhoneFormatBar._tile,
              height: PhoneFormatBar._tile,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: action.active
                    ? palette.tonalBackground
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              child: action.icon == null
                  ? Text(
                      action.glyph!,
                      style: TextStyle(
                        color: color,
                        fontSize: 21,
                        fontWeight: AppWeight.font(AppWeight.regular),
                        fontVariations: AppWeight.wght(AppWeight.regular),
                        height: 1,
                      ),
                    )
                  : KapyIcon(action.icon!, size: 21, color: color),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the attach button adds to the note.
enum FormatBarAttachment { camera, photos, voice, file }

/// The small sheet the attach button opens, one row for each thing a note
/// can take that is not text. Voice note is left out where [voice] is false,
/// as Commands leaves it out.
Future<FormatBarAttachment?> chooseAttachment(
  BuildContext context, {
  required bool voice,
}) => showModalBottomSheet<FormatBarAttachment>(
  context: context,
  showDragHandle: true,
  builder: (context) => SafeArea(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (choice, label, icon) in const [
          (FormatBarAttachment.camera, 'Camera', KapyIcons.cameraOutlined),
          (
            FormatBarAttachment.photos,
            'Photos',
            KapyIcons.photoLibraryOutlined,
          ),
          (FormatBarAttachment.voice, 'Voice note', KapyIcons.micRounded),
          (FormatBarAttachment.file, 'File', KapyIcons.attachFileRounded),
        ])
          if (voice || choice != FormatBarAttachment.voice)
            ListTile(
              key: ValueKey('attach-${choice.name}'),
              leading: KapyIcon(icon),
              title: Text(label),
              onTap: () => Navigator.pop(context, choice),
            ),
        const SizedBox(height: 8),
      ],
    ),
  ),
);

/// Asks for the address a link goes to; null when it is cancelled or empty.
Future<String?> askLinkAddress(BuildContext context) => showDialog<String>(
  context: context,
  builder: (context) => const _LinkAddressDialog(),
);

class _LinkAddressDialog extends StatefulWidget {
  const _LinkAddressDialog();

  @override
  State<_LinkAddressDialog> createState() => _LinkAddressDialogState();
}

class _LinkAddressDialogState extends State<_LinkAddressDialog> {
  final _address = TextEditingController();

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  void _submit() {
    final address = _address.text.trim();
    Navigator.pop(context, address.isEmpty ? null : address);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add a link'),
    content: TextField(
      key: const ValueKey('link-address'),
      controller: _address,
      autofocus: true,
      keyboardType: TextInputType.url,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(hintText: 'https://'),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        key: const ValueKey('link-add'),
        onPressed: _submit,
        child: const Text('Add'),
      ),
    ],
  );
}
