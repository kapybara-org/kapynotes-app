import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/theme.dart';
import 'compact_icon_button.dart';
import 'control_surface.dart';
import 'settings_rows.dart';

/// One setting a search can find: what it is called, what else somebody
/// might call it, where it lives, and what it is set to.
///
/// [S] is whatever settings names its categories with; the search itself only
/// ever reads the words.
@immutable
class SettingsSearchEntry<S> {
  const SettingsSearchEntry({
    required this.section,
    required this.sectionLabel,
    required this.title,
    required this.icon,
    this.target,
    this.group,
    this.keywords = const [],
    this.description,
    this.value,
    this.changed = false,
    this.elsewhere,
  });

  final S section;
  final String sectionLabel;
  final String title;
  final KapyIconData icon;

  /// The key the setting's row already carries, which is how its pane is
  /// searched for it. Null for a whole category, which opens at its top.
  final String? target;

  /// The heading the row sits under.
  final String? group;

  /// The other words people use for it — "dark mode" for the theme.
  final List<String> keywords;

  /// The row's own line of explanation.
  final String? description;

  /// What it is set to, in a word, shown at the end of a result.
  final String? value;

  /// Whether it is off its default.
  final bool changed;

  /// Where a setting that is not in settings lives instead — "In a voice
  /// note's player". Such a result says so and goes nowhere.
  final String? elsewhere;

  /// Stable across searches, for the result row's key.
  String get id => target ?? 'section-$sectionLabel-$title';

  /// The line under it in the results: where it lives, in the words its pane
  /// uses — "Appearance › Text" — and what it is for.
  String get place {
    if (elsewhere case final where?) return where;
    if (target == null && title == sectionLabel) {
      return description ?? sectionLabel;
    }
    final heading = group;
    final path = heading == null || heading.toLowerCase() == title.toLowerCase()
        ? sectionLabel
        : '$sectionLabel › $heading';
    final about = description;
    if (about == null || about.isEmpty) return path;
    return '$path · ${about[0].toLowerCase()}${about.substring(1)}';
  }
}

