import 'dart:async';

import 'package:flutter/gestures.dart' show kMiddleMouseButton;
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import 'context_menu.dart';

/// Whether the click under way asks for a tab behind the one in front:
/// ⌘-click on a Mac and Ctrl-click elsewhere, as a browser opens a link.
bool clickOpensTabBehind() {
  final keyboard = HardwareKeyboard.instance;
  return AppPlatform.isMacOS
      ? keyboard.isMetaPressed
      : keyboard.isControlPressed;
}

/// One open note on the tab row.
@immutable
class NoteTab {
  const NoteTab({
    required this.id,
    required this.title,
    required this.icon,
    this.pinned,
  });

  final String id;
  final String title;

  /// The rail's icon for where the note lives: Notes, Drawings or Shared.
  final KapyIconData icon;

  /// Whether one of a day's tabs is pinned, which puts a pin in its icon's
  /// place. Null for a tab that isn't one of a day's, which has no pin.
  final bool? pinned;
}

/// The page header's second row: the open notes, one tab each.
///
/// A tab is never squeezed. Its title shows in full up to [maxLabelWidth],
/// and a tab that does not fit folds into "N more", the least recently used
/// first and a pinned one of a day's last, so the row never scrolls and never
/// shrinks a tab to nothing. The active tab never folds.
class NoteTabRow extends StatelessWidget {
  const NoteTabRow({
    super.key,
    required this.tabs,
    required this.activeId,
    required this.recentIds,
    required this.onSelect,
    required this.onClose,
    required this.onCloseOthers,
    this.onPin,
    this.closeShortcut,
  });

  static const double height = 36;

  /// The widest a title gets before it is cut short.
  static const double maxLabelWidth = 160;

  static const double _inset = 16;
  static const double _gap = 16;

  final List<NoteTab> tabs;
  final String? activeId;

  /// The ids of [tabs], most recently used first: the order they keep their
  /// place on the row in.
  final List<String> recentIds;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final ValueChanged<String> onCloseOthers;

  /// Pins one of a day's tabs, or with pin false unpins it.
  final void Function(String id, {required bool pin})? onPin;

  /// The keys that close the active tab, as a keycap prints them.
  final String? closeShortcut;

  static TextStyle _labelStyle(Color color, {bool active = false}) =>
      chromeStyle(
        size: 13,
        line: 16,
        weight: active ? AppWeight.button : AppWeight.body,
        color: color,
      );

  static TextStyle _moreStyle(Color color) =>
      chromeStyle(size: 12, line: 16, weight: AppWeight.body, color: color);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final base = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);

    double textWidth(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: base.merge(style)),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    final labelStyle = _labelStyle(palette.textPrimary, active: true);
    final titles = {
      for (final tab in tabs) tab.id: textWidth(tab.title, labelStyle),
    };
    double labelOf(NoteTab tab) =>
        titles[tab.id]!.clamp(0.0, maxLabelWidth).toDouble();

    return LayoutBuilder(
      builder: (context, constraints) {
        final room = constraints.maxWidth - 2 * _inset;
        double used(List<NoteTab> shown) =>
            shown.fold(
              0.0,
              (sum, tab) => sum + _TabChip.widthFor(labelOf(tab)),
            ) +
            _gap * (shown.length - 1);

        final shown = [...tabs];
        if (used(shown) > room) {
          final more =
              _gap +
              _MoreButton.widthFor(
                textWidth(
                  '${tabs.length} more',
                  _moreStyle(palette.textSecondary),
                ),
              );
          final pinned = {
            for (final tab in tabs)
              if (tab.pinned == true) tab.id,
          };
          for (final id in [
            ...recentIds.reversed.where((id) => !pinned.contains(id)),
            ...recentIds.reversed.where(pinned.contains),
          ]) {
            if (shown.length == 1 || used(shown) + more <= room) break;
            if (id != activeId) shown.removeWhere((tab) => tab.id == id);
          }
        }
        final folded = [
          for (final tab in tabs)
            if (!shown.contains(tab)) tab,
        ];

        return Semantics(
          container: true,
          explicitChildNodes: true,
          label: 'Open notes',
          child: Container(
            height: AppControlMetrics.scaleBar(context, height),
            padding: const EdgeInsets.symmetric(horizontal: _inset),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: palette.pageBorder,
                  width: AppHairline.of(context),
                ),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, tab) in shown.indexed) ...[
                  if (index > 0) const SizedBox(width: _gap),
                  _TabChip(
                    key: ValueKey('note-tab-${tab.id}'),
                    tab: tab,
                    labelWidth: labelOf(tab),
                    cut: titles[tab.id]! > maxLabelWidth,
                    active: tab.id == activeId,
                    onSelect: () => onSelect(tab.id),
                    onClose: () => onClose(tab.id),
                    onCloseOthers: () => onCloseOthers(tab.id),
                    closeShortcut: tab.id == activeId ? closeShortcut : null,
                    onPin: switch ((tab.pinned, onPin)) {
                      (final pinned?, final onPin?) => () => onPin(
                        tab.id,
                        pin: !pinned,
                      ),
                      _ => null,
                    },
                  ),
                ],
                if (folded.isNotEmpty) ...[
                  const SizedBox(width: _gap),
                  Center(
                    child: _MoreButton(
                      folded: folded,
                      onSelect: onSelect,
                      onClose: onClose,
                      onCloseOthers: switch (activeId) {
                        final id? => () => onCloseOthers(id),
                        null => null,
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Brings the tab row in under the toolbar while [shown], and takes it away
/// again. It grows out from under the toolbar over 160 ms with an ease-out as
/// the tabs fade in, and leaves the same way over 120 ms. The page below moves
/// with it, so the text never jumps. Where the system asks for less motion,
/// it comes and goes at once.
class TabRowReveal extends StatefulWidget {
  const TabRowReveal({super.key, required this.shown, required this.child});

  final bool shown;
  final Widget child;

  @override
  State<TabRowReveal> createState() => _TabRowRevealState();
}

class _TabRowRevealState extends State<TabRowReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 160),
    reverseDuration: const Duration(milliseconds: 120),
    value: widget.shown ? 1 : 0,
  )..addStatusListener((_) => setState(() {}));

  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );

  @override
  void didUpdateWidget(TabRowReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shown == oldWidget.shown) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = widget.shown ? 1 : 0;
    } else if (widget.shown) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isDismissed) return const SizedBox.shrink();
    return SizeTransition(
      sizeFactor: _curve,
      alignment: Alignment.bottomCenter,
      child: FadeTransition(opacity: _curve, child: widget.child),
    );
  }
}

