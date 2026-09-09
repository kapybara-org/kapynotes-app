import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../compact_icon_button.dart';
import 'editor_formatting.dart';

/// A compact formatting surface that appears beside a text selection.
///
/// Native edit actions remain available behind the trailing overflow button,
/// leaving the actions people use while writing visible in one row.
class NoteSelectionFormattingToolbar extends StatelessWidget {
  const NoteSelectionFormattingToolbar({
    super.key,
    required this.editableTextState,
    required this.paragraphStyle,
    required this.boldActive,
    required this.italicActive,
    required this.bulletsActive,
    required this.checklistActive,
    required this.onParagraphStylePressed,
    required this.onBoldPressed,
    required this.onItalicPressed,
    required this.onBulletsPressed,
    required this.onChecklistPressed,
    this.corrections = const [],
    this.onOpenLink,
    this.onCopyLink,
    this.onCopy,
    this.onCopyPlainText,
  });

  final EditableTextState editableTextState;
  final NoteParagraphStyle? paragraphStyle;
  final bool boldActive;
  final bool italicActive;
  final bool bulletsActive;
  final bool checklistActive;
  final VoidCallback onParagraphStylePressed;
  final VoidCallback onBoldPressed;
  final VoidCallback onItalicPressed;
  final VoidCallback onBulletsPressed;
  final VoidCallback onChecklistPressed;

  /// Spelling corrections for the misspelled word this selection covers.
  ///
  /// Right-clicking a misspelling selects it on macOS, and holding it does the
  /// same on a phone, so the corrections have to be reachable from the
  /// selection surface as well as from the caret menu.
  final List<ContextMenuButtonItem> corrections;
  final VoidCallback? onOpenLink;
  final VoidCallback? onCopyLink;
  final VoidCallback? onCopy;
  final VoidCallback? onCopyPlainText;

  static const double _screenPadding = 8;
  static const double _toolbarGap = 8;
  static const double _handleGap = 20;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final anchors = editableTextState.contextMenuAnchors;
    final primary = anchors.primaryAnchor - const Offset(0, _toolbarGap);
    final secondary =
        (anchors.secondaryAnchor ?? anchors.primaryAnchor) +
        const Offset(0, _handleGap);
    final topPadding = MediaQuery.paddingOf(context).top + _screenPadding;
    final localAdjustment = Offset(_screenPadding, topPadding);
    final nativeItems = editableTextState.contextMenuButtonItems
        .where(
          (item) => AdaptiveTextSelectionToolbar.getButtonLabel(
            context,
            item,
          ).isNotEmpty,
        )
        .map(
          (item) => item.type == ContextMenuButtonType.copy && onCopy != null
              ? ContextMenuButtonItem(
                  type: item.type,
                  label: item.label,
                  onPressed: () => _run(onCopy!),
                )
              : item,
        )
        .toList(growable: false);
    // Sits with the native Copy rather than out on the row: it is the same
    // action with one difference, and the row is for writing, not clipboard
    // housekeeping.
    final menuItems = [
      if (onCopyPlainText != null)
        ContextMenuButtonItem(
          label: 'Copy Plain Text',
          onPressed: () => _run(onCopyPlainText!),
        ),
      ...nativeItems,
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(
        _screenPadding,
        topPadding,
        _screenPadding,
        _screenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: TextSelectionToolbarLayoutDelegate(
          anchorAbove: primary - localAdjustment,
          anchorBelow: secondary - localAdjustment,
        ),
        child: RepaintBoundary(
          key: const ValueKey('selection-formatting-toolbar'),
          child: Material(
            color: palette.surfaceBackground,
            elevation: 0,
            shadowColor: Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            clipBehavior: Clip.antiAlias,
            child: _WithCorrections(
              corrections: corrections,
              child: SizedBox(
                height: 40,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onOpenLink != null)
                      _SelectionIconButton(
                        key: const ValueKey('selection-open-link'),
                        icon: Icons.open_in_new_rounded,
                        tooltip: 'Open link',
                        active: false,
                        onPressed: () => _run(onOpenLink!),
                      ),
                    if (onCopyLink != null)
                      _SelectionIconButton(
                        key: const ValueKey('selection-copy-link'),
                        icon: Icons.content_copy_rounded,
                        tooltip: 'Copy link',
                        active: false,
                        onPressed: () => _run(onCopyLink!),
                      ),
                    if (onOpenLink != null || onCopyLink != null)
                      Container(
                        width: 0.5,
                        height: 20,
                        color: palette.separator,
                      ),
                    _SelectionStyleCycle(
                      style: paragraphStyle,
                      onPressed: onParagraphStylePressed,
                    ),
                    Container(width: 0.5, height: 20, color: palette.separator),
                    _SelectionIconButton(
                      key: const ValueKey('selection-bold'),
                      icon: Icons.format_bold_rounded,
                      tooltip: 'Bold',
                      active: boldActive,
                      onPressed: () => _run(onBoldPressed),
                    ),
                    _SelectionIconButton(
                      key: const ValueKey('selection-italic'),
                      icon: Icons.format_italic_rounded,
                      tooltip: 'Italic',
                      active: italicActive,
                      onPressed: () => _run(onItalicPressed),
                    ),
                    _SelectionIconButton(
                      key: const ValueKey('selection-bullets'),
                      icon: Icons.format_list_bulleted_rounded,
                      tooltip: 'Bulleted list',
                      active: bulletsActive,
                      onPressed: () => _run(onBulletsPressed),
                    ),
                    _SelectionIconButton(
                      key: const ValueKey('selection-checklist'),
                      icon: Icons.checklist_rounded,
                      tooltip: 'Checklist',
                      active: checklistActive,
                      onPressed: () => _run(onChecklistPressed),
                    ),
                    if (menuItems.isNotEmpty)
                      _NativeActionsMenu(items: menuItems),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static void _run(VoidCallback callback) {
    ContextMenuController.removeAny();
    callback();
  }
}

/// Puts spelling corrections above the formatting row, the way the system
/// menu puts them above the editing actions.
///
/// Without any, the toolbar is the row alone, down to the pixel.
class _WithCorrections extends StatelessWidget {
  const _WithCorrections({required this.corrections, required this.child});

  final List<ContextMenuButtonItem> corrections;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (corrections.isEmpty) return child;
    final palette = context.palette;
    // The row decides how wide the toolbar is; a long correction is clipped
    // to it rather than stretching the surface across the note.
    return IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final correction in corrections)
            _CorrectionButton(item: correction),
          Container(height: 0.5, color: palette.separator),
          child,
        ],
      ),
    );
  }
}

