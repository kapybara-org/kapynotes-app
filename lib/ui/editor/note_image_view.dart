import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/note_attachment.dart';
import '../../data/blob_store.dart';
import '../../images/note_image_provider.dart';
import 'note_image_layout.dart';

/// The sizes the menu offers, as a fraction of the writing column.
const Map<String, double> noteImageSizeChoices = {
  'Small': 0.35,
  'Medium': 0.6,
  'Full width': 1.0,
};

/// One image, as it appears in the middle of somebody's writing.
///
/// Deliberately quiet: rounded corners, a hairline border that only separates
/// a pale image from a pale page, and nothing else at rest. The controls —
/// the width handle, the menu — appear on hover or on a deliberate press,
/// because the thing being designed here is a page that reads well, and an
/// affordance painted permanently over a picture is one more thing between
/// the reader and it.
///
/// The box is sized before any bytes are read, from the width and height
/// stored on the ref. That is what keeps a note with ten images from reflowing
/// ten times as they load.
class NoteImageView extends StatefulWidget {
  const NoteImageView({
    super.key,
    required this.ref,
    required this.box,
    required this.store,
    this.columnWidth = 0,
    this.resizable = false,
    this.fetch,
    this.onTap,
    this.onResize,
    this.onResizeEnd,
    this.onRemove,
  });

  final NoteImageRef ref;
  final NoteImageBox box;
  final BlobStore store;

  /// Width of the writing column, which is what a width factor is a fraction
  /// of. Zero disables the handle: there is nothing to measure against.
  final double columnWidth;

  /// False for a tile in a gallery, whose width comes from how many share the
  /// line rather than from a setting of its own.
  final bool resizable;

  final NoteImageFetcher? fetch;
  final VoidCallback? onTap;

  /// Called continuously while dragging, so the picture follows the pointer.
  final ValueChanged<double>? onResize;

  /// Called once the drag ends, which is when the new width is worth saving.
  final VoidCallback? onResizeEnd;

  final VoidCallback? onRemove;

  @override
  State<NoteImageView> createState() => _NoteImageViewState();
}

class _NoteImageViewState extends State<NoteImageView> {
  bool _hovering = false;
  bool _dragging = false;

  bool get _hasMenu => widget.onRemove != null || widget.onResize != null;

  bool get _showsHandle =>
      widget.resizable &&
      widget.onResize != null &&
      widget.columnWidth > 0 &&
      AppPlatform.hasPointer &&
      (_hovering || _dragging);

  void _drag(double dx) {
    final onResize = widget.onResize;
    if (onResize == null || widget.columnWidth <= 0) return;
    // The handle sits on the right edge, so a pointer moving right widens.
    onResize(
      clampImageWidthFactor((widget.box.width + dx) / widget.columnWidth),
    );
  }

