import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../keycap.dart';

/// A block that Text ▾ turns the selection's line into.
class SelectionBlock {
  const SelectionBlock({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.trigger,
    this.requiresMarkdown = false,
  });

  final String label;
  final KapyIconData icon;

  /// What typed at the start of a line does the same, such as "#".
  final String? trigger;
  final bool requiresMarkdown;
  final VoidCallback onSelected;
}

/// One of the bubble's formatting buttons.
class SelectionAction {
  const SelectionAction({
    required this.name,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.shortcut,
  });

  /// Names its key, as in selection-bold.
  final String name;
  final String label;
  final KapyIconData icon;
  final bool active;
  final String? shortcut;
  final VoidCallback onPressed;
}

/// The formatting bubble over a selection where there is a pointer: Text ▾,
/// then bold, italic, strikethrough, inline code and link, which becomes a
/// field for the address.
///
/// It sits in the root overlay rather than in the field's own context menu,
/// so the address field can take the keyboard while the selection waits in
/// the note. The editor says where the selection is and what it holds, and
/// takes it away again when the selection goes.
class SelectionBubbleController extends ChangeNotifier {
  OverlayEntry? _entry;
  Rect _above = Rect.zero;
  Rect _below = Rect.zero;
  Rect _within = Rect.largest;
  String _block = 'Text';
  List<SelectionBlock> _blocks = const [];
  List<SelectionAction> _actions = const [];
  bool _markdownEnabled = false;
  ValueChanged<String>? _onLink;
  VoidCallback? _onLinkClosed;
  bool _blocksOpen = false;
  bool _editingLink = false;
  final _link = TextEditingController();
  late final _linkFocus = FocusNode(
    debugLabel: 'Link address',
    onKeyEvent: (node, event) {
      if (event is! KeyDownEvent ||
          event.logicalKey != LogicalKeyboardKey.escape) {
        return KeyEventResult.ignored;
      }
      closeLink();
      return KeyEventResult.handled;
    },
  );

  bool get isVisible => _entry != null;
  bool get blocksOpen => _blocksOpen;

  /// Whether the address field holds the keyboard, which the note gave up.
  bool get editingLink => _editingLink;

  /// Shows the bubble, or brings the one showing up to date. [above] is the
  /// selection's first line and [below] its last, in global coordinates.
  void show(
    BuildContext context, {
    required Rect above,
    required Rect below,
    required Rect within,
    required String block,
    required List<SelectionBlock> blocks,
    required List<SelectionAction> actions,
    required bool markdownEnabled,
    required ValueChanged<String> onLink,
    required VoidCallback onLinkClosed,
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _above = above;
    _below = below;
    _within = within;
    _block = block;
    _blocks = blocks;
    _actions = actions;
    _markdownEnabled = markdownEnabled;
    _onLink = onLink;
    _onLinkClosed = onLinkClosed;
    if (_entry == null) {
      _entry = OverlayEntry(
        builder: (context) => _SelectionBubbleOverlay(controller: this),
      );
      overlay.insert(_entry!);
    }
    notifyListeners();
  }

  void hide() {
    _entry?.remove();
    _entry = null;
    _blocksOpen = false;
    _editingLink = false;
    _link.clear();
  }

  void toggleBlocks() {
    _blocksOpen = !_blocksOpen;
    notifyListeners();
  }

  /// Turns the buttons into the address field.
  void editLink() {
    if (!isVisible) return;
    _blocksOpen = false;
    _editingLink = true;
    _link.clear();
    notifyListeners();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_editingLink) _linkFocus.requestFocus();
    });
  }

  /// Back from the address field to the buttons, and the keyboard back to
  /// the note.
  void closeLink() {
    if (!_editingLink) return;
    _editingLink = false;
    _link.clear();
    notifyListeners();
    _onLinkClosed?.call();
  }

  void _submitLink() {
    final address = _link.text.trim();
    if (address.isEmpty) return;
    final onLink = _onLink;
    hide();
    onLink?.call(address);
  }

  void _choose(SelectionBlock block) {
    _blocksOpen = false;
    notifyListeners();
    block.onSelected();
  }

  /// Esc closes Text ▾ first, then the bubble, and leaves the selection.
  bool handleKeyEvent(KeyEvent event) {
    if (!isVisible ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    if (_blocksOpen) {
      toggleBlocks();
    } else {
      hide();
    }
    return true;
  }

  @override
  void dispose() {
    hide();
    _link.dispose();
    _linkFocus.dispose();
    super.dispose();
  }
}

class _SelectionBubbleOverlay extends StatelessWidget {
  const _SelectionBubbleOverlay({required this.controller});