class _CorrectionButton extends StatelessWidget {
  const _CorrectionButton({required this.item});

  final ContextMenuButtonItem item;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = AdaptiveTextSelectionToolbar.getButtonLabel(context, item);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('selection-correction-$label'),
        onTap: item.onPressed == null
            ? null
            : () {
                ContextMenuController.removeAny();
                item.onPressed!();
              },
        hoverColor: palette.hover,
        focusColor: palette.hover,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Container(
          height: 30,
          alignment: AlignmentDirectional.centerStart,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: palette.textPrimary,
              fontSize: AppTypeScale.small,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionStyleCycle extends StatelessWidget {
  const _SelectionStyleCycle({required this.style, required this.onPressed});

  final NoteParagraphStyle? style;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final next = nextParagraphStyle(style);
    return SizedBox(
      width: 78,
      height: 40,
      child: Center(
        child: Tooltip(
          message:
              'Text style: ${style?.label ?? 'Mixed'}. Click for ${next.label}',
          child: Material(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const ValueKey('selection-style'),
              onTap: onPressed,
              borderRadius: BorderRadius.circular(6),
              hoverColor: palette.hover,
              focusColor: palette.hover,
              splashColor: Colors.transparent,
              highlightColor: Colors.transparent,
              child: SizedBox(
                width: 70,
                height: AppControlMetrics.iconButtonExtent,
                child: Center(
                  child: Text(
                    style?.label ?? 'Mixed',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: palette.textPrimary,
                      fontSize: AppTypeScale.small,
                      fontWeight: FontWeight.w500,
                      fontStyle: style == NoteParagraphStyle.subtitle
                          ? FontStyle.italic
                          : FontStyle.normal,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectionIconButton extends StatelessWidget {
  const _SelectionIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: 32,
      height: 40,
      child: Center(
        child: CompactIconButton(
          tooltip: tooltip,
          selected: active,
          onPressed: onPressed,
          foregroundColor: active ? palette.textPrimary : palette.textSecondary,
          icon: Icon(icon, size: AppControlMetrics.iconControl),
        ),
      ),
    );
  }
}

class _NativeActionsMenu extends StatelessWidget {
  const _NativeActionsMenu({required this.items});

  final List<ContextMenuButtonItem> items;

  @override
  Widget build(BuildContext context) {
    final labels = [
      for (final item in items)
        AdaptiveTextSelectionToolbar.getButtonLabel(context, item),
    ];
    return SizedBox(
      width: 32,
      height: 40,
      child: Center(
        child: Builder(
          builder: (buttonContext) => CompactIconButton(
            key: const ValueKey('selection-more'),
            tooltip: 'Edit actions',
            onPressed: () async {
              final selected = await _showToolbarMenu(buttonContext, [
                for (var index = 0; index < items.length; index++)
                  PopupMenuItem(
                    value: index,
                    enabled: items[index].onPressed != null,
                    child: Text(labels[index]),
                  ),
              ]);
              if (selected != null) items[selected].onPressed?.call();
            },
            foregroundColor: context.palette.textSecondary,
            icon: Icon(
              Icons.more_horiz_rounded,
              size: AppControlMetrics.iconAction,
            ),
          ),
        ),
      ),
    );
  }
}

Future<T?> _showToolbarMenu<T>(
  BuildContext buttonContext,
  List<PopupMenuEntry<T>> items,
) {
  final navigator = Navigator.of(buttonContext);
  final button = buttonContext.findRenderObject()! as RenderBox;
  final overlay = navigator.overlay!.context.findRenderObject()! as RenderBox;
  final topLeft = button.localToGlobal(Offset.zero, ancestor: overlay);
  final bottomRight = button.localToGlobal(
    button.size.bottomRight(Offset.zero),
    ancestor: overlay,
  );
  final position = RelativeRect.fromRect(
    Rect.fromPoints(topLeft, bottomRight),
    Offset.zero & overlay.size,
  );
  // PopupMenuButton waits for its own State before firing onSelected. This
  // toolbar is intentionally removed as the menu opens, so keep the durable
  // Navigator context and await showMenu directly instead.
  ContextMenuController.removeAny();
  return showMenu<T>(
    context: navigator.context,
    position: position,
    items: items,
    requestFocus: false,
  );
}
