import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/folders.dart';
import '../../sync/presence.dart';
import '../checklist_pie.dart';
import '../collaborator_colors.dart';
import '../sidebar_timestamp.dart';
import 'note_footer.dart' show typingStatusText;

/// The note title's hand-drawn underline, under its last word: Paper's clay
/// stroke, a little longer than the word and rising slightly into it.
class NoteTitleUnderline extends StatelessWidget {
  const NoteTitleUnderline({super.key, required this.word});

  /// The last word of the title, in the coordinates this is laid out in.
  final Rect word;

  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('note-title-underline'),
    painter: _UnderlinePainter(word, context.palette.clay),
  );
}

class _UnderlinePainter extends CustomPainter {
  _UnderlinePainter(this.word, this.color);

  final Rect word;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = word.height / 48;
    final path = Path()
      ..moveTo(word.left - 2.9 * scale, word.top + 47.1 * scale)
      ..quadraticBezierTo(
        word.center.dx,
        word.top + 46.8 * scale,
        word.right + 2.9 * scale,
        word.top + 49.5 * scale,
      );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.6 * scale
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_UnderlinePainter old) =>
      old.word != word || old.color != color;
}

/// What Saved says, for the date line to carry while the page is too narrow
/// to show it in its bar.
class DateLineSaved extends InheritedWidget {
  const DateLineSaved({super.key, required this.saved, required super.child});

  /// Null while the bar has room for Saved itself.
  final ({String label, String? tooltip})? saved;

  static ({String label, String? tooltip})? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DateLineSaved>()?.saved;

  @override
  bool updateShouldNotify(DateLineSaved oldWidget) => saved != oldWidget.saved;
}

/// The folders the notes on the page are filed in, for the line above each
/// note's title while the page's days have the bar's top left.
class NoteFolders extends InheritedWidget {
  const NoteFolders({
    super.key,
    required this.tree,
    this.onOpenFolder,
    required super.child,
  });

  final FolderTree tree;

  /// Shows a folder from the line in this tab, or with behind in a new tab
  /// behind it. Null on a phone, which has no folder to show it on, so the
  /// line only says where the note is.
  final void Function(String folderId, {required bool behind})? onOpenFolder;

  static NoteFolders? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NoteFolders>();

  @override
  bool updateShouldNotify(NoteFolders oldWidget) =>
      tree != oldWidget.tree || onOpenFolder != oldWidget.onOpenFolder;
}

/// The row under a note's title: when it was edited, how far its checklist
/// has got, its running total, and who else is in it or why it cannot be
/// changed. On the desktop it is Sanjay's date-and-time line, "Wed 19 Nov ·
/// 8:55 · 0 of 1 done" then the tags; a phone keeps "Edited today, 8:55"
/// with the day as a pill.
class NoteMetaRow extends StatelessWidget {
  const NoteMetaRow({
    super.key,
    required this.edited,
    required this.today,
    this.day,
    this.done = 0,
    this.tasks = 0,
    this.total,
    this.describeTotal,
    this.typing = const [],
    this.readOnlyLabel,
    this.readOnlyIcon,
    this.onReadOnlyPressed,
    this.tags,
    this.addTag,
    this.phone = false,
    this.width = double.infinity,
  });

  /// When the note was last edited, or on a phone when it was written, and
  /// today, both on the reader's clock.
  final DateTime edited;
  final DateTime today;

  /// The day the note was given, where it has one, so the line reads "Fri 21
  /// Nov · 9:41" rather than the day it was last edited.
  final DateTime? day;

  /// Ticked boxes out of every box in the note. No boxes, no progress.
  final int done;
  final int tasks;

  final String? total;

  /// Writes what the total counted and how, for the hover on it; called only
  /// once someone hovers, since the note is read on every keystroke.
  final String Function()? describeTotal;
  final List<Collaborator> typing;

  /// Set only when the note cannot be changed: what that is called here.
  final String? readOnlyLabel;
  final KapyIconData? readOnlyIcon;
  final VoidCallback? onReadOnlyPressed;

  /// The note's tag chips, at the end of the line.
  final Widget? tags;

  /// + Tag, after the chips: on a desktop's line, the first to step aside.
  final Widget? addTag;

  /// On a phone's note page (M07): the facts and tags share one line that
  /// wraps, where a tablet keeps the tags on a line of their own.
  final bool phone;

  /// How wide the writing column is, which a desktop's line keeps to.
  final double width;

  static const double _gap = 10;