  final SelectionBubbleController controller;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => CustomMultiChildLayout(
      delegate: _BubbleLayout(
        above: controller._above,
        below: controller._below,
        within: controller._within,
        safeArea: MediaQuery.paddingOf(context),
      ),
      children: [
        // Part of the note's field for taps, as the platform's own toolbar
        // is: a click on the bubble is not a click outside the note, which
        // would take its focus, and the bubble with it, before the click
        // lands.
        LayoutId(
          id: _BubbleLayout.bubble,
          child: TextFieldTapRegion(
            child: ExcludeFocus(
              excluding: !controller.editingLink,
              child: _Bubble(controller: controller),
            ),
          ),
        ),
        if (controller.blocksOpen)
          LayoutId(
            id: _BubbleLayout.menu,
            child: TextFieldTapRegion(
              child: ExcludeFocus(child: _BlockMenu(controller: controller)),
            ),
          ),
      ],
    ),
  );
}

/// Over the selection's first line, or under its last near the top edge,
/// across no further than the note's own pane; Text ▾ opens upward when there is room, so the selection stays in view,
/// and otherwise toward the side with more, kept on screen.
class _BubbleLayout extends MultiChildLayoutDelegate {
  _BubbleLayout({
    required this.above,
    required this.below,
    required this.within,
    required this.safeArea,
  });

  final Rect above;
  final Rect below;
  final Rect within;
  final EdgeInsets safeArea;

  static const bubble = 'bubble';
  static const menu = 'menu';
  static const double _margin = 8;
  static const double _gap = 8;
  static const double _menuGap = 6;

  @override
  void performLayout(Size size) {
    final loose = BoxConstraints.loose(
      Size(
        math.max(0, size.width - _margin * 2),
        math.max(0, size.height - _margin * 2),
      ),
    );
    final top = safeArea.top + _margin;
    final bottom = size.height - safeArea.bottom - _margin;
    final left = math.max(0.0, within.left) + _margin;
    final right = math.min(size.width, within.right) - _margin;
    double across(double width) =>
        _clamp(above.center.dx - width / 2, left, right - width);

    final bubbleSize = layoutChild(bubble, loose);
    final fitsAbove = above.top - _gap - bubbleSize.height >= top;
    final y = fitsAbove
        ? above.top - _gap - bubbleSize.height
        : _clamp(below.bottom + _gap, top, bottom - bubbleSize.height);
    final x = across(bubbleSize.width);
    positionChild(bubble, Offset(x, y));

    if (!hasChild(menu)) return;
    final menuSize = layoutChild(menu, loose);
    final roomAbove = y - _menuGap - top;
    final roomBelow = bottom - (y + bubbleSize.height + _menuGap);
    final upward =
        fitsAbove && (menuSize.height <= roomAbove || roomAbove > roomBelow);
    positionChild(
      menu,
      Offset(
        _clamp(x, left, right - menuSize.width),
        _clamp(
          upward
              ? y - _menuGap - menuSize.height
              : y + bubbleSize.height + _menuGap,
          top,
          bottom - menuSize.height,
        ),
      ),
    );
  }

  static double _clamp(double value, double low, double high) =>
      high <= low ? low : math.min(math.max(value, low), high);

  @override
  bool shouldRelayout(_BubbleLayout oldDelegate) =>
      oldDelegate.above != above ||
      oldDelegate.below != below ||
      oldDelegate.within != within ||
      oldDelegate.safeArea != safeArea;
}

BoxDecoration _surface(CalcPalette palette, double radius) => BoxDecoration(
  color: palette.controlBackground,
  borderRadius: BorderRadius.circular(radius),
  border: Border.all(color: palette.separator),
  boxShadow: const [
    BoxShadow(
      color: Color(0x80000000),
      offset: Offset(0, 12),
      blurRadius: 28,
      spreadRadius: -14,
    ),
  ],
);

class _Bubble extends StatelessWidget {
  const _Bubble({required this.controller});

  final SelectionBubbleController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      key: const ValueKey('selection-bubble'),
      height: 40,
      padding: const EdgeInsets.all(5),
      decoration: _surface(palette, 11),
      child: controller.editingLink
          ? _LinkField(controller: controller)
          : Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 2,
              children: [
                _BlockButton(controller: controller),
                Container(
                  width: 1,
                  height: 18,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  color: palette.separator,
                ),
                for (final action in controller._actions)
                  _BubbleIconButton(
                    key: ValueKey('selection-${action.name}'),
                    icon: action.icon,
                    label: action.label,
                    shortcut: action.shortcut,
                    active: action.active,
                    onPressed: action.onPressed,
                  ),
              ],
            ),
    );
  }
}

/// "Text ▾": the block the selection is in, and the way to another.
class _BlockButton extends StatelessWidget {
  const _BlockButton({required this.controller});

