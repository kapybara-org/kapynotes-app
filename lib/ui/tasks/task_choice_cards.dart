import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/platform.dart';
import '../../core/theme.dart';
import '../../data/blob_store.dart';
import '../../data/task_board.dart';
import '../sidebar_timestamp.dart';
import 'task_choice.dart';
import 'task_marks.dart';
import 'task_details_sheet.dart';

/// The Tasks boards' colours (KAPY-62, row D), each the nearest of the
/// palette's own. In dark, the few the palette has no role for are steps off
/// the card, worked out from the neutral ladder's steps.
class TaskInk {
  const TaskInk._({
    required this.card,
    required this.raised,
    required this.lifted,
    required this.rowHover,
    required this.button,
    required this.chip,
    required this.text,
    required this.secondary,
    required this.quiet,
    required this.sage,
    required this.doneFill,
    required this.edge,
    required this.keyEdge,
    required this.hairline,
  });

  factory TaskInk.of(BuildContext context) {
    final palette = context.palette;
    if (palette.brightness == Brightness.dark) {
      final card = palette.cardBackground;
      final text = palette.textPrimary;
      Color step(Color toward, double amount) => Color(
        Color.alphaBlend(toward.withValues(alpha: amount), card).toARGB32(),
      );
      final contrast = palette.increasedContrast;
      return TaskInk._(
        card: card,
        raised: palette.selectedBackground,
        lifted: step(text, 0.06),
        rowHover: palette.hover,
        button: step(text, 0.07),
        chip: step(text, 0.0817),
        text: text,
        secondary: palette.textSecondary,
        quiet: palette.textTertiary,
        sage: palette.accentText,
        doneFill: step(palette.accentText, 0.16),
        edge: contrast ? palette.controlBorder : text.withAlpha(0x14),
        keyEdge: contrast ? palette.checkboxBorder : text.withAlpha(0x24),
        hairline: palette.separator,
      );
    }
    return TaskInk._(
      card: palette.wellBackground,
      raised: palette.cardBackground,
      lifted: palette.surfaceBackground,
      rowHover: palette.hover,
      button: palette.controlBackground,
      chip: palette.selectedBackground,
      text: palette.textPrimary,
      secondary: palette.textSecondary,
      quiet: palette.textTertiary,
      sage: palette.accentText,
      doneFill: palette.tonalBackground,
      edge: palette.controlBorder,
      keyEdge: palette.keycapBorder,
      hairline: palette.separator,
    );
  }

  final Color card;
  final Color raised;
  final Color lifted;
  final Color rowHover;
  final Color button;
  final Color chip;
  final Color text;
  final Color secondary;
  final Color quiet;
  final Color sage;
  final Color doneFill;
  final Color edge;
  final Color keyEdge;
  final Color hairline;
}

/// Increase contrast's 1 px outline for a Tasks control of [radius], drawn
/// over it so nothing moves. Null with Increase contrast off.
BoxDecoration? taskContrastEdge(BuildContext context, double radius) =>
    context.palette.increasedContrast
    ? BoxDecoration(
        border: Border.all(color: TaskInk.of(context).edge),
        borderRadius: BorderRadius.circular(radius),
      )
    : null;

TextStyle taskText(
  double size,
  double line,
  Color color, [
  double weight = 400,
]) => uiStyle(size, line, FontWeight.w400, color, axis: weight);

TextStyle _mono(Color color) => TextStyle(
  fontFamily: AppFonts.ui,
  fontFamilyFallback: AppFonts.uiFallback,
  fontSize: 11,
  height: 14 / 11,
  color: color,
);

const _connectors = {
  'a',
  'an',
  'and',
  'at',
  'before',
  'by',
  'for',
  'from',
  'in',
  'of',
  'on',
  'or',
  'that',
  'the',
  'to',
  'which',
  'with',
};

/// A task's first words, short enough for "Start with …": up to three, and
/// never ending on a little word such as "which" or "the".
String shortTaskName(String words) {
  final parts = words.trim().split(RegExp(r'\s+'));
  final kept = parts.take(3).toList();
  while (kept.length > 1 && _connectors.contains(kept.last.toLowerCase())) {
    kept.removeLast();
  }
  final short = kept.join(' ');
  return kept.length < parts.length ? '$short…' : short;
}