  /// A phone's line under the title: the note's day and the time it was
  /// written, "Fri 21 · 9:41", or the time alone today. A note given a day
  /// other than the one it was written on says the day alone, since the time
  /// belongs to another day.
  String _phoneLine() {
    final written = DateTime(edited.year, edited.month, edited.day);
    final shown = day ?? written;
    final clock = SidebarTimestamp.clock(edited);
    if (shown != written) return SidebarTimestamp.weekdayAndDay(shown);
    return shown == DateTime(today.year, today.month, today.day)
        ? clock
        : '${SidebarTimestamp.weekdayAndDay(shown)} · $clock';
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final quiet = TextStyle(
      fontFamily: AppFonts.ui,
      fontFamilyFallback: AppFonts.uiFallback,
      fontSize: 13,
      height: 16 / 13,
      fontWeight: AppWeight.font(AppWeight.body),
      fontVariations: AppWeight.wght(AppWeight.body),
      color: palette.textTertiary,
    );
    final strong = quiet.copyWith(
      fontWeight: AppWeight.font(AppWeight.rowTitle),
      fontVariations: AppWeight.wght(AppWeight.rowTitle),
      color: palette.textSecondary,
    );
    final mobile = AppPlatform.isMobile;
    final dot = Text('·', style: quiet.copyWith(color: palette.textDivider));
    final typingText = typingStatusText([for (final p in typing) p.name]);
    final progress = '$done of $tasks done';
    final saved = DateLineSaved.of(context);
    final savedLabel = saved == null
        ? null
        : Text(saved.label, key: const ValueKey('note-saved'), style: quiet);
    final items = <Widget>[
      if (!mobile)
        Text(
          '${SidebarTimestamp.shortDay(day ?? edited, now: today)} · '
          '${SidebarTimestamp.clock(edited)}',
          key: const ValueKey('note-edited'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: quiet.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        )
      else if (phone)
        Text(
          _phoneLine(),
          key: const ValueKey('note-edited'),
          style: quiet.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        )
      else if (day case final day?)
        Container(
          key: const ValueKey('note-day-pill'),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: palette.tonalBackground,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            SidebarTimestamp.weekdayAndDay(day),
            maxLines: 1,
            style: strong.copyWith(
              color: palette.tonalForeground,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      if (mobile && !phone)
        Text(
          SidebarTimestamp.edited(
            edited,
            now: today,
            displayTime: (time) => time,
          ),
          key: const ValueKey('note-edited'),
          style: quiet,
        ),
      if (savedLabel != null)
        switch (saved?.tooltip) {
          final tooltip? => Tooltip(message: tooltip, child: savedLabel),
          null => savedLabel,
        },
      if (tasks > 0 && !mobile)
        Text(progress, key: const ValueKey('note-progress'), style: quiet)
      else if (tasks > 0)
        Semantics(
          label: progress,
          excludeSemantics: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ChecklistPie(
                key: const ValueKey('note-progress'),
                done: done,
                total: tasks,
                fill: Theme.of(context).colorScheme.primary,
                check: palette.paperColor,
              ),
              const SizedBox(width: 6),
              Text(progress, style: strong),
            ],
          ),
        ),
      if (total case final total?)
        _TotalHover(
          describe: describeTotal,
          child: Text.rich(
            key: const ValueKey('note-total'),
            TextSpan(
              text: 'Total: ',
              children: [TextSpan(text: total, style: strong)],
            ),
            style: quiet,
          ),
        ),
      if (typingText != null)
        Semantics(
          liveRegion: true,
          label: typingText,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final person in typing.take(3)) ...[
                Container(
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
                const SizedBox(width: 3),
              ],
              const SizedBox(width: 3),
              Text(
                typingText,
                key: const ValueKey('typing-presence'),
                style: quiet,
              ),
            ],
          ),
        ),
      if (readOnlyLabel case final label?)
        _ReadOnly(
          label: label,
          icon: readOnlyIcon,
          style: strong,
          onPressed: onReadOnlyPressed,
        ),
    ];
    if (phone) {
      // One line, as M07 draws it: the facts a dot apart, then the tags after
      // a gap. It wraps when they don't fit, and the editor makes room for
      // as many lines as it takes, so a wrap never runs into the note.
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: _gap + 4,
        children: [
          Wrap(
            key: const ValueKey('note-facts'),
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final (index, item) in items.indexed)
                index == 0
                    ? item
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(width: _gap),
                          dot,
                          const SizedBox(width: _gap),
                          item,
                        ],
                      ),
            ],
          ),
          ?tags,
        ],
      );
    }
    if (AppPlatform.isMobile) {
      // Grows with the text size and the tags' 44 pt targets rather than
      // clipping them to a fixed row.
      return ConstrainedBox(
        constraints: BoxConstraints(minHeight: EditorMetrics.metaRow),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 16),
              child: Wrap(
                key: const ValueKey('note-facts'),
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (final (index, item) in items.indexed)
                    index == 0
                        ? item
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(width: _gap),
                              dot,
                              const SizedBox(width: _gap),
                              item,
                            ],
                          ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            // The tags' own targets are 44 pt tall on a phone, so the row
            // gives them the room rather than clipping them to the pill.
            SizedBox(
              height: AppPlatform.hasPointer ? 22 : 44,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (tags case final tags?) Flexible(child: tags),
                  ?addTag,
                ],
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: EditorMetrics.metaRow,
      child: _MetaLine(
        width: width,
        children: [
          for (final (index, item) in items.indexed)
            index == 0
                ? item
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text('·', style: quiet),
                      ),
                      item,
                    ],
                  ),
          if (tags case final tags?)
            Padding(padding: const EdgeInsets.only(left: 6), child: tags),
          ?addTag,
        ],
      ),
    );
  }
}