  final SelectionBubbleController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final open = controller.blocksOpen;
    return Semantics(
      button: true,
      expanded: open,
      label: 'Turn into',
      value: controller._block,
      excludeSemantics: true,
      onTap: controller.toggleBlocks,
      child: Material(
        color: open ? palette.selectedBackground : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          key: const ValueKey('selection-block'),
          borderRadius: BorderRadius.circular(7),
          hoverColor: palette.hover,
          onTap: controller.toggleBlocks,
          child: Container(
            height: 30,
            padding: const EdgeInsets.only(left: 10, right: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 5,
              children: [
                Text(
                  controller._block,
                  style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: AppTypeScale.small,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                KapyIcon(
                  KapyIcons.chevronDownRounded,
                  size: 14,
                  color: palette.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BubbleIconButton extends StatelessWidget {
  const _BubbleIconButton({
    super.key,
    required this.icon,
    required this.label,
    required this.shortcut,
    required this.active,
    required this.onPressed,
  });

  final KapyIconData icon;
  final String label;
  final String? shortcut;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final shortcut = this.shortcut;
    return Semantics(
      button: true,
      toggled: active,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Tooltip(
        message: shortcut == null ? label : '$label  $shortcut',
        child: Material(
          color: active ? palette.selectedBackground : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          child: InkWell(
            borderRadius: BorderRadius.circular(7),
            hoverColor: palette.hover,
            onTap: onPressed,
            child: SizedBox.square(
              dimension: 30,
              child: Center(
                child: KapyIcon(
                  icon,
                  size: 16,
                  color: active ? palette.textPrimary : palette.textSecondary,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The bubble as an address field: ↵ links, esc goes back.
class _LinkField extends StatelessWidget {
  const _LinkField({required this.controller});

  final SelectionBubbleController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = TextStyle(
      color: palette.textPrimary,
      fontSize: AppTypeScale.small,
      fontWeight: FontWeight.w500,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        SizedBox(
          width: 28,
          height: 30,
          child: Center(
            child: KapyIcon(
              KapyIcons.linkRounded,
              size: 16,
              color: palette.textSecondary,
            ),
          ),
        ),
        Container(
          width: 230,
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: palette.surfaceBackground,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: palette.controlBorder),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: TextField(
              key: const ValueKey('selection-link-field'),
              controller: controller._link,
              focusNode: controller._linkFocus,
              style: style,
              cursorHeight: 16,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                hintText: 'Paste or type a link',
                hintStyle: style.copyWith(color: palette.textTertiary),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.zero,
              ),
              onSubmitted: (_) => controller._submitLink(),
            ),
          ),
        ),
        Semantics(
          button: true,
          label: 'Link',
          excludeSemantics: true,
          onTap: controller._submitLink,
          child: Material(
            color: palette.tonalBackground,
            borderRadius: BorderRadius.circular(7),
            child: InkWell(
              key: const ValueKey('selection-link-apply'),
              borderRadius: BorderRadius.circular(7),
              onTap: controller._submitLink,
              child: Container(
                height: 30,
                padding: const EdgeInsets.only(left: 10, right: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 6,
                  children: [
                    Text(
                      'Link',
                      style: TextStyle(
                        color: palette.tonalForeground,
                        fontSize: AppTypeScale.caption,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Keycap('↵'),
                  ],
                ),
              ),
            ),
          ),
        ),
        _BubbleIconButton(
          key: const ValueKey('selection-link-cancel'),
          icon: KapyIcons.closeRounded,
          label: 'Back to formatting',
          shortcut: 'esc',
          active: false,
          onPressed: controller.closeLink,
        ),
      ],
    );
  }
}

/// Text ▾ open: what the line can become, each with what typed at the start
/// of a line does the same.
class _BlockMenu extends StatelessWidget {
  const _BlockMenu({required this.controller});

  final SelectionBubbleController controller;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final quiet = TextStyle(
      color: palette.textTertiary,
      fontSize: AppTypeScale.caption,
      fontWeight: FontWeight.w500,
    );
    return Material(
      type: MaterialType.transparency,
      child: Container(
        key: const ValueKey('selection-block-menu'),
        width: 236,
        padding: const EdgeInsets.all(6),
        decoration: _surface(palette, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 10, 8, 5),
              child: Semantics(
                header: true,
                label: 'Turn into',
                excludeSemantics: true,
                child: Text(
                  'TURN INTO',
                  style: TextStyle(
                    color: palette.textTertiary,
                    fontSize: AppTypeScale.badge,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.44,
                  ),
                ),
              ),
            ),
            for (final block in controller._blocks)
              Builder(
                builder: (context) {
                  final current = block.label == controller._block;
                  final asks =
                      block.requiresMarkdown && !controller._markdownEnabled;
                  final trigger = block.trigger;
                  return Semantics(
                    button: true,
                    selected: current,
                    label: block.label,
                    hint: asks ? 'Requires Markdown' : null,
                    excludeSemantics: true,
                    onTap: () => controller._choose(block),
                    child: Material(
                      color: current
                          ? palette.selectedBackground
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        key: ValueKey('selection-block-${block.label}'),
                        borderRadius: BorderRadius.circular(8),
                        hoverColor: palette.hover,
                        onTap: () => controller._choose(block),
                        child: Container(
                          height: 32,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Row(
                            spacing: 10,
                            children: [
                              KapyIcon(
                                block.icon,
                                size: 16,
                                color: current
                                    ? palette.textPrimary
                                    : palette.textSecondary,
                              ),
                              Expanded(
                                child: Text(
                                  block.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: palette.textPrimary,
                                    fontSize: AppTypeScale.body,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                              if (asks)
                                Text('Markdown', style: quiet)
                              else if (trigger != null)
                                Keycap(trigger),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