/// Whether [item] has sat untouched long enough to ask if it's still wanted.
bool taskIsStale(TaskItem item, DateTime now) =>
    !item.doNow &&
    now.millisecondsSinceEpoch - item.lastTouched >=
        TaskBoard.staleAfter.inMilliseconds;

/// The quiet line under a task on a card: its note, ↺ if it came back, and
/// when it was added if that matters.
class TaskCardMeta extends StatelessWidget {
  const TaskCardMeta({
    super.key,
    required this.item,
    required this.label,
    this.added,
    this.phone = false,
  });

  final TaskItem item;
  final String? label;
  final String? added;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final words = [?label, ?added].join(' · ');
    return Row(
      children: [
        if (label != null && !phone) ...[
          NoteSwatch(note: item.note, size: 8),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            words.isEmpty ? (phone ? 'No note' : '') : words,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: phone
                ? taskText(13, 18, ink.secondary)
                : taskText(12, 16, ink.secondary),
          ),
        ),
        if (item.entry.enteredAt != 0) ...[
          const SizedBox(width: 6),
          KapyIcon(KapyIcons.undoRounded, size: 14, color: ink.quiet),
        ],
      ],
    );
  }
}

/// The share of a row a note's name may take beside a task's words, so the
/// words always keep most of it.
const double taskMarkShare = 0.4;

/// The widest a note's name grows beside a task's words in a row [row] wide.
double taskMarkWidth(double row) => math.min(220, row * taskMarkShare);

/// How wide the pair must be for its two cards to sit side by side; a
/// narrower one stacks them.
const double _pairBesideWidth = 440;

/// How wide Do now must be for Not finished and Done to sit beside the task;
/// a narrower card puts them under it.
const double _doNowBesideWidth = 420;

/// "What do you want to work on next?": your choice so far against the next
/// task on the list. ← or a click keeps the left, → or a click takes the
/// right, and Start with (or esc) stops early.
class TaskPairCard extends StatelessWidget {
  const TaskPairCard({
    super.key,
    required this.pair,
    required this.now,
    required this.labelOf,
    required this.onKeep,
    required this.onTake,
    required this.onStart,
    this.justDone,
    this.phone = false,
  });

  final PairStage pair;
  final DateTime now;
  final String? Function(TaskItem item) labelOf;
  final VoidCallback onKeep;
  final VoidCallback onTake;
  final VoidCallback onStart;

  /// The task just finished, when the pair asks about tasks that joined
  /// since you chose.
  final TaskItem? justDone;
  final bool phone;

  String? _added(TaskItem item, {required bool joined}) {
    final at = DateTime.fromMillisecondsSinceEpoch(item.entry.addedAt);
    if (joined) return 'added ${SidebarTimestamp.clock(at)}';
    if (taskIsStale(item, now)) {
      return 'added ${SidebarTimestamp.shortDay(at, now: now)}';
    }
    return null;
  }

