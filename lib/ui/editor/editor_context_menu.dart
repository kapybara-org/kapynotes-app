import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../context_menu.dart';

/// The editor's ordinary Cut, Copy, Paste and custom actions.
///
/// Touch keeps the platform toolbar people already know. Pointer platforms
/// use the same quiet surface as the rest of Kapy Notes instead of dropping a
/// second visual language into the editor.
class NoteEditorContextMenu extends StatelessWidget {
  const NoteEditorContextMenu({
    super.key,
    required this.anchors,
    required this.buttonItems,
  });

  final TextSelectionToolbarAnchors anchors;
  final List<ContextMenuButtonItem> buttonItems;

  static const double _screenPadding = 8;

  @override
  Widget build(BuildContext context) {
    final visibleItems = [
      for (final item in buttonItems)
        if (AdaptiveTextSelectionToolbar.getButtonLabel(
          context,
          item,
        ).isNotEmpty)
          item,
    ];
    if (visibleItems.isEmpty) return const SizedBox.shrink();

    // The native touch toolbar remains the most familiar and compact way to
    // edit text around selection handles and the on-screen keyboard.
    if (!AppPlatform.hasPointer) {
      return AdaptiveTextSelectionToolbar.buttonItems(
        anchors: anchors,
        buttonItems: visibleItems,
      );
    }

    final topPadding = MediaQuery.paddingOf(context).top + _screenPadding;
    final localAdjustment = Offset(_screenPadding, topPadding);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        _screenPadding,
        topPadding,
        _screenPadding,
        _screenPadding,
      ),
      child: CustomSingleChildLayout(
        delegate: DesktopTextSelectionToolbarLayoutDelegate(
          anchor: anchors.primaryAnchor - localAdjustment,
        ),
        child: RepaintBoundary(
          key: const ValueKey('editor-context-menu'),
          child: KapyContextMenuSurface(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in visibleItems)
                  _EditorContextMenuButton(item: item),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EditorContextMenuButton extends StatelessWidget {
  const _EditorContextMenuButton({required this.item});

  final ContextMenuButtonItem item;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final label = AdaptiveTextSelectionToolbar.getButtonLabel(context, item);
    final enabled = item.onPressed != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('editor-context-action-$label'),
        onTap: !enabled
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
          height: 32,
          alignment: AlignmentDirectional.centerStart,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: enabled ? palette.textPrimary : palette.textTertiary,
              fontSize: AppTypeScale.control,
              fontWeight: AppWeight.font(AppWeight.body),
              fontVariations: AppWeight.wght(AppWeight.body),
            ),
          ),
        ),
      ),
    );
  }
}
