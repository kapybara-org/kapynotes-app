import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../context_menu.dart';
import '../keycap.dart';

/// The bar that floats at the foot of the page: Image, Video, Voice and
/// Drawing to put something in the note, Format for the writing tools, and
/// the slash that opens every command.
///
/// Riverbank's replacement for the desktop footer. A phone keeps its own.
class InsertBar extends StatelessWidget {
  const InsertBar({
    super.key,
    required this.onImage,
    required this.onVideo,
    required this.onVoice,
    required this.onDrawing,
    required this.formatActions,
    required this.onFormat,
    required this.onCommands,
    this.imageHint,
    this.voiceHint,
    this.imageBusy = false,
    this.videoBusy = false,
    this.voiceBusy = false,
  });

  /// Null where there is nothing to put a picture or a video in, or while
  /// one is on its way; the button is then shown off.
  final VoidCallback? onImage;
  final VoidCallback? onVideo;
  final VoidCallback? onVoice;
  final VoidCallback? onDrawing;

  /// What Format offers, each answered through [onFormat] by its value.
  final List<KapyMenuAction> formatActions;
  final ValueChanged<String> onFormat;
  final VoidCallback onCommands;

  /// The keys that do the same, for the tooltips.
  final String? imageHint;
  final String? voiceHint;

  /// A picture or a video on its way in, or a recording starting: the button
  /// turns into a spinner until it has.
  final bool imageBusy;
  final bool videoBusy;
  final bool voiceBusy;

  /// From the page's foot to the bar's.
  static const double bottom = 19;

  /// How much of the page's foot the bar covers: what the writing keeps clear
  /// so its last line can be scrolled above the bar.
  static const double clearance = 88;

  /// The narrowest page that has room for the bar's words, with a margin on
  /// either side. On a narrower one each button keeps its icon, and says what
  /// it does in its tooltip.
  static const double _labelledWidth = 620;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          _bar(context, labels: constraints.maxWidth >= _labelledWidth),
    );
  }

  Widget _bar(BuildContext context, {required bool labels}) {
    final palette = context.palette;
    final divider = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Container(width: 1, height: 20, color: palette.controlBorder),
    );
    return ExcludeFocus(
      child: Container(
        key: const ValueKey('insert-bar'),
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: palette.controlBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: palette.controlBorder, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: palette.shadowAt(0x80),
              offset: const Offset(0, 12),
              blurRadius: 28,
              spreadRadius: -14,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: [
            _BarButton(
              key: const ValueKey('insert-image'),
              icon: KapyIcons.photoLibraryOutlined,
              label: 'Image',
              labelled: labels,
              tooltip: imageBusy
                  ? 'Adding image…'
                  : _hinted('Insert image', imageHint),
              busy: imageBusy,
              onPressed: imageBusy ? null : onImage,
            ),
            _BarButton(
              key: const ValueKey('insert-video'),
              icon: KapyIcons.videoOutlined,
              label: 'Video',
              labelled: labels,
              tooltip: videoBusy ? 'Adding video…' : 'Insert video',
              busy: videoBusy,
              onPressed: videoBusy ? null : onVideo,
            ),
            _BarButton(
              key: const ValueKey('insert-voice'),
              icon: KapyIcons.micRounded,
              label: 'Voice',
              labelled: labels,
              tooltip: voiceBusy
                  ? 'Starting recording…'
                  : _hinted('Record a voice note', voiceHint),
              busy: voiceBusy,
              onPressed: voiceBusy ? null : onVoice,
            ),
            _BarButton(
              key: const ValueKey('insert-drawing'),
              icon: KapyIcons.penRounded,
              label: 'Drawing',
              labelled: labels,
              tooltip: 'New drawing',
              onPressed: onDrawing,
            ),
            divider,
            Builder(
              builder: (context) => _BarButton(
                key: const ValueKey('insert-format'),
                icon: KapyIcons.textFormatRounded,
                label: 'Format',
                labelled: labels,
                tooltip: 'Format',
                onPressed: () => _showFormat(context),
              ),
            ),
            divider,
            _BarButton(
              key: const ValueKey('insert-commands'),
              keycap: '/',
              label: 'Commands',
              labelled: labels,
              tooltip: 'Commands · /',
              quiet: true,
              onPressed: onCommands,
            ),
          ],
        ),
      ),
    );
  }

  static String _hinted(String label, String? hint) =>
      hint == null ? label : '$label · $hint';

  /// Opens above Format, its left edge on the button's.
  void _showFormat(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    unawaited(
      showKapyContextMenu<String>(
        context: context,
        globalPosition: box.localToGlobal(const Offset(0, -6)),
        requestFocus: false,
        items: [
          for (final action in formatActions)
            PopupMenuItem(
              key: ValueKey('format-${action.value}'),
              value: action.value,
              enabled: action.enabled,
              height: 36,
              child: KapyMenuActionRow(action, touch: false),
            ),
        ],
      ).then((choice) {
        if (choice != null) onFormat(choice);
      }),
    );
  }
}

/// One of the bar's buttons: Paper's 34px item, its icon or keycap before
/// its label, tinted on hover.
class _BarButton extends StatefulWidget {
  const _BarButton({
    super.key,
    this.icon,
    this.keycap,
    required this.label,
    required this.labelled,
    required this.tooltip,
    required this.onPressed,
    this.quiet = false,
    this.busy = false,
  });

  final KapyIconData? icon;
  final String? keycap;
  final String label;

  /// Whether [label] is shown beside the icon, or only named to assistive
  /// technology.
  final bool labelled;
  final String tooltip;
  final VoidCallback? onPressed;

  /// Commands, which reads as a hint rather than as an action.
  final bool quiet;
  final bool busy;

  @override
  State<_BarButton> createState() => _BarButtonState();
}

class _BarButtonState extends State<_BarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final enabled = widget.onPressed != null;
    final ink = !enabled || widget.quiet
        ? palette.textTertiary
        : palette.textPrimary;
    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: widget.label,
        excludeSemantics: true,
        onTap: widget.onPressed,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: _hovered && enabled ? palette.hover : null,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: widget.keycap == null ? 6 : 7,
                children: [
                  if (widget.busy)
                    SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: palette.textTertiary,
                      ),
                    )
                  else if (widget.icon case final icon?)
                    KapyIcon(
                      icon,
                      size: 16,
                      color: enabled
                          ? palette.textSecondary
                          : palette.textTertiary,
                    ),
                  if (widget.keycap case final keycap?) Keycap(keycap),
                  if (widget.labelled)
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontFamily: AppFonts.ui,
                        fontFamilyFallback: AppFonts.uiFallback,
                        fontSize: 13,
                        height: 16 / 13,
                        fontWeight: widget.quiet
                            ? FontWeight.w500
                            : FontWeight.w600,
                        color: ink,
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