  String get _count => pair.pairsLeft == 1
      ? '1 more pair after this'
      : '${pair.pairsLeft} more pairs after this';

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final last = pair.pairsLeft == 0;
    final leftLabel = pair.chosen ? 'Your choice so far' : 'First on the list';
    final rightLabel = pair.joined ? 'New since you chose' : 'Next on the list';
    final left = _PairOption(
      key: const ValueKey('tasks-pair-left'),
      heading: leftLabel,
      item: pair.left,
      meta: TaskCardMeta(
        item: pair.left,
        label: labelOf(pair.left),
        added: _added(pair.left, joined: false),
        phone: phone,
      ),
      keyLabel: '←',
      action: pair.chosen ? 'Keep your choice' : 'Choose',
      onPressed: onKeep,
      phone: phone,
    );
    final right = _PairOption(
      key: const ValueKey('tasks-pair-right'),
      heading: rightLabel,
      item: pair.right,
      meta: TaskCardMeta(
        item: pair.right,
        label: labelOf(pair.right),
        added: _added(pair.right, joined: pair.joined),
        phone: phone,
      ),
      keyLabel: '→',
      action: pair.chosen ? 'Choose this instead' : 'Choose',
      onPressed: onTake,
      phone: phone,
    );
    final question = Semantics(
      header: true,
      child: Text(
        'What do you want to work on next?',
        style: phone
            ? taskText(15, 20, ink.text, 500)
            : taskText(15, 22, ink.text, 520),
      ),
    );
    final done = justDone;
    final start = last
        ? null
        : _StartButton(
            label: 'Start with ${shortTaskName(pair.left.words)}',
            semantics: 'Start with ${pair.left.words}',
            onPressed: onStart,
            phone: phone,
          );
    return Container(
      key: const ValueKey('tasks-pair'),
      padding: phone
          ? const EdgeInsets.fromLTRB(16, 14, 16, 16)
          : const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ink.card,
        borderRadius: BorderRadius.circular(phone ? 12 : 10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          if (done != null && done.doneAt != null)
            Row(
              key: const ValueKey('tasks-just-done'),
              children: [
                KapyIcon(
                  KapyIcons.checkCircleRounded,
                  size: 16,
                  color: ink.secondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${done.words} is done.',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: taskText(13, 18, ink.secondary),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  SidebarTimestamp.clock(done.doneAt!),
                  style: taskText(12, 16, ink.quiet).copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          if (phone || last)
            question
          else
            Row(
              children: [
                Expanded(child: question),
                const SizedBox(width: 8),
                Text(
                  _count,
                  style: taskText(12, 16, ink.quiet).copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              if (phone ||
                  constraints.maxWidth <
                      _pairBesideWidth *
                          MediaQuery.textScalerOf(context).scale(16) /
                          16) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [left, right],
                );
              }
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    Expanded(child: left),
                    Expanded(child: right),
                  ],
                ),
              );
            },
          ),
          if (phone) ...[
            Text(
              last
                  ? 'Tap the one you’d rather do. Your pick becomes Do now.'
                  : 'Tap the one you’d rather do. $_count.',
              style: taskText(13, 18, ink.quiet),
            ),
            ?(start == null
                ? null
                : Align(alignment: Alignment.centerLeft, child: start)),
          ] else
            Row(
              children: [
                Expanded(
                  child: Text(
                    last
                        ? 'Your pick becomes Do now. The other waits its turn.'
                        : 'The one you don’t pick waits its turn.',
                    style: taskText(12, 16, ink.quiet),
                  ),
                ),
                if (start != null) ...[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 320),
                    child: start,
                  ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _PairOption extends StatefulWidget {
  const _PairOption({
    super.key,
    required this.heading,
    required this.item,
    required this.meta,
    required this.keyLabel,
    required this.action,
    required this.onPressed,
    required this.phone,
  });

  final String heading;
  final TaskItem item;
  final Widget meta;
  final String keyLabel;
  final String action;
  final VoidCallback onPressed;
  final bool phone;

  @override
  State<_PairOption> createState() => _PairOptionState();
}

class _PairOptionState extends State<_PairOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final phone = widget.phone;
    final lit = _hovered && !phone;
    return Semantics(
      button: true,
      label: '${widget.heading}: ${widget.item.words}',
      hint: widget.action,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            constraints: BoxConstraints(minHeight: phone ? 44 : 0),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: phone || lit ? ink.lifted : ink.raised,
              border: phone
                  ? null
                  : Border.all(color: lit ? ink.sage : ink.edge),
              borderRadius: BorderRadius.circular(phone ? 10 : 8),
            ),
            foregroundDecoration: phone ? taskContrastEdge(context, 10) : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: phone ? 2 : 4,
              children: [
                Text(
                  widget.heading,
                  style: taskText(
                    12,
                    16,
                    phone ? ink.secondary : ink.quiet,
                    520,
                  ),
                ),
                Text(
                  widget.item.words,
                  maxLines: phone ? 3 : 2,
                  overflow: TextOverflow.ellipsis,
                  style: phone
                      ? taskText(16, 22, ink.text, 500)
                      : taskText(14, 20, ink.text, 500),
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: phone
                      ? widget.meta
                      : Row(
                          children: [
                            Expanded(child: widget.meta),
                            const SizedBox(width: 8),
                            TaskKey(widget.keyLabel),
                          ],
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

/// A key printed on a card, as the boards draw it.
class TaskKey extends StatelessWidget {
  const TaskKey(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    return ExcludeSemantics(
      child: Container(
        height: 20,
        constraints: const BoxConstraints(minWidth: 20),
        padding: const EdgeInsets.symmetric(horizontal: 5),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border.all(color: ink.keyEdge),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: _mono(ink.secondary)),
      ),
    );
  }
}

class _StartButton extends StatelessWidget {
  const _StartButton({
    required this.label,
    required this.semantics,
    required this.onPressed,
    required this.phone,
  });

  final String label;
  final String semantics;
  final VoidCallback onPressed;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    return TaskButton(
      key: const ValueKey('tasks-start'),
      semantics: semantics,
      onPressed: onPressed,
      fill: ink.lifted,
      outline: taskContrastEdge(context, phone ? 8 : 6),
      height: phone ? 44 : 32,
      innerHeight: phone ? 36 : 32,
      radius: phone ? 8 : 6,
      padding: phone ? 14 : 12,
      children: [
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: phone
                ? taskText(15, 20, ink.text, 500)
                : taskText(13, 18, ink.text, 460),
          ),
        ),
        if (!phone && AppPlatform.hasPointer) ...[
          const SizedBox(width: 8),
          ExcludeSemantics(child: Text('esc', style: _mono(ink.secondary))),
        ],
      ],
    );
  }
}

/// A plain filled button as the Tasks boards draw them.
class TaskButton extends StatelessWidget {
  const TaskButton({
    super.key,
    required this.semantics,
    required this.onPressed,
    required this.children,
    this.fill,
    this.outline,
    this.height = 32,
    double? innerHeight,
    this.radius = 6,
    this.padding = 10,
  }) : innerHeight = innerHeight ?? height;

  final String semantics;
  final VoidCallback onPressed;
  final List<Widget> children;
  final Color? fill;

  /// Drawn over the button, so it moves nothing.
  final Decoration? outline;

  /// The target's height; [innerHeight] is the drawn button's.
  final double height;
  final double innerHeight;
  final double radius;
  final double padding;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semantics,
    excludeSemantics: true,
    onTap: onPressed,
    child: MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: height),
          child: Center(
            widthFactor: 1,
            heightFactor: 1,
            child: Container(
              constraints: BoxConstraints(minHeight: innerHeight),
              padding: EdgeInsets.symmetric(horizontal: padding, vertical: 2),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(radius),
              ),
              foregroundDecoration: outline,
              child: Row(mainAxisSize: MainAxisSize.min, children: children),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Do now: the task, its note and the first line of its details with its
/// picture, then Not finished and Done ⌘↵. On a phone, Done comes first.
class TaskDoNowCard extends StatelessWidget {
  const TaskDoNowCard({
    super.key,
    required this.item,
    required this.label,
    required this.onOpen,
    required this.onNotFinished,
    required this.onDone,
    this.images,
    this.doneShortcut,
    this.phone = false,
  });

  final TaskItem item;
  final String? label;
  final VoidCallback onOpen;
  final VoidCallback onNotFinished;

  /// Null on a note shared to view only, where Done is not shown.
  final VoidCallback? onDone;
  final BlobStore? images;
  final String? doneShortcut;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final details = item.details;
    final label = this.label;
    final notFinished = TaskButton(
      key: const ValueKey('tasks-not-finished'),
      semantics: 'Not finished',
      onPressed: onNotFinished,
      fill: phone ? ink.lifted : null,
      height: phone ? 44 : 32,
      innerHeight: phone ? 36 : 32,
      radius: phone ? 8 : 6,
      padding: phone ? 14 : 10,
      children: [
        KapyIcon(
          KapyIcons.undoRounded,
          size: phone ? 16 : 14,
          color: phone ? ink.text : ink.secondary,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            'Not finished',
            style: phone
                ? taskText(15, 20, ink.text, 500)
                : taskText(13, 18, ink.secondary, 500),
          ),
        ),
      ],
    );
    final onDone = this.onDone;
    final done = onDone == null
        ? null
        : TaskButton(
            key: const ValueKey('tasks-done'),
            semantics: 'Done',
            onPressed: onDone,
            fill: phone ? ink.doneFill : ink.button,
            height: phone ? 44 : 32,
            innerHeight: phone ? 36 : 32,
            radius: phone ? 8 : 6,
            padding: phone ? 14 : 10,
            children: [
              KapyIcon(
                KapyIcons.checkRounded,
                size: phone ? 16 : 14,
                color: phone ? ink.sage : ink.text,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Done',
                  style: phone
                      ? taskText(15, 20, ink.sage, 500)
                      : taskText(13, 18, ink.text, 500),
                ),
              ),
              if (!phone && doneShortcut != null) ...[
                const SizedBox(width: 6),
                ExcludeSemantics(
                  child: Text(doneShortcut!, style: _mono(ink.quiet)),
                ),
              ],
            ],
          );
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          child: Text(
            'Do now',
            style: phone
                ? taskText(13, 18, ink.sage, 520)
                : taskText(12, 16, ink.sage, 520),
          ),
        ),
        SizedBox(height: phone ? 4 : 6),
        Semantics(
          button: true,
          hint: 'Opens its details',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onOpen,
            child: Text(
              item.words,
              style: phone
                  ? taskText(17, 22, ink.text, 500)
                  : taskText(15, 20, ink.text, 500),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              if (label != null && !phone) ...[
                NoteSwatch(note: item.note, size: 8),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label ?? (phone ? 'No note' : ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: phone
                      ? taskText(13, 16, ink.quiet)
                      : taskText(12, 16, ink.quiet),
                ),
              ),
            ],
          ),
        ),
        if (details != null)
          Padding(
            padding: EdgeInsets.only(top: phone ? 12 : 10),
            child: Row(
              children: [
                TaskDetailPicture(
                  item: item,
                  details: details,
                  images: images,
                  size: 36,
                ),
                if (details.hasPicture) const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    details.preview.trim(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: phone
                        ? taskText(13, 18, ink.secondary)
                        : taskText(12, 16, ink.secondary),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    return Container(
      key: const ValueKey('tasks-do-now'),
      padding: phone
          ? const EdgeInsets.all(16)
          : const EdgeInsets.fromLTRB(16, 14, 14, 14),
      decoration: BoxDecoration(
        color: ink.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: phone
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                body,
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [?done, notFinished]),
              ],
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth >=
                    _doNowBesideWidth *
                        MediaQuery.textScalerOf(context).scale(16) /
                        16) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(child: body),
                      const SizedBox(width: 16),
                      notFinished,
                      if (done != null) ...[const SizedBox(width: 6), done],
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: [
                    body,
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        alignment: WrapAlignment.end,
                        children: [notFinished, ?done],
                      ),
                    ),
                  ],
                );
              },
            ),
    );
  }
}

