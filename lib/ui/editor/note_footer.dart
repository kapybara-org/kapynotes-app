import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/shortcut_prefs.dart';
import '../compact_icon_button.dart';
import '../glass_surface.dart';
import '../mobile_page_swipe.dart';
import 'editor_formatting.dart';

/// What a button is called, with the key that does it after a separator.
///
/// A shortcut the user has cleared leaves the name on its own, rather than a
/// tooltip trailing off after a dot into nothing.
String _withShortcut(String label, ShortcutBinding? shortcut) =>
    shortcut == null ? label : '$label · ${shortcut.displayLabel}';

/// Short enough for the footer while still naming every small collaboration.
String? typingStatusText(List<String> names) {
  final unique = <String>[];
  for (final name in names) {
    final clean = name.trim();
    if (clean.isNotEmpty && !unique.contains(clean)) unique.add(clean);
  }
  return switch (unique.length) {
    0 => null,
    1 => '${unique[0]} is typing...',
    2 => '${unique[0]} and ${unique[1]} are typing...',
    _ => '${unique[0]} and ${unique.length - 1} others are typing...',
  };
}

/// Persistent note status bar inspired by the compact footer in Numi.
class NoteFooter extends StatelessWidget {
  const NoteFooter({
    super.key,
    required this.total,
    this.typingNames = const [],
    this.readOnly = false,
    required this.paragraphStyleShortcut,
    required this.boldShortcut,
    required this.italicShortcut,
    required this.bulletsShortcut,
    required this.checklistShortcut,
    required this.imageShortcut,
    required this.voiceShortcut,
    required this.onParagraphStylePressed,
    required this.onBoldPressed,
    required this.onItalicPressed,
    required this.onBulletsPressed,
    required this.onChecklistPressed,
    this.onInsertImagePressed,
    this.imageBusy = false,
    this.onRecordVoicePressed,
    this.voiceBusy = false,
    required this.onIndentPressed,
    required this.onOutdentPressed,
    required this.showIndentControls,
    required this.canIndent,
    required this.canOutdent,
    required this.boldActive,
    required this.italicActive,
    required this.bulletsActive,
    required this.checklistActive,
    required this.paragraphStyle,
  });

  final String? total;
  final List<String> typingNames;
  final bool readOnly;
  final ShortcutBinding? paragraphStyleShortcut;
  final ShortcutBinding? boldShortcut;
  final ShortcutBinding? italicShortcut;
  final ShortcutBinding? bulletsShortcut;
  final ShortcutBinding? checklistShortcut;
  final ShortcutBinding? imageShortcut;
  final ShortcutBinding? voiceShortcut;
  final VoidCallback onParagraphStylePressed;
  final VoidCallback onBoldPressed;
  final VoidCallback onItalicPressed;
  final VoidCallback onBulletsPressed;
  final VoidCallback onChecklistPressed;

  /// Null where the editor has no image store to put a picture in, which is
  /// only ever a test. The button is hidden rather than disabled: a control
  /// that can never do anything is worse than no control.
  final VoidCallback? onInsertImagePressed;
  final bool imageBusy;

  /// Starts a recording, or stops the one running.
  final VoidCallback? onRecordVoicePressed;
  final bool voiceBusy;

  /// Nesting only appears once the caret is on a list line. The row shares its
  /// width with the total readout, and on a narrow phone two permanent extra
  /// buttons would crowd it for the sake of controls that would do nothing.
  final VoidCallback onIndentPressed;
  final VoidCallback onOutdentPressed;
  final bool showIndentControls;
  final bool canIndent;
  final bool canOutdent;
  final bool boldActive;
  final bool italicActive;
  final bool bulletsActive;
  final bool checklistActive;
  final NoteParagraphStyle? paragraphStyle;

  static double get height => AppControlMetrics.footerHeight;

  /// Gap between the bar's edge and the control nearest it.
  ///
  /// The two sides differ by design. An icon button paints a hover surface
  /// wider than its glyph, so its optical edge already sits inside its box; a
  /// text run has no such padding and needs the margin spelled out to look
  /// equally inset.
  static double get _edgeInset => AppPlatform.hasPointer ? 12 : 8;
  static double get _textEdgeInset => AppPlatform.hasPointer ? 12 : 10;