/// A desktop's meta line: the facts in order, then the tags, then + Tag, each
/// whole. Where the column ends before one does, it and everything after it
/// step aside, as the bar's items do, rather than run into the pane's edge.
/// Only the date, first, shortens to fit a column too narrow even for it.
class _MetaLine extends MultiChildRenderObjectWidget {
  const _MetaLine({required this.width, required super.children});

  final double width;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMetaLine(width);

  @override
  void updateRenderObject(BuildContext context, _RenderMetaLine renderObject) =>
      renderObject.width = width;
}

class _MetaLineData extends ContainerBoxParentData<RenderBox> {
  bool shown = false;
}

class _RenderMetaLine extends RenderBox
    with ContainerRenderObjectMixin<RenderBox, _MetaLineData> {
  _RenderMetaLine(this._width);

  /// How far one already showing may reach past a column that holds still
  /// before it steps aside: a tag's × as the pointer rests on its chip, so the
  /// chip never leaves from under the pointer. A column that changes gives
  /// none, so each width shows the same items however it was reached.
  static const double _grace = 15;

  double? _column;

  double get width => _width;
  double _width;
  set width(double value) {
    if (value == _width) return;
    _width = value;
    markNeedsLayout();
  }

  Iterable<RenderBox> get _shown sync* {
    for (var child = firstChild; child != null; child = childAfter(child)) {
      if ((child.parentData! as _MetaLineData).shown) yield child;
    }
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _MetaLineData) child.parentData = _MetaLineData();
  }

  @override
  void performLayout() {
    final column = math.min(width, constraints.maxWidth);
    final grace = column == _column ? _grace : 0.0;
    _column = column;
    final height = constraints.maxHeight;
    var x = 0.0;
    var fits = true;
    for (var child = firstChild; child != null; child = childAfter(child)) {
      child.layout(
        BoxConstraints(
          maxWidth: child == firstChild ? column : double.infinity,
          maxHeight: height,
        ),
        parentUsesSize: true,
      );
      final data = child.parentData! as _MetaLineData;
      final reach = x + child.size.width - column;
      fits = fits && reach <= (data.shown ? grace : 0);
      data
        ..shown = fits
        ..offset = Offset(x, (height - child.size.height) / 2);
      if (fits) x += child.size.width;
    }
    size = constraints.constrain(Size(x, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in _shown) {
      context.paintChild(
        child,
        (child.parentData! as _MetaLineData).offset + offset,
      );
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in _shown) {
      if (result.addWithPaintOffset(
        offset: (child.parentData! as _MetaLineData).offset,
        position: position,
        hitTest: (result, position) =>
            child.hitTest(result, position: position),
      )) {
        return true;
      }
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) =>
      _shown.forEach(visitor);
}

class _ReadOnly extends StatelessWidget {
  const _ReadOnly({
    required this.label,
    required this.icon,
    required this.style,
    required this.onPressed,
  });

  final String label;
  final KapyIconData? icon;
  final TextStyle style;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon case final icon?) ...[
          KapyIcon(icon, size: 13, color: style.color),
          const SizedBox(width: 4),
        ],
        Text(label, key: const ValueKey('view-only-status'), style: style),
      ],
    );
    return Semantics(
      button: onPressed != null,
      child: onPressed == null
          ? content
          : MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(onTap: onPressed, child: content),
            ),
    );
  }
}

/// A tooltip whose text is worked out when the pointer arrives or touches,
/// which is before a long press has lasted long enough to show it, and not on
/// every rebuild. A [Tooltip] with no message has no gestures at all, so until
/// then it says what it is on.
class _TotalHover extends StatefulWidget {
  const _TotalHover({required this.describe, required this.child});

  final String Function()? describe;
  final Widget child;

  @override
  State<_TotalHover> createState() => _TotalHoverState();
}

class _TotalHoverState extends State<_TotalHover> {
  String? _detail;

  @override
  void didUpdateWidget(_TotalHover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.describe != oldWidget.describe && _detail != null) {
      _detail = widget.describe?.call();
    }
  }

  void _describe() {
    if (_detail != null) return;
    setState(() => _detail = widget.describe?.call());
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _describe(),
    child: MouseRegion(
      onEnter: (_) => _describe(),
      onExit: (_) => _detail = null,
      child: Tooltip(message: _detail ?? 'Total', child: widget.child),
    ),
  );
}