/// The evening: "Done for today.", the tasks left in the order they wait for
/// tomorrow, and Keep going.
class TaskEveningCard extends StatelessWidget {
  const TaskEveningCard({
    super.key,
    required this.finished,
    required this.left,
    required this.onKeepGoing,
    this.phone = false,
  });

  final int finished;

  /// The rows of the tasks left, built by the page.
  final List<Widget> left;
  final VoidCallback onKeepGoing;
  final bool phone;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final count = left.length;
    final rest = count == 1
        ? 'The 1 left waits here for tomorrow.'
        : 'The $count left wait here for tomorrow, in this order.';
    return Container(
      key: const ValueKey('tasks-evening'),
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
      decoration: BoxDecoration(
        color: ink.card,
        borderRadius: BorderRadius.circular(phone ? 12 : 10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              KapyIcon(KapyIcons.sunsetRounded, size: 16, color: ink.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Done for today.',
                    style: taskText(15, 22, ink.text, 520),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '$finished finished. $rest',
            style: taskText(13, 18, ink.secondary),
          ),
          const SizedBox(height: 10),
          ...left,
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: TaskButton(
              key: const ValueKey('tasks-keep-going'),
              semantics: 'Keep going',
              onPressed: onKeepGoing,
              fill: ink.raised,
              height: phone ? 44 : 32,
              innerHeight: phone ? 36 : 32,
              padding: 12,
              children: [
                Text(
                  'Keep going',
                  style: phone
                      ? taskText(15, 20, ink.text, 500)
                      : taskText(13, 18, ink.text, 460),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "5 finished today" and their names, under the evening card; opens Done.
class TaskFinishedLine extends StatelessWidget {
  const TaskFinishedLine({
    super.key,
    required this.finished,
    required this.onPressed,
  });

  final List<TaskItem> finished;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final ink = TaskInk.of(context);
    final title = '${finished.length} finished today';
    return Semantics(
      button: true,
      label: title,
      hint: 'Opens Done',
      excludeSemantics: true,
      onTap: onPressed,
      child: InkWell(
        key: const ValueKey('tasks-finished-today'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        hoverColor: ink.rowHover,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              KapyIcon(KapyIcons.checkRounded, size: 16, color: ink.quiet),
              const SizedBox(width: 10),
              Text(title, style: taskText(13, 18, ink.secondary, 460)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  [for (final item in finished) item.words].join(', '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: taskText(12, 16, ink.quiet),
                ),
              ),
              const SizedBox(width: 10),
              KapyIcon(
                KapyIcons.chevronRightRounded,
                size: 14,
                color: ink.quiet,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