/// A tab: the note's icon, its title, and an × that is always there.
class _TabChip extends StatefulWidget {
  const _TabChip({
    super.key,
    required this.tab,
    required this.labelWidth,
    required this.cut,
    required this.active,
    required this.onSelect,
    required this.onClose,
    required this.onCloseOthers,
    required this.closeShortcut,
    required this.onPin,
  });

  final NoteTab tab;
  final double labelWidth;

  /// Whether the title is longer than the tab shows.
  final bool cut;
  final bool active;
  final VoidCallback onSelect;
  final VoidCallback onClose;
  final VoidCallback onCloseOthers;
  final String? closeShortcut;

  /// Pins the tab, or unpins a pinned one. Null where it has no pin.
  final VoidCallback? onPin;

  /// 2 · icon 16 · 8 · the label · 4 · the × in its 20 · 2.
  static double widthFor(double labelWidth) => labelWidth + 52;

  /// From the tab's left edge to the end of its label: the underline stops
  /// short of the ×.
  static double underlineFor(double labelWidth) => labelWidth + 26;

  @override
  State<_TabChip> createState() => _TabChipState();
}

class _TabChipState extends State<_TabChip> {
  bool _closeHovered = false;

  Future<void> _showMenu(Offset position) async {
    final choice = await showKapyContextMenu<String>(
      context: context,
      globalPosition: position,
      items: [
        for (final action in [
          if (widget.onPin != null)
            KapyMenuAction(
              value: 'pin',
              label: widget.tab.pinned == true ? 'Unpin tab' : 'Pin tab',
              icon: KapyIcons.pinOutlined,
            ),
          KapyMenuAction(
            value: 'close',
            label: 'Close tab',
            icon: KapyIcons.closeRounded,
            hint: widget.closeShortcut,
          ),
          const KapyMenuAction(
            value: 'others',
            label: 'Close other tabs',
            icon: KapyIcons.closeRounded,
          ),
        ])
          PopupMenuItem(
            key: ValueKey('tab-menu-${action.value}'),
            value: action.value,
            height: 36,
            child: KapyMenuActionRow(action, touch: false),
          ),
      ],
    );
    switch (choice) {
      case 'close':
        widget.onClose();
      case 'others':
        widget.onCloseOthers();
      case 'pin':
        widget.onPin?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final active = widget.active;
    final title = Text(
      widget.tab.title,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: NoteTabRow._labelStyle(
        active ? palette.textPrimary : palette.textSecondary,
        active: active,
      ),
    );
    return Semantics(
      button: true,
      selected: active,
      label: widget.tab.title,
      excludeSemantics: true,
      onTap: widget.onSelect,
      customSemanticsActions: {
        CustomSemanticsAction(
          label: widget.tab.pinned == true ? 'Unpin tab' : 'Pin tab',
        ): ?widget.onPin,
        const CustomSemanticsAction(label: 'Close tab'): widget.onClose,
      },
      child: Listener(
        // A middle click closes a tab, as it does in a browser.
        onPointerDown: (event) {
          if (event.buttons == kMiddleMouseButton) widget.onClose();
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onSelect,
          onSecondaryTapUp: (details) =>
              unawaited(_showMenu(details.globalPosition)),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: SizedBox(
              width: _TabChip.widthFor(widget.labelWidth),
              child: Stack(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Row(
                      children: [
                        KapyIcon(
                          widget.tab.pinned == true
                              ? KapyIcons.pinOutlined
                              : widget.tab.icon,
                          size: 16,
                          color: active
                              ? palette.textPrimary
                              : palette.textTertiary,
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: widget.labelWidth,
                          child: widget.cut
                              ? Tooltip(message: widget.tab.title, child: title)
                              : title,
                        ),
                        const SizedBox(width: 4),
                        Tooltip(
                          message: [
                            'Close tab',
                            ?widget.closeShortcut,
                          ].join('  '),
                          child: MouseRegion(
                            onEnter: (_) =>
                                setState(() => _closeHovered = true),
                            onExit: (_) =>
                                setState(() => _closeHovered = false),
                            child: GestureDetector(
                              key: ValueKey('close-tab-${widget.tab.id}'),
                              behavior: HitTestBehavior.opaque,
                              onTap: widget.onClose,
                              child: Container(
                                width: 20,
                                height: 20,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: _closeHovered
                                      ? palette.controlBackground
                                      : null,
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: KapyIcon(
                                  KapyIcons.closeRounded,
                                  size: 12,
                                  color: active
                                      ? palette.textSecondary
                                      : palette.textTertiary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (active)
                    Positioned(
                      left: 0,
                      bottom: 0,
                      width: _TabChip.underlineFor(widget.labelWidth),
                      height: 2,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.selectedBorder,
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// "N more": the tabs the row has no room for, as a menu with an × on each,
/// and Close other tabs at its end.
class _MoreButton extends StatelessWidget {
  const _MoreButton({
    required this.folded,
    required this.onSelect,
    required this.onClose,
    required this.onCloseOthers,
  });

  final List<NoteTab> folded;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onClose;
  final VoidCallback? onCloseOthers;

  /// 8 · the words · 4 · chevron 12 · 8.
  static double widthFor(double textWidth) => textWidth + 32;

  Future<void> _show(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final choice = await showKapyContextMenu<String>(
      context: context,
      globalPosition: box.localToGlobal(Offset(0, box.size.height + 4)),
      items: [
        for (final tab in folded)
          PopupMenuItem(
            key: ValueKey('more-tab-${tab.id}'),
            value: 'open:${tab.id}',
            height: 36,
            child: _FoldedTabRow(tab: tab),
          ),
        const PopupMenuDivider(height: 9),
        PopupMenuItem(
          key: const ValueKey('more-tab-close-others'),
          value: 'others',
          enabled: onCloseOthers != null,
          height: 36,
          child: KapyMenuActionRow(
            KapyMenuAction(
              value: 'others',
              label: 'Close other tabs',
              icon: KapyIcons.closeRounded,
              enabled: onCloseOthers != null,
            ),
            touch: false,
          ),
        ),
      ],
    );
    if (choice == null) return;
    final id = choice.substring(choice.indexOf(':') + 1);
    if (choice == 'others') {
      onCloseOthers?.call();
    } else if (choice.startsWith('open:')) {
      onSelect(id);
    } else if (choice.startsWith('close:')) {
      onClose(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final count = folded.length;
    return Semantics(
      button: true,
      label: '$count more ${count == 1 ? 'tab' : 'tabs'}',
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: const ValueKey('note-tabs-more'),
          onTap: () => unawaited(_show(context)),
          borderRadius: BorderRadius.circular(6),
          child: Ink(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: palette.controlBackground,
              border: Border.all(
                color: palette.controlBorder,
                width: AppHairline.of(context),
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count more',
                  maxLines: 1,
                  style: NoteTabRow._moreStyle(palette.textSecondary),
                ),
                const SizedBox(width: 4),
                KapyIcon(
                  KapyIcons.chevronDownRounded,
                  size: 12,
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

/// A folded tab in the "N more" menu: its icon, its title and its ×.
class _FoldedTabRow extends StatelessWidget {
  const _FoldedTabRow({required this.tab});

  final NoteTab tab;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Row(
      children: [
        KapyIcon(
          tab.icon,
          size: AppControlMetrics.iconControl,
          color: palette.textSecondary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            tab.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTypeScale.control,
              color: palette.textPrimary,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Tooltip(
          message: 'Close tab',
          child: GestureDetector(
            key: ValueKey('close-more-tab-${tab.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).pop('close:${tab.id}'),
            child: SizedBox.square(
              dimension: 20,
              child: Center(
                child: KapyIcon(
                  KapyIcons.closeRounded,
                  size: 12,
                  color: palette.textTertiary,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
