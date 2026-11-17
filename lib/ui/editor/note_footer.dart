import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../data/shortcut_prefs.dart';
import '../../sync/presence.dart';
import '../collaborator_colors.dart';
import '../compact_icon_button.dart';
import '../glass_surface.dart';
import '../mobile_page_swipe.dart';
import 'editor_formatting.dart';
import 'markdown_editing.dart';
import 'markdown_syntax.dart';

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
    this.typing = const [],
    this.readOnly = false,
    this.readOnlyLabel = 'View only',
    this.readOnlyIcon = Icons.visibility_outlined,
    this.onReadOnlyPressed,
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
    this.onInsertMenuPressed,
    required this.onIndentPressed,
    required this.onOutdentPressed,
    required this.showIndentControls,
    required this.canIndent,
    required this.canOutdent,
    this.onAddTableRowPressed,
    this.onRemoveTableRowPressed,
    this.onAddTableColumnPressed,
    this.onRemoveTableColumnPressed,
    this.onCycleTableAlignmentPressed,
    this.tableAlignment,
    this.tableTapGroup,
    required this.boldActive,
    required this.italicActive,
    required this.bulletsActive,
    required this.checklistActive,
    required this.paragraphStyle,
    this.markdown = false,
    this.markdownHeadingLevel,
    this.onDismissKeyboardPressed,
  });

  /// Whoever else is typing in the note, by name. Their caret's colour marks
  /// the line, so the words in the footer and the flag in the text read as
  /// the same person.
  final List<Collaborator> typing;
  final bool readOnly;

  /// What [readOnly] is called here: View only for the sharing role, or the
  /// note limit's own words. [onReadOnlyPressed], when set, explains it.
  final String readOnlyLabel;
  final IconData readOnlyIcon;
  final VoidCallback? onReadOnlyPressed;
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

  /// The one doorway to every insert command.
  final VoidCallback? onInsertMenuPressed;

  /// Nesting only appears once the caret is on a list line. The row shares its
  /// width with the total readout, and on a narrow phone two permanent extra
  /// buttons would crowd it for the sake of controls that would do nothing.
  final VoidCallback onIndentPressed;
  final VoidCallback onOutdentPressed;
  final bool showIndentControls;
  final bool canIndent;
  final bool canOutdent;

  /// Present only while a cell is being edited on a phone. The ordinary text
  /// controls stay where they are; these join the same horizontal scroller so
  /// a narrow screen never compresses either group into untappable slivers.
  final VoidCallback? onAddTableRowPressed;
  final VoidCallback? onRemoveTableRowPressed;
  final VoidCallback? onAddTableColumnPressed;
  final VoidCallback? onRemoveTableColumnPressed;
  final VoidCallback? onCycleTableAlignmentPressed;
  final MarkdownCellAlign? tableAlignment;

  /// The tap group of the open table cell. A press on the table controls is
  /// part of editing that cell, not a press somewhere else that finishes it —
  /// without this, the first tap on "insert row" closed the cell instead.
  final Object? tableTapGroup;
  final bool boldActive;
  final bool italicActive;
  final bool bulletsActive;
  final bool checklistActive;
  final NoteParagraphStyle? paragraphStyle;

  /// Whether the note is written in markdown, where the style control steps
  /// through heading levels instead of [paragraphStyle].
  final bool markdown;

  /// The markdown heading level under the caret: 0 for body text, null when
  /// the selected lines differ. Read only when [markdown] is true.
  final int? markdownHeadingLevel;

  /// Present only on a phone while its software keyboard is visible. Kept
  /// outside the formatting scroller so expanding or dragging the tools can
  /// never move the escape hatch away from the footer's right edge.
  final VoidCallback? onDismissKeyboardPressed;

  static double get height => AppControlMetrics.footerHeight;

  /// Gap between the bar's edge and the control nearest it.
  ///
  /// The two sides differ by design. An icon button paints a hover surface
  /// wider than its glyph, so its optical edge already sits inside its box; a
  /// text run has no such padding and needs the margin spelled out to look
  /// equally inset.
  static const double _edgeInset = 8;
  static const double _textEdgeInset = 10;

  /// Between the controls and the readout at the other end. They are
  /// different in kind — one changes the note, the other only reports on it —
  /// and butted together they would read as one row of controls.
  static const double _groupGap = 14;

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
  }) {
    if (available <= 0) return 0;
    if (available >= rowWidth) return available;
    final extent = AppControlMetrics.footerButtonSlotExtent;
    if (extent <= 0 || available <= extent) return available;
    return (available / extent).floor() * extent;
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final typingText = typingStatusText([
      for (final person in typing) person.name,
    ]);
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
                // The controls start at the left edge and grow rightward, which is
                // the whole point of not centring them: the nesting buttons appear
                // the moment the caret lands on a list line, and a centred row that
                // grows from five squares to seven slides everything already in it
                // sideways by a full button — 44pt under a thumb. Tap Bullets and
                // Bold would leave from under the finger that just pressed it.
                // The formatting revealer plus its five tools, and the insert
                // buttons when there is somewhere to put their attachments.
                final insertButtonCount =
                    readOnly || onInsertMenuPressed == null ? 0 : 1;
                final showTableControls = onAddTableRowPressed != null;
                final buttonCount = readOnly
                    ? 0
                    : 6 +
                          insertButtonCount +
                          (showIndentControls ? 2 : 0) +
                          (showTableControls ? 5 : 0);
                final rowWidth =
                    buttonCount * AppControlMetrics.footerButtonSlotExtent;
                final dismissKeyboard = onDismissKeyboardPressed;
                final dismissSlot = dismissKeyboard == null
                    ? 0.0
                    : AppControlMetrics.footerButtonSlotExtent + _edgeInset;
                final fixed =
                    _edgeInset +
                    rowWidth +
                    _groupGap +
                    _textEdgeInset +
                    dismissSlot;
                // Whatever is genuinely left over, up to a readable maximum. The
                // floor is what makes the controls scroll instead of the readout
                // shrinking to nothing on a narrow phone with nesting showing.
                final readoutSlot = typingText == null && !readOnly
                    ? 0.0
                    : (constraints.maxWidth - fixed).clamp(112.0, 220.0);

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
                                  _textEdgeInset -
                                  dismissSlot,
                            ),
                            rowWidth,
                            leadingButtonCount: insertButtonCount,
                          ),
                        ),
                        // Scrolls only when it cannot fit, which a narrow phone with
                        // the nesting controls showing still cannot. Left-anchored,
                        // so what is on screen stays where it was.
                        child: SingleChildScrollView(
                          key: const ValueKey('note-formatting-scroll'),
                          scrollDirection: Axis.horizontal,
                          physics: const ClampingScrollPhysics(),
                          child: ExcludeFocus(
                            child: Row(
                              key: const ValueKey('note-formatting-controls'),
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (onInsertMenuPressed != null)
                                  _FormatButton(
                                    key: const ValueKey('insert-menu'),
                                    label: '/',
                                    tooltip: 'Insert',
                                    active: false,
                                    onPressed: onInsertMenuPressed,
                                  ),
                                _ExpandableFormattingControls(
                                  paragraphStyle: paragraphStyle,
                                  markdown: markdown,
                                  markdownHeadingLevel: markdownHeadingLevel,
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
                                if (showTableControls) ...[
                                  TapRegion(
                                    groupId: tableTapGroup,
                                    // A tap must not take focus from the cell,
                                    // or the keyboard goes down with it.
                                    child: ExcludeFocus(
                                      child: _TableFooterControls(
                                        onAddRow: onAddTableRowPressed!,
                                        onRemoveRow: onRemoveTableRowPressed,
                                        onAddColumn: onAddTableColumnPressed!,
                                        onRemoveColumn:
                                            onRemoveTableColumnPressed,
                                        onCycleAlignment:
                                            onCycleTableAlignmentPressed!,
                                        alignment:
                                            tableAlignment ??
                                            MarkdownCellAlign.start,
                                      ),
                                    ),
                                  ),
                                ],
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
                              for (final person in typing.take(3))
                                Padding(
                                  padding: const EdgeInsets.only(right: 3),
                                  child: Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: collaboratorColor(
                                        person.userId,
                                        on: palette.brightness,
                                      ),
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  typingText,
                                  key: const ValueKey('typing-presence'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.right,
                                  style: TextStyle(
                                    fontSize: AppTypeScale.caption,
                                    fontWeight: FontWeight.w400,
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
                        child: _ReadOnlyStatus(
                          label: readOnlyLabel,
                          icon: readOnlyIcon,
                          onPressed: onReadOnlyPressed,
                        ),
                      ),
                      SizedBox(width: _textEdgeInset),
                    ],
                    if (dismissKeyboard != null) ...[
                      ExcludeFocus(
                        child: _FormatButton(
                          key: const ValueKey('dismiss-keyboard'),
                          icon: KapyIcons.chevronDownRounded,
                          tooltip: 'Hide keyboard',
                          active: false,
                          onPressed: dismissKeyboard,
                        ),
                      ),
                      SizedBox(width: _edgeInset),
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
class _TableFooterControls extends StatelessWidget {
  const _TableFooterControls({
    required this.onAddRow,
    required this.onRemoveRow,
    required this.onAddColumn,
    required this.onRemoveColumn,
    required this.onCycleAlignment,
    required this.alignment,
  });

  final VoidCallback onAddRow;
  final VoidCallback? onRemoveRow;
  final VoidCallback onAddColumn;
  final VoidCallback? onRemoveColumn;
  final VoidCallback onCycleAlignment;
  final MarkdownCellAlign alignment;

  KapyIconData get _alignmentIcon => switch (alignment) {
    MarkdownCellAlign.start => KapyIcons.alignLeft,
    MarkdownCellAlign.center => KapyIcons.alignCenter,
    MarkdownCellAlign.end => KapyIcons.alignRight,
  };

  String get _alignmentTooltip => switch (alignment) {
    MarkdownCellAlign.start => 'Column aligned left; change to center',
    MarkdownCellAlign.center => 'Column centered; change to right',
    MarkdownCellAlign.end => 'Column aligned right; change to left',
  };

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _FormatButton(
        key: const ValueKey('footer-table-add-row'),
        icon: KapyIcons.tableRowBelow,
        tooltip: 'Insert row below',
        active: false,
        onPressed: onAddRow,
      ),
      _FormatButton(
        key: const ValueKey('footer-table-add-column'),
        icon: KapyIcons.tableColumnRight,
        tooltip: 'Insert column right',
        active: false,
        onPressed: onAddColumn,
      ),
      _FormatButton(
        key: const ValueKey('footer-table-align-column'),
        icon: _alignmentIcon,
        tooltip: _alignmentTooltip,
        active: alignment != MarkdownCellAlign.start,
        onPressed: onCycleAlignment,
      ),
      _FormatButton(
        key: const ValueKey('footer-table-remove-row'),
        icon: KapyIcons.tableDeleteRow,
        tooltip: 'Delete row',
        active: false,
        onPressed: onRemoveRow,
      ),
      _FormatButton(
        key: const ValueKey('footer-table-remove-column'),
        icon: KapyIcons.tableDeleteColumn,
        tooltip: 'Delete column',
        active: false,
        onPressed: onRemoveColumn,
      ),
    ],
  );
}

/// The leading button is an explicit toggle on every platform. Once opened,
/// the tools stay put while the pointer returns to the note, matching the
/// dependable tap-to-open behavior on touch devices.
class _ExpandableFormattingControls extends StatefulWidget {
  const _ExpandableFormattingControls({
    required this.paragraphStyle,
    required this.markdown,
    required this.markdownHeadingLevel,
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
  final bool markdown;
  final int? markdownHeadingLevel;
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

  bool get _styled => markdown
      ? (markdownHeadingLevel ?? 0) > 0
      : paragraphStyle != null && paragraphStyle != NoteParagraphStyle.text;

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
        widget._styled;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _FormatButton(
          key: const ValueKey('formatting-toggle'),
          icon: KapyIcons.textFormatRounded,
          tooltip: _expanded
              ? 'Hide formatting tools'
              : 'Show formatting tools',
          active: anyActive || _expanded,
          onPressed: () => _setExpanded(!_expanded),
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
                    markdown: widget.markdown,
                    markdownHeadingLevel: widget.markdownHeadingLevel,
                    shortcut: widget.paragraphStyleShortcut,
                    onPressed: widget.onParagraphStylePressed,
                  ),
                  _FormatButton(
                    key: const ValueKey('format-checklist'),
                    icon: KapyIcons.checklistRounded,
                    tooltip: _withShortcut(
                      'Checklist',
                      widget.checklistShortcut,
                    ),
                    active: widget.checklistActive,
                    onPressed: widget.onChecklistPressed,
                  ),
                  _FormatButton(
                    key: const ValueKey('format-bullets'),
                    icon: KapyIcons.bulletedListRounded,
                    tooltip: _withShortcut(
                      'Bulleted list',
                      widget.bulletsShortcut,
                    ),
                    active: widget.bulletsActive,
                    onPressed: widget.onBulletsPressed,
                  ),
                  _FormatButton(
                    key: const ValueKey('format-bold'),
                    icon: KapyIcons.formatBoldRounded,
                    tooltip: _withShortcut('Bold', widget.boldShortcut),
                    active: widget.boldActive,
                    onPressed: widget.onBoldPressed,
                  ),
                  _FormatButton(
                    key: const ValueKey('format-italic'),
                    icon: KapyIcons.formatItalicRounded,
                    tooltip: _withShortcut('Italic', widget.italicShortcut),
                    active: widget.italicActive,
                    onPressed: widget.onItalicPressed,
                  ),
                  if (widget.showIndentControls) ...[
                    _FormatButton(
                      key: const ValueKey('format-outdent'),
                      icon: KapyIcons.indentDecreaseRounded,
                      tooltip: 'Move out \u00b7 Shift + Tab',
                      active: false,
                      onPressed: widget.canOutdent
                          ? widget.onOutdentPressed
                          : null,
                    ),
                    _FormatButton(
                      key: const ValueKey('format-indent'),
                      icon: KapyIcons.indentIncreaseRounded,
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
    );
  }
}

class _StyleCycleButton extends StatelessWidget {
  const _StyleCycleButton({
    super.key,
    required this.style,
    required this.markdown,
    required this.markdownHeadingLevel,
    required this.shortcut,
    required this.onPressed,
  });

  final NoteParagraphStyle? style;
  final bool markdown;
  final int? markdownHeadingLevel;
  final ShortcutBinding? shortcut;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final active = markdown
        ? (markdownHeadingLevel ?? 0) > 0
        : style != null && style != NoteParagraphStyle.text;
    final label = markdown
        ? markdownHeadingShortLabel(markdownHeadingLevel)
        : switch (style) {
            NoteParagraphStyle.heading => 'H',
            NoteParagraphStyle.subtitle => 'S',
            _ => 'Aa',
          };
    final name = markdown
        ? markdownHeadingLabel(markdownHeadingLevel)
        : style?.label ?? 'Mixed';
    return _FooterButtonSlot(
      child: CompactIconButton(
        extent: AppControlMetrics.footerButtonExtent,
        tooltip: _withShortcut('Text style: $name', shortcut),
        selected: active,
        foregroundColor: active ? palette.textPrimary : palette.textTertiary,
        onPressed: onPressed,
        icon: Text(
          label,
          style: TextStyle(
            fontSize: AppTypeScale.caption,
            fontWeight: FontWeight.w400,
            fontStyle: !markdown && style == NoteParagraphStyle.subtitle
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
    this.icon,
    this.label,
    required this.tooltip,
    required this.active,
    required this.onPressed,
  }) : assert((icon == null) != (label == null));

  final KapyIconData? icon;
  final String? label;
  final String tooltip;
  final bool active;

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
        icon: icon != null
            ? KapyIcon(icon!, size: AppControlMetrics.footerIconAction)
            : Text(
                label!,
                style: TextStyle(
                  color: foreground,
                  fontSize: AppControlMetrics.footerIconAction,
                  fontWeight: FontWeight.w500,
                  height: 1,
                ),
              ),
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

/// The quiet word in the footer's readout slot while a note cannot be
/// changed, and the way to find out why when there is something to explain.
class _ReadOnlyStatus extends StatelessWidget {
  const _ReadOnlyStatus({
    required this.label,
    required this.icon,
    this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final status = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Icon(
          icon,
          size: AppControlMetrics.iconAction,
          color: palette.textTertiary,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            key: const ValueKey('view-only-status'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTypeScale.caption,
              fontWeight: FontWeight.w500,
              color: palette.textSecondary,
            ),
          ),
        ),
      ],
    );
    final pressed = onPressed;
    if (pressed == null) return status;
    return Semantics(
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: pressed,
          child: status,
        ),
      ),
    );
  }
}