  Future<void> _showMenu(Offset position) async {
    if (!_hasMenu) return;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    final palette = context.palette;
    final error = Theme.of(context).colorScheme.error;
    final current = widget.ref.widthFactor;

    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        if (widget.resizable && widget.onResize != null)
          for (final entry in noteImageSizeChoices.entries)
            PopupMenuItem(
              value: entry.key,
              height: 36,
              child: Row(
                children: [
                  // A tick rather than a highlight: the row says which width
                  // this image is at, and stays readable when none matches
                  // because the handle was dragged somewhere in between.
                  SizedBox(
                    width: AppControlMetrics.iconControl,
                    child: (current - entry.value).abs() < 0.02
                        ? Icon(
                            Icons.check_rounded,
                            size: AppControlMetrics.iconControl,
                            color: palette.textSecondary,
                          )
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    entry.key,
                    style: TextStyle(
                      fontSize: AppTypeScale.control,
                      color: palette.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
        if (widget.onRemove != null)
          PopupMenuItem(
            value: 'remove',
            height: 36,
            child: Row(
              children: [
                Icon(
                  Icons.delete_outline_rounded,
                  size: AppControlMetrics.iconControl,
                  color: error,
                ),
                const SizedBox(width: 10),
                Text(
                  'Remove image',
                  style: TextStyle(
                    fontSize: AppTypeScale.control,
                    color: error,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (choice == null) return;
    if (choice == 'remove') {
      widget.onRemove?.call();
      return;
    }
    final size = noteImageSizeChoices[choice];
    if (size != null) {
      widget.onResize?.call(size);
      widget.onResizeEnd?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final radius = BorderRadius.circular(widget.box.cropped ? 8 : 10);

    // The thumbnail is enough for a tile and for the ordinary reading width;
    // the full image is what the viewer opens. Fetching the original to paint
    // it 320px wide is the difference between a note that opens instantly and
    // one that does not.
    final source = widget.box.cropped && widget.ref.thumbHash != null
        ? widget.ref.thumbHash!
        : widget.ref.hash;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: noteImageGap / 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        cursor: widget.onTap == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapDown: !_hasMenu
              ? null
              : (details) => _showMenu(details.globalPosition),
          onLongPressStart: !_hasMenu
              ? null
              : (details) => _showMenu(details.globalPosition),
          child: SizedBox(
            width: widget.box.width,
            height: widget.box.height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ClipRRect(
                    borderRadius: radius,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: palette.controlBackground,
                        borderRadius: radius,
                        border: Border.all(
                          color: palette.separator,
                          width: 0.5,
                        ),
                      ),
                      child: Image(
                        image: NoteImageProvider(
                          hash: source,
                          store: widget.store,
                          fetch: widget.fetch,
                        ),
                        width: widget.box.width,
                        height: widget.box.height,
                        fit: widget.box.cropped ? BoxFit.cover : BoxFit.contain,
                        gaplessPlayback: true,
                        filterQuality: FilterQuality.medium,
                        // No spinner. A note that flickers a progress ring
                        // over every picture on open reads as broken; an empty
                        // box that fills in reads as loading, which it is.
                        frameBuilder: (context, child, frame, wasSync) =>
                            AnimatedOpacity(
                              opacity: frame == null ? 0 : 1,
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              child: child,
                            ),
                        errorBuilder: (context, error, stack) => _Unavailable(
                          palette: palette,
                          compact: widget.box.height < 120,
                        ),
                      ),
                    ),
                  ),
                ),
                if (_showsHandle)
                  Positioned(
                    top: 0,
                    bottom: 0,
                    right: 0,
                    child: _WidthHandle(
                      key: const ValueKey('image-width-handle'),
                      active: _dragging,
                      onDragStart: () => setState(() => _dragging = true),
                      onDrag: _drag,
                      onDragEnd: () {
                        if (!_dragging) return;
                        setState(() => _dragging = false);
                        widget.onResizeEnd?.call();
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The grab bar on an image's trailing edge.
///
/// Inside the picture rather than outside it, because an image sits in a line
/// of text: a handle hanging off the edge would either overlap the writing
/// beside it or force every image to reserve room it does not otherwise need.
///
/// Raw pointer events rather than a drag recognizer, deliberately. This sits
/// inside an editable, whose own selection recognizer also wants horizontal
/// drags — put both in the gesture arena and the handle loses. A [Listener]
/// is not in the arena at all, so dragging the edge of a picture resizes it
/// instead of selecting the text behind it.
class _WidthHandle extends StatelessWidget {
  const _WidthHandle({
    super.key,
    required this.active,
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
  });

  final bool active;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => onDragStart(),
        onPointerMove: (event) => onDrag(event.delta.dx),
        onPointerUp: (_) => onDragEnd(),
        onPointerCancel: (_) => onDragEnd(),
        child: Padding(
          // A 20pt strip to aim at, holding a 5pt bar to look at.
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 5,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: active ? 0.95 : 0.7),
              borderRadius: BorderRadius.circular(3),
              boxShadow: const [
                BoxShadow(color: Color(0x55000000), blurRadius: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What an image looks like when its bytes are not on this device.
///
/// Reachable in one honest situation: the note synced before the picture did.
/// It says so rather than showing a broken-file glyph, because the bytes are
/// very likely on their way.
class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.palette, required this.compact});

  final CalcPalette palette;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: palette.controlBackground,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.image_outlined,
              size: compact ? 18 : 24,
              color: palette.textTertiary,
            ),
            if (!compact) ...[
              const SizedBox(height: 6),
              Text(
                'Not on this device yet',
                style: TextStyle(
                  fontSize: AppTypeScale.caption,
                  color: palette.textTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The full picture, over everything else.
///
/// Pinch or scroll to zoom, drag to move, tap the backdrop or press Escape to
/// leave. Nothing is cropped here and nothing is capped: this is the screen
/// that exists so the reading view never has to show the whole thing.
class NoteImageViewer extends StatelessWidget {
  const NoteImageViewer({
    super.key,
    required this.ref,
    required this.store,
    this.fetch,
  });

  final NoteImageRef ref;
  final BlobStore store;
  final NoteImageFetcher? fetch;

  static Future<void> open(
    BuildContext context, {
    required NoteImageRef ref,
    required BlobStore store,
    NoteImageFetcher? fetch,
  }) => Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black.withValues(alpha: 0.86),
      barrierDismissible: true,
      pageBuilder: (context, animation, secondary) => FadeTransition(
        opacity: animation,
        child: NoteImageViewer(ref: ref, store: store, fetch: fetch),
      ),
      transitionDuration: const Duration(milliseconds: 160),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) => Navigator.of(context).maybePop(),
            ),
          },
          child: Focus(
            autofocus: true,
            child: Stack(
              children: [
                // The backdrop is the dismiss target, so there is always a
                // large safe place to tap to get out.
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                ),
                Positioned.fill(
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: InteractiveViewer(
                        maxScale: 8,
                        child: Center(
                          child: Image(
                            image: NoteImageProvider(
                              hash: ref.hash,
                              store: store,
                              fetch: fetch,
                            ),
                            fit: BoxFit.contain,
                            filterQuality: FilterQuality.high,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: SafeArea(
                    child: IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close_rounded),
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