  /// Between the controls and the readout at the other end. They are
  /// different in kind — one changes the note, the other only reports on it —
  /// and butted together they would read as one row of controls.
  static double get _groupGap => AppPlatform.hasPointer ? 16 : 14;

  /// Extra distinction between insert actions and text formatting. Proximity
  /// should reveal the two jobs before somebody has to inspect the tooltips.
  static double get _formatGroupGap => AppPlatform.hasPointer ? 8 : 0;

  /// Trims an available width down to a whole number of buttons.
  ///
  /// The formatting row scrolls when it will not fit, which is the right
  /// behaviour, but a row cut mid-button reads as a rendering fault rather
  /// than as something to scroll. Cutting on a button boundary makes it
  /// obvious that there is more, and keeps every visible control tappable.
  static double _snapToWholeButtons(
    double available,
    double rowWidth, {
    int leadingButtonCount = 0,
    double internalGap = 0,
  }) {
    if (available <= 0) return 0;
    if (available >= rowWidth) return available;
    final extent = AppControlMetrics.footerButtonSlotExtent;
    if (extent <= 0 || available <= extent) return available;
    final leadingWidth = leadingButtonCount * extent;
    if (internalGap > 0 && available > leadingWidth) {
      if (available < leadingWidth + internalGap + extent) {
        return leadingWidth;
      }
      return ((available - internalGap) / extent).floor() * extent +
          internalGap;
    }
    return (available / extent).floor() * extent;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final typingText = typingStatusText(typingNames);
    // The bar holds the bottom edge the way the toolbar holds the top one: its
    // background runs under the home indicator or the navigation bar while the
    // controls stay above them. Insetting the page instead left the bar
    // floating over a strip of empty background.
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    // The control strip below scrolls sideways when it does not fit, so a
    // horizontal drag that lands here is aimed at it — not at the page swipes
    // that open the notes list or start a new note.
    return SizedBox(
      height: AppControlMetrics.scaleBar(context, height) + bottomInset,
      child: PageSwipeExclusion(
        child: GlassSurface(
          color: palette.surfaceBackground.withMultipliedAlpha(0.94),
          border: Border(top: BorderSide(color: palette.separator, width: 0.5)),
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomInset),
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Wide phones still need the shorter label beside five formatting
                // controls and a grouped currency value. Desktop keeps its existing
                // label until the window reaches the genuinely narrow breakpoint.
                final compactTotal =
                    constraints.maxWidth < (AppPlatform.isMobile ? 520 : 420);

                // The controls start at the left edge and grow rightward, which is
                // the whole point of not centring them: the nesting buttons appear
                // the moment the caret lands on a list line, and a centred row that
                // grows from five squares to seven slides everything already in it
                // sideways by a full button — 44pt under a thumb. Tap Bullets and
                // Bold would leave from under the finger that just pressed it.
                // The formatting revealer plus its five tools, and the insert
                // buttons when there is somewhere to put their attachments.
                final insertButtonCount = readOnly
                    ? 0
                    : (onInsertImagePressed == null ? 0 : 1) +
                          (onRecordVoicePressed == null ? 0 : 1);
                final buttonCount = readOnly
                    ? 0
                    : 6 + insertButtonCount + (showIndentControls ? 2 : 0);
                final insertFormatGap = insertButtonCount == 0
                    ? 0.0
                    : _formatGroupGap;
                final rowWidth =
                    buttonCount * AppControlMetrics.footerButtonSlotExtent +
                    insertFormatGap;
                final fixed =
                    _edgeInset + rowWidth + _groupGap + _textEdgeInset;
                // Whatever is genuinely left over, up to a readable maximum. The
                // floor is what makes the controls scroll instead of the readout
                // shrinking to nothing on a narrow phone with nesting showing.
                final readoutSlot =
                    typingText == null && !readOnly && total == null
                    ? 0.0
                    : typingText != null || readOnly
                    ? (constraints.maxWidth - fixed).clamp(112.0, 220.0)
                    : (constraints.maxWidth - fixed).clamp(40.0, 180.0);

                return Row(
                  children: [
                    SizedBox(width: _edgeInset),
                    if (!readOnly)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: _snapToWholeButtons(
                            math.max(
                              0,
                              constraints.maxWidth -
                                  _edgeInset -
                                  readoutSlot -
                                  _groupGap -
                                  _textEdgeInset,
                            ),
                            rowWidth,
                            leadingButtonCount: insertButtonCount,
                            internalGap: insertFormatGap,
                          ),
                        ),
                        // Scrolls only when it cannot fit, which a narrow phone with
                        // the nesting controls showing still cannot. Left-anchored,
                        // so what is on screen stays where it was.
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          physics: const ClampingScrollPhysics(),
                          child: ExcludeFocus(
                            child: Row(
                              key: const ValueKey('note-formatting-controls'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Adding a picture is not a style, and it leads the
                                // row rather than trailing it: on a narrow phone the
                                // row scrolls, and the first slot is the only one
                                // guaranteed to be on screen.
                                if (onInsertImagePressed != null) ...[
                                  _FormatButton(
                                    key: const ValueKey('insert-image'),
                                    icon: AppPlatform.isMobile
                                        ? Icons.camera_alt_outlined
                                        : Icons.image_outlined,
                                    tooltip: imageBusy
                                        ? 'Adding photo…'
                                        : _withShortcut(
                                            AppPlatform.isMobile
                                                ? 'Take or choose a photo'
                                                : 'Add an image',
                                            imageShortcut,
                                          ),
                                    active: false,
                                    busy: imageBusy,
                                    progressKey: const ValueKey(
                                      'insert-image-progress',
                                    ),
                                    onPressed: imageBusy
                                        ? null
                                        : onInsertImagePressed,
                                  ),
                                ],
                                if (onRecordVoicePressed != null)
                                  _FormatButton(
                                    key: const ValueKey('record-voice'),
                                    icon: Icons.mic_none_rounded,
                                    tooltip: voiceBusy
                                        ? 'Starting recording…'
                                        : _withShortcut(
                                            'Record a voice note',
                                            voiceShortcut,
                                          ),
                                    active: false,
                                    busy: voiceBusy,
                                    progressKey: const ValueKey(
                                      'record-voice-progress',
                                    ),
                                    onPressed: voiceBusy
                                        ? null
                                        : onRecordVoicePressed,
                                  ),
                                if (onInsertImagePressed != null ||
                                    onRecordVoicePressed != null)
                                  SizedBox(width: _formatGroupGap),
                                _ExpandableFormattingControls(
                                  paragraphStyle: paragraphStyle,
                                  paragraphStyleShortcut:
                                      paragraphStyleShortcut,
                                  boldShortcut: boldShortcut,
                                  italicShortcut: italicShortcut,
                                  bulletsShortcut: bulletsShortcut,
                                  checklistShortcut: checklistShortcut,
                                  onParagraphStylePressed:
                                      onParagraphStylePressed,
                                  onBoldPressed: onBoldPressed,
                                  onItalicPressed: onItalicPressed,
                                  onBulletsPressed: onBulletsPressed,
                                  onChecklistPressed: onChecklistPressed,
                                  onIndentPressed: onIndentPressed,
                                  onOutdentPressed: onOutdentPressed,
                                  showIndentControls: showIndentControls,
                                  canIndent: canIndent,
                                  canOutdent: canOutdent,
                                  boldActive: boldActive,
                                  italicActive: italicActive,
                                  bulletsActive: bulletsActive,
                                  checklistActive: checklistActive,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // Everything between the controls and the readout. The only
                    // flexible thing in the row, so the total is pinned right
                    // however wide the window is.
                    const Spacer(),
                    // Collaboration temporarily takes this quiet status slot;
                    // the calculation total returns as soon as typing stops.
                    if (typingText != null) ...[
                      SizedBox(
                        width: readoutSlot,
                        child: Semantics(
                          liveRegion: true,
                          label: typingText,
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: palette.function,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  typingText,
                                  key: const ValueKey('typing-presence'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    fontSize: AppTypeScale.caption,
                                    fontWeight: FontWeight.w500,
                                    color: palette.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      SizedBox(width: _textEdgeInset),
                    ] else if (readOnly) ...[
                      SizedBox(
                        width: readoutSlot,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Icon(
                              Icons.visibility_outlined,
                              size: AppControlMetrics.iconAction,
                              color: palette.textTertiary,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'View only',
                              key: const ValueKey('view-only-status'),
                              style: TextStyle(
                                fontSize: AppTypeScale.caption,
                                fontWeight: FontWeight.w500,
                                color: palette.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(width: _textEdgeInset),
                    ] else if (total case final total?) ...[
                      SizedBox(
                        width: readoutSlot,
                        child: Text.rich(
                          key: const ValueKey('note-total'),
                          TextSpan(
                            text: compactTotal ? '\u03a3 ' : 'Total: ',
                            style: TextStyle(
                              fontSize: AppTypeScale.caption,
                              fontWeight: FontWeight.w500,
                              color: palette.textTertiary,
                            ),
                            children: [
                              TextSpan(
                                text: total,
                                style: TextStyle(
                                  fontWeight: FontWeight.w500,
                                  color: palette.textPrimary,
                                ),
                              ),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                        ),
                      ),
                      SizedBox(width: _textEdgeInset),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Keeps writing tools out of the way until the user reaches for them.
///
/// Pointer devices reveal the row as the pointer enters this control. Touch
/// devices use the same leading button as an explicit toggle, since hover is
/// not a meaningful interaction there.
class _ExpandableFormattingControls extends StatefulWidget {
  const _ExpandableFormattingControls({
    required this.paragraphStyle,
    required this.paragraphStyleShortcut,
    required this.boldShortcut,
    required this.italicShortcut,
    required this.bulletsShortcut,
    required this.checklistShortcut,
    required this.onParagraphStylePressed,
    required this.onBoldPressed,
    required this.onItalicPressed,
    required this.onBulletsPressed,
    required this.onChecklistPressed,
    required this.onIndentPressed,
    required this.onOutdentPressed,
    required this.showIndentControls,
    required this.canIndent,
    required this.canOutdent,
    required this.boldActive,
    required this.italicActive,
    required this.bulletsActive,
    required this.checklistActive,
  });

  final NoteParagraphStyle? paragraphStyle;
  final ShortcutBinding? paragraphStyleShortcut;
  final ShortcutBinding? boldShortcut;
  final ShortcutBinding? italicShortcut;
  final ShortcutBinding? bulletsShortcut;
  final ShortcutBinding? checklistShortcut;
  final VoidCallback onParagraphStylePressed;
  final VoidCallback onBoldPressed;
  final VoidCallback onItalicPressed;
  final VoidCallback onBulletsPressed;
  final VoidCallback onChecklistPressed;
  final VoidCallback onIndentPressed;
  final VoidCallback onOutdentPressed;
  final bool showIndentControls;
  final bool canIndent;
  final bool canOutdent;
  final bool boldActive;
  final bool italicActive;
  final bool bulletsActive;
  final bool checklistActive;

  @override
  State<_ExpandableFormattingControls> createState() =>
      _ExpandableFormattingControlsState();
}

class _ExpandableFormattingControlsState
    extends State<_ExpandableFormattingControls> {
  bool _expanded = false;

  void _setExpanded(bool value) {
    if (_expanded == value) return;
    setState(() => _expanded = value);
  }

  @override
  Widget build(BuildContext context) {
    final anyActive =
        widget.boldActive ||
        widget.italicActive ||
        widget.bulletsActive ||
        widget.checklistActive ||
        (widget.paragraphStyle != null &&
            widget.paragraphStyle != NoteParagraphStyle.text);

    return MouseRegion(
      onEnter: AppPlatform.hasPointer ? (_) => _setExpanded(true) : null,
      onExit: AppPlatform.hasPointer ? (_) => _setExpanded(false) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _FormatButton(
            key: const ValueKey('formatting-toggle'),
            icon: Icons.text_format_rounded,
            tooltip: AppPlatform.hasPointer
                ? 'Formatting tools'
                : (_expanded
                      ? 'Hide formatting tools'
                      : 'Show formatting tools'),
            active: anyActive || _expanded,
            onPressed: AppPlatform.hasPointer
                ? () => _setExpanded(true)
                : () => _setExpanded(!_expanded),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerLeft,
            child: ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: _expanded ? 1 : 0,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Everything that changes a whole line comes first — the
                    // style, then the two kinds of list — and the marks that
                    // change a word follow. Nesting stays at the end, beside
                    // the lists it belongs to.
                    _StyleCycleButton(
                      key: const ValueKey('format-style'),
                      style: widget.paragraphStyle,
                      shortcut: widget.paragraphStyleShortcut,
                      onPressed: widget.onParagraphStylePressed,
                    ),
                    _FormatButton(
                      key: const ValueKey('format-checklist'),
                      icon: Icons.checklist_rounded,
                      tooltip: _withShortcut(
                        'Checklist',
                        widget.checklistShortcut,
                      ),
                      active: widget.checklistActive,
                      onPressed: widget.onChecklistPressed,
                    ),
                    _FormatButton(
                      key: const ValueKey('format-bullets'),
                      icon: Icons.format_list_bulleted_rounded,
                      tooltip: _withShortcut(
                        'Bulleted list',
                        widget.bulletsShortcut,
                      ),
                      active: widget.bulletsActive,
                      onPressed: widget.onBulletsPressed,
                    ),
                    _FormatButton(
                      key: const ValueKey('format-bold'),
                      icon: Icons.format_bold_rounded,
                      tooltip: _withShortcut('Bold', widget.boldShortcut),
                      active: widget.boldActive,
                      onPressed: widget.onBoldPressed,
                    ),
                    _FormatButton(
                      key: const ValueKey('format-italic'),
                      icon: Icons.format_italic_rounded,
                      tooltip: _withShortcut('Italic', widget.italicShortcut),
                      active: widget.italicActive,
                      onPressed: widget.onItalicPressed,
                    ),
                    if (widget.showIndentControls) ...[
                      _FormatButton(
                        key: const ValueKey('format-outdent'),
                        icon: Icons.format_indent_decrease_rounded,
                        tooltip: 'Move out \u00b7 Shift + Tab',
                        active: false,
                        onPressed: widget.canOutdent
                            ? widget.onOutdentPressed
                            : null,
                      ),
                      _FormatButton(
                        key: const ValueKey('format-indent'),
                        icon: Icons.format_indent_increase_rounded,
                        tooltip: 'Move in \u00b7 Tab',
                        active: false,
                        onPressed: widget.canIndent
                            ? widget.onIndentPressed
                            : null,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StyleCycleButton extends StatelessWidget {
  const _StyleCycleButton({
    super.key,
    required this.style,
    required this.shortcut,
    required this.onPressed,
  });

  final NoteParagraphStyle? style;
  final ShortcutBinding? shortcut;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final active = style != null && style != NoteParagraphStyle.text;
    final label = switch (style) {
      NoteParagraphStyle.heading => 'H',
      NoteParagraphStyle.subtitle => 'S',
      _ => 'Aa',
    };
    return _FooterButtonSlot(
      child: CompactIconButton(
        extent: AppControlMetrics.footerButtonExtent,
        tooltip: _withShortcut(
          'Text style: ${style?.label ?? 'Mixed'}',
          shortcut,
        ),
        selected: active,
        foregroundColor: active ? palette.textPrimary : palette.textTertiary,
        onPressed: onPressed,
        icon: Text(
          label,
          style: TextStyle(
            fontSize: AppPlatform.hasPointer
                ? AppTypeScale.control
                : AppTypeScale.caption,
            fontWeight: FontWeight.w500,
            fontStyle: style == NoteParagraphStyle.subtitle
                ? FontStyle.italic
                : FontStyle.normal,
          ),
        ),
      ),
    );
  }
}

class _FormatButton extends StatelessWidget {
  const _FormatButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.active,
    required this.onPressed,
    this.busy = false,
    this.progressKey,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final bool busy;
  final Key? progressKey;

  /// Null disables the button, which is how the nesting controls show that a
  /// list is already at the margin or at the deepest level.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final foreground = switch ((active, onPressed == null)) {
      (_, true) => palette.textTertiary.withValues(alpha: 0.38),
      (true, _) => palette.textPrimary,
      _ => palette.textTertiary,
    };
    return _FooterButtonSlot(
      child: CompactIconButton(
        extent: AppControlMetrics.footerButtonExtent,
        tooltip: tooltip,
        selected: active,
        foregroundColor: foreground,
        onPressed: onPressed,
        icon: busy
            ? SizedBox.square(
                key: progressKey,
                dimension: AppControlMetrics.footerIconAction,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: foreground,
                ),
              )
            : Icon(icon, size: AppControlMetrics.footerIconAction),
      ),
    );
  }
}

/// Gives every footer action the same trailing beat without enlarging its
/// painted hover surface. The final beat also keeps the strip off the readout.
class _FooterButtonSlot extends StatelessWidget {
  const _FooterButtonSlot({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(right: AppControlMetrics.footerButtonGap),
    child: child,
  );
}
