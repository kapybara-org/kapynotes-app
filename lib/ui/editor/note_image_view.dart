import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/note_attachment.dart';
import '../../data/blob_store.dart';
import '../../images/note_image_provider.dart';
import '../context_menu.dart';
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
/// a pale image from a pale page, and a small close control for immediate
/// removal. Resizing stays on hover because it is a desktop-only refinement.
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
    this.selected = false,
    this.fetch,
    this.uploadProgress,
    this.onSelect,
    this.onOpen,
    this.onCopy,
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

  /// Whether the image's U+FFFC anchor is inside the editor selection.
  final bool selected;

  final NoteImageFetcher? fetch;
  final ValueListenable<double?>? uploadProgress;
  final VoidCallback? onSelect;
  final VoidCallback? onOpen;
  final VoidCallback? onCopy;

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

  bool get _hasMenu =>
      widget.onOpen != null ||
      widget.onCopy != null ||
      widget.onRemove != null ||
      widget.onResize != null;

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

  void _tap() {
    widget.onSelect?.call();
    widget.onOpen?.call();
  }

  void _selectAndShowMenu(Offset position) {
    widget.onSelect?.call();
    // Selecting the U+FFFC asks EditableText to rebuild its WidgetSpans. Let
    // the pointer gesture finish before the menu consults that new tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showMenu(position);
    });
    // And ask for that frame. A post-frame callback is only run at the end of
    // a frame something else scheduled; selecting an image that is *already*
    // selected changes nothing, so nothing scheduled one, and the menu sat
    // waiting for whatever came next — the caret's blink, or the mouse
    // moving. Which is why the delay only ever showed up on the second
    // right-click.
    WidgetsBinding.instance.scheduleFrame();
  }

  Future<void> _showMenu(Offset position) async {
    if (!_hasMenu) return;

    final palette = context.palette;
    final error = Theme.of(context).colorScheme.error;
    final current = widget.ref.widthFactor;

    final choice = await showKapyContextMenu<String>(
      context: context,
      globalPosition: position,
      items: [
        if (widget.onOpen != null)
          PopupMenuItem(
            value: 'open',
            height: 36,
            child: Row(
              children: [
                KapyIcon(
                  KapyIcons.openInFullRounded,
                  size: AppControlMetrics.iconControl,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Open Image',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.control,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (widget.onCopy != null)
          PopupMenuItem(
            value: 'copy',
            height: 36,
            child: Row(
              children: [
                KapyIcon(
                  KapyIcons.copyRounded,
                  size: AppControlMetrics.iconControl,
                  color: palette.textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Copy Image',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.control,
                      color: palette.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
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
                        ? KapyIcon(
                            KapyIcons.checkRounded,
                            size: AppControlMetrics.iconControl,
                            color: palette.textSecondary,
                          )
                        : null,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      entry.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTypeScale.control,
                        color: palette.textPrimary,
                      ),
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
                KapyIcon(
                  KapyIcons.deleteOutlined,
                  size: AppControlMetrics.iconControl,
                  color: error,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Remove image',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.control,
                      color: error,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (choice == null) return;
    if (choice == 'open') {
      widget.onOpen?.call();
      return;
    }
    if (choice == 'copy') {
      widget.onCopy?.call();
      return;
    }
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
    final wantsThumbnail =
        (widget.box.cropped || AppPlatform.isMobile) &&
        widget.ref.thumbHash != null;
    // A source device can use its thumbnail before either object has an id.
    // Once the full object has an id, a missing thumb id means an interrupted
    // upload or legacy note, so mobile must use the full object until the
    // lightweight one is repaired rather than showing an empty rectangle.
    final thumbnailAvailable =
        wantsThumbnail &&
        (widget.ref.thumbId != null || widget.ref.attachmentId == null);
    final source = thumbnailAvailable ? widget.ref.thumbHash! : widget.ref.hash;
    final preview = widget.ref.previewBytes;
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final ImageProvider provider = preview == null
        ? NoteImageProvider(
            hash: source,
            fallbackHash: source == widget.ref.hash ? null : widget.ref.hash,
            store: widget.store,
            fetch: widget.fetch,
            cover: widget.box.cropped,
          )
        : ResizeImage.resizeIfNeeded(
            (widget.box.width * pixelRatio).ceil(),
            (widget.box.height * pixelRatio).ceil(),
            MemoryImage(preview),
          );

    Widget imageSurface(double? uploadProgress) {
      final preparing = widget.ref.isPreparing;
      final uploading = !widget.ref.isUploaded && widget.uploadProgress != null;
      final showsTransfer = preparing || uploading;
      final fraction = preparing ? null : uploadProgress?.clamp(0.0, 1.0);
      final blur = !showsTransfer
          ? 0.0
          : preparing
          ? 12.0
          : 10.0 * (1 - (fraction ?? 0));

      return ClipRRect(
        borderRadius: radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: palette.controlBackground,
            borderRadius: radius,
            border: Border.all(color: palette.separator, width: 0.5),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ImageFiltered(
                enabled: blur > 0.05,
                imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                child: Image(
                  image: provider,
                  width: widget.box.width,
                  height: widget.box.height,
                  fit: widget.box.cropped ? BoxFit.cover : BoxFit.contain,
                  gaplessPlayback: true,
                  filterQuality: FilterQuality.medium,
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
              if (showsTransfer)
                _ImageTransferCover(preparing: preparing, progress: fraction),
            ],
          ),
        ),
      );
    }

    final progress = widget.uploadProgress;
    final media = progress == null
        ? imageSurface(null)
        : ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (context, value, _) => imageSurface(value),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: noteImageGap / 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        cursor: widget.onSelect == null && widget.onOpen == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onSelect == null && widget.onOpen == null ? null : _tap,
          onSecondaryTapUp: !_hasMenu
              ? null
              : (details) => _selectAndShowMenu(details.globalPosition),
          onLongPressStart: !_hasMenu
              ? null
              : (details) => _selectAndShowMenu(details.globalPosition),
          child: SizedBox(
            width: widget.box.width,
            height: widget.box.height,
            child: Stack(
              children: [
                Positioned.fill(child: media),
                if (widget.selected)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        key: const ValueKey('selected-image-outline'),
                        decoration: BoxDecoration(
                          borderRadius: radius,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (widget.onRemove != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: IconButton(
                      key: ValueKey(
                        'remove-image-${widget.ref.hash}-${widget.ref.offset}',
                      ),
                      tooltip: 'Remove image',
                      onPressed: widget.onRemove,
                      icon: const KapyIcon(KapyIcons.closeRounded, size: 17),
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.58),
                        minimumSize: const Size.square(30),
                        maximumSize: const Size.square(30),
                        padding: EdgeInsets.zero,
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

class _ImageTransferCover extends StatelessWidget {
  const _ImageTransferCover({required this.preparing, required this.progress});

  final bool preparing;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final percentage = progress == null ? null : (progress! * 100).round();
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.18),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(
                  dimension: 17,
                  child: CircularProgressIndicator(
                    value: progress,
                    strokeWidth: 2,
                    color: Colors.white,
                    backgroundColor: Colors.white24,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  preparing
                      ? 'Preparing…'
                      : percentage == null
                      ? 'Waiting to upload…'
                      : 'Uploading $percentage%',
                  key: ValueKey(
                    preparing ? 'image-preparing' : 'image-upload-percentage',
                  ),
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: AppTypeScale.caption,
                    fontWeight: FontWeight.w600,
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
            KapyIcon(
              KapyIcons.imageOutlined,
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
class NoteImageViewer extends StatefulWidget {
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
      opaque: true,
      pageBuilder: (context, animation, secondary) => FadeTransition(
        opacity: animation,
        child: NoteImageViewer(ref: ref, store: store, fetch: fetch),
      ),
      transitionDuration: const Duration(milliseconds: 160),
    ),
  );

  @override
  State<NoteImageViewer> createState() => _NoteImageViewerState();
}

class _NoteImageViewerState extends State<NoteImageViewer> {
  static const double _tapSlop = 12;

  final GlobalKey _imageKey = GlobalKey();
  final GlobalKey _closeKey = GlobalKey();
  final Map<int, Offset> _outsideDown = {};
  final Set<int> _activePointers = {};

  bool _contains(GlobalKey key, Offset globalPosition) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final bounds = Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(box.size.bottomRight(Offset.zero)),
    );
    return bounds.contains(globalPosition);
  }

  void _pointerDown(PointerDownEvent event) {
    _activePointers.add(event.pointer);
    if (!_contains(_imageKey, event.position) &&
        !_contains(_closeKey, event.position)) {
      _outsideDown[event.pointer] = event.position;
    }
  }

  void _pointerUp(PointerUpEvent event) {
    _activePointers.remove(event.pointer);
    final down = _outsideDown.remove(event.pointer);
    if (down == null || _activePointers.isNotEmpty) return;
    if ((event.position - down).distance > _tapSlop) return;
    if (_contains(_imageKey, event.position) ||
        _contains(_closeKey, event.position)) {
      return;
    }
    Navigator.of(context).maybePop();
  }

  void _pointerCancel(PointerCancelEvent event) {
    _activePointers.remove(event.pointer);
    _outsideDown.remove(event.pointer);
  }

  @override
  Widget build(BuildContext context) {
    final ImageProvider provider = widget.ref.previewBytes == null
        ? NoteImageProvider(
            hash: widget.ref.hash,
            store: widget.store,
            fetch: widget.fetch,
          )
        : MemoryImage(widget.ref.previewBytes!);
    return Scaffold(
      backgroundColor: Colors.black,
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
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _pointerDown,
              onPointerUp: _pointerUp,
              onPointerCancel: _pointerCancel,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: InteractiveViewer(
                      maxScale: 8,
                      child: Center(
                        child: Image(
                          key: _imageKey,
                          image: provider,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: SafeArea(
                      child: IconButton(
                        key: _closeKey,
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const KapyIcon(KapyIcons.closeRounded),
                        color: Colors.white,
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