/// The entries [query] finds, best first.
///
/// Every word typed has to turn up somewhere in an entry — its title, the
/// other names it goes by, its heading, its category, its explanation — so a
/// second word narrows rather than widens. A word that begins a word in the
/// title counts most, one in the explanation least, and a match from the
/// middle of a word only counts from three letters on, where it stops being
/// noise.
List<SettingsSearchEntry<S>> searchSettings<S>(
  List<SettingsSearchEntry<S>> entries,
  String query, {
  int limit = 40,
}) {
  final phrase = _normalize(query);
  if (phrase.isEmpty) return const [];
  final terms = phrase.split(' ');
  final scored = <(int, int)>[];
  for (var index = 0; index < entries.length; index++) {
    final score = _score(entries[index], terms, phrase);
    if (score != null) scored.add((score, index));
  }
  // Ties keep the order the panes list them in.
  scored.sort(
    (a, b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : a.$2.compareTo(b.$2),
  );
  return [for (final (_, index) in scored.take(limit)) entries[index]];
}

String _normalize(String text) => text
    .toLowerCase()
    .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
    .trim();

int? _score<S>(
  SettingsSearchEntry<S> entry,
  List<String> terms,
  String phrase,
) {
  final title = _normalize(entry.title);
  final keywords = [for (final keyword in entry.keywords) _normalize(keyword)];
  final fields = <(String, int)>[
    (title, 8),
    (keywords.join(' '), 5),
    (_normalize(entry.group ?? ''), 3),
    (_normalize(entry.sectionLabel), 3),
    (_normalize(entry.description ?? ''), 1),
  ];

  var total = 0;
  for (final term in terms) {
    var best = 0;
    for (final (text, weight) in fields) {
      if (text.isEmpty) continue;
      final words = text.split(' ');
      final found = words.contains(term)
          ? weight * 3
          : words.any((word) => word.startsWith(term))
          ? weight * 2
          : term.length >= 3 && text.contains(term)
          ? weight
          : 0;
      if (found > best) best = found;
    }
    if (best == 0) return null;
    total += best;
  }
  // The whole of what was typed, as it stands, beats the sum of its words.
  if (title == phrase) {
    total += 40;
  } else if (title.startsWith(phrase)) {
    total += 20;
  }
  if (keywords.contains(phrase)) total += 16;
  return total;
}

/// The field at the head of settings that finds one.
///
/// Escape empties it before it closes anything: somebody who typed the wrong
/// thing wants the field back, not the whole of settings gone.
class SettingsSearchField extends StatelessWidget {
  const SettingsSearchField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.onMove,
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmitted;

  /// The arrow keys, moving which result Return opens.
  final ValueChanged<int> onMove;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyUpEvent && controller.text.isNotEmpty) {
          if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
            onMove(1);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            onMove(-1);
            return KeyEventResult.handled;
          }
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            controller.text.isNotEmpty) {
          controller.clear();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) => SizedBox(
          height: 28,
          child: TextField(
            key: const ValueKey('settings-search'),
            controller: controller,
            focusNode: focusNode,
            autofocus: autofocus,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => onSubmitted(),
            style: TextStyle(
              fontSize: 12.5,
              height: 16 / 12.5,
              color: palette.textPrimary,
            ),
            cursorHeight: 14,
            decoration: kapyFieldDecoration(
              context,
              hintText: 'Search',
              hintStyle: TextStyle(
                fontSize: 12.5,
                height: 16 / 12.5,
                color: palette.textSecondary,
              ),
              fillColor: palette.cardBackground,
              borderColor: palette.increasedContrast
                  ? palette.controlBorder
                  : Colors.transparent,
              borderWidth: palette.increasedContrast ? 1 : 0,
              radius: AppRadii.control,
              neutralFocus: true,
              // InputDecorator gives its prefix the whole adornment slot.
              // Center loosens those constraints so the glyph keeps its
              // intended size.
              prefixIcon: Padding(
                padding: const EdgeInsets.only(left: 9, right: 7),
                child: Center(
                  widthFactor: 1,
                  heightFactor: 1,
                  child: KapyIcon(
                    KapyIcons.searchRounded,
                    size: 13,
                    color: palette.textSecondary,
                  ),
                ),
              ),
              prefixIconConstraints: const BoxConstraints(minHeight: 26),
              suffixIcon: value.text.isEmpty
                  ? null
                  : CompactIconButton(
                      key: const ValueKey('settings-search-clear'),
                      tooltip: 'Clear search',
                      extent: 28,
                      foregroundColor: palette.textTertiary,
                      onPressed: () {
                        controller.clear();
                        focusNode.requestFocus();
                      },
                      icon: KapyIcon(
                        KapyIcons.cancelRounded,
                        size: AppControlMetrics.iconAdornment,
                      ),
                    ),
              suffixIconConstraints: const BoxConstraints(
                minWidth: 30,
                minHeight: 28,
              ),
              contentPadding: const EdgeInsets.only(
                right: 10,
                top: 8.5,
                bottom: 8.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What a search found, as rows that go to it — or, finding nothing, a line
/// that says so rather than an empty pane.
class SettingsSearchResults<S> extends StatelessWidget {
  const SettingsSearchResults({
    super.key,
    required this.query,
    required this.results,
    required this.onOpen,
    required this.marked,
  });

  final String query;
  final List<SettingsSearchEntry<S>> results;
  final ValueChanged<SettingsSearchEntry<S>> onOpen;

  /// The result Return opens, lit so a keyboard can see which.
  final int marked;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    if (results.isEmpty) {
      return Padding(
        key: const ValueKey('settings-search-empty'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 36),
        child: Column(
          children: [
            KapyIcon(
              KapyIcons.searchOffRounded,
              size: 26,
              color: palette.textTertiary,
            ),
            const SizedBox(height: 10),
            Text(
              'No results for “${query.trim()}”',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: SettingsMetrics.titleSize,
                fontWeight: AppWeight.font(AppWeight.regular),
                fontVariations: AppWeight.wght(AppWeight.regular),
                color: palette.textSecondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Try “dark”, “font”, or “export”',
              textAlign: TextAlign.center,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: SettingsMetrics.subtitleSize,
                color: palette.textTertiary,
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsGroup(
          children: [
            for (var index = 0; index < results.length; index++)
              _ResultRow(
                key: ValueKey('settings-search-result-${results[index].id}'),
                entry: results[index],
                marked: index == marked,
                onTap: results[index].elsewhere == null
                    ? () => onOpen(results[index])
                    : null,
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(3, 16, 3, 0),
          child: Text(
            'Also try “dark”, “hotkey”, “backup” or a key like “⌘H”.',
            style: TextStyle(fontSize: 12.5, color: palette.textDescription),
          ),
        ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    super.key,
    required this.entry,
    required this.marked,
    required this.onTap,
  });

  final SettingsSearchEntry<Object?> entry;
  final bool marked;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final value = entry.value;
    final row = Container(
      constraints: BoxConstraints(minHeight: SettingsMetrics.minRowHeight),
      padding: SettingsMetrics.padding,
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            KapyIcon(entry.icon, size: 16, color: palette.textTertiary),
            const SizedBox(width: 12),
            Expanded(
              child: SettingsRowCopy(
                title: entry.title,
                subtitle: entry.place,
                changed: entry.changed,
              ),
            ),
            if (value != null && value.isNotEmpty) ...[
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (box.maxWidth * 0.4).clamp(0, 180).toDouble(),
                ),
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: SettingsMetrics.buttonLabelSize,
                    color: palette.textDescription,
                  ),
                ),
              ),
            ],
            if (marked) ...[
              const SizedBox(width: 10),
              Container(
                height: 20,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.controlBackground,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: palette.controlBorder),
                ),
                child: Text(
                  '↵',
                  style: TextStyle(fontSize: 11, color: palette.textSecondary),
                ),
              ),
            ],
          ],
        ),
      ),
    );
    final lit = marked ? ColoredBox(color: palette.hover, child: row) : row;
    final onTap = this.onTap;
    if (onTap == null) return lit;
    return Semantics(
      button: true,
      child: InkWell(onTap: onTap, child: lit),
    );
  }
}

/// A moment's light on the row a search led to, so the eye lands on it.
///
/// Painted over the pane rather than by the row, so that any row can be lit
/// without knowing it can be, and the light follows the row if the pane
/// scrolls while it fades.
class SettingsFlashLayer extends LeafRenderObjectWidget {
  const SettingsFlashLayer({
    super.key,
    required this.target,
    required this.progress,
  });

  /// The row to light, or null for nothing.
  final ValueListenable<RenderBox?> target;

  /// Zero to one over the life of the light.
  final Animation<double> progress;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderFlash(
    target: target,
    progress: progress,
    color: Theme.of(context).colorScheme.primary,
  );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderFlash)
      ..target = target
      ..progress = progress
      ..color = Theme.of(context).colorScheme.primary;
  }
}

class _RenderFlash extends RenderBox {
  _RenderFlash({
    required ValueListenable<RenderBox?> target,
    required Animation<double> progress,
    required Color color,
  }) : _target = target,
       _progress = progress,
       _color = color;

  ValueListenable<RenderBox?> _target;
  set target(ValueListenable<RenderBox?> value) {
    if (identical(value, _target)) return;
    if (attached) _target.removeListener(markNeedsPaint);
    _target = value;
    if (attached) _target.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Animation<double> _progress;
  set progress(Animation<double> value) {
    if (identical(value, _progress)) return;
    if (attached) _progress.removeListener(markNeedsPaint);
    _progress = value;
    if (attached) _progress.addListener(markNeedsPaint);
    markNeedsPaint();
  }

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  bool hitTestSelf(Offset position) => false;

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _target.addListener(markNeedsPaint);
    _progress.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _target.removeListener(markNeedsPaint);
    _progress.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final box = _target.value;
    final t = _progress.value;
    if (box == null || t <= 0 || t >= 1) return;
    if (!box.attached || !box.hasSize || !_isInside(box)) return;

    // In quickly, held while the eye finds it, then out slowly.
    final strength = t < 0.12
        ? t / 0.12
        : t > 0.55
        ? (1 - t) / 0.45
        : 1.0;
    final origin = globalToLocal(box.localToGlobal(Offset.zero));
    final rect = (origin & box.size).deflate(0.75).shift(offset);
    final shape = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    context.canvas
      ..save()
      ..clipRect(offset & size)
      ..drawRRect(
        shape,
        Paint()..color = _color.withValues(alpha: 0.14 * strength),
      )
      ..drawRRect(
        shape,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = _color.withValues(alpha: 0.75 * strength),
      )
      ..restore();
  }

  /// Only a row in the pane this layer covers — the [Stack] it shares with
  /// that pane — so a page sliding past on its way out cannot light the row
  /// on the page coming in.
  bool _isInside(RenderObject box) {
    var pane = parent;
    while (pane != null && pane is! RenderStack) {
      pane = pane.parent;
    }
    if (pane == null) return false;
    for (RenderObject? node = box; node != null; node = node.parent) {
      if (identical(node, pane)) return true;
    }
    return false;
  }
}
