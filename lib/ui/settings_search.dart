import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/platform.dart';
import '../core/theme.dart';
import 'compact_icon_button.dart';
import 'control_surface.dart';
import 'settings_rows.dart';

/// One setting a search can find: what it is called, what else somebody
/// might call it, and where it lives.
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

  /// The row's own line of explanation: searched, never shown.
  final String? description;

  /// Stable across searches, for the result row's key.
  String get id => target ?? 'section-$sectionLabel';

  /// The line under it in the results: where it lives, in the words its pane
  /// uses — "General · Writing" — or, for a whole category, what is in it.
  /// A heading that only repeats the title is left out.
  String get place {
    if (target == null && title == sectionLabel) {
      return description ?? sectionLabel;
    }
    final heading = group;
    if (heading == null || heading.toLowerCase() == title.toLowerCase()) {
      return sectionLabel;
    }
    return '$sectionLabel · $heading';
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
    this.autofocus = false,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSubmitted;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
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
        builder: (context, value, _) => TextField(
          key: const ValueKey('settings-search'),
          controller: controller,
          focusNode: focusNode,
          autofocus: autofocus,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => onSubmitted(),
          style: TextStyle(
            fontSize: AppTypeScale.control,
            color: palette.textPrimary,
          ),
          cursorHeight: AppTypeScale.control + 2,
          decoration: kapyFieldDecoration(
            context,
            hintText: 'Search settings',
            hintStyle: TextStyle(
              fontSize: AppTypeScale.control,
              color: palette.textTertiary,
            ),
            // InputDecorator gives its prefix the whole adornment slot. Center
            // loosens those constraints so the glyph keeps its intended size.
            prefixIcon: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: KapyIcon(
                KapyIcons.searchRounded,
                size: AppControlMetrics.iconSearch,
                color: palette.textTertiary,
              ),
            ),
            prefixIconConstraints: BoxConstraints(
              minWidth: AppControlMetrics.fieldAdornmentSlot + 2,
              minHeight: AppControlMetrics.fieldAdornmentSlot,
            ),
            suffixIcon: value.text.isEmpty
                ? null
                : CompactIconButton(
                    key: const ValueKey('settings-search-clear'),
                    tooltip: 'Clear search',
                    extent: AppControlMetrics.fieldAdornmentSlot,
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
            suffixIconConstraints: BoxConstraints(
              minWidth: AppControlMetrics.fieldAdornmentSlot,
              minHeight: AppControlMetrics.fieldAdornmentSlot,
            ),
            contentPadding: EdgeInsets.symmetric(
              vertical: AppControlMetrics.fieldVerticalPadding,
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
  });

  final String query;
  final List<SettingsSearchEntry<S>> results;
  final ValueChanged<SettingsSearchEntry<S>> onOpen;

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
                fontWeight: FontWeight.w400,
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
        SettingsLabel(
          results.length == 1 ? '1 SETTING' : '${results.length} SETTINGS',
        ),
        SettingsGroup(
          children: [
            for (var index = 0; index < results.length; index++)
              _ResultRow(
                key: ValueKey('settings-search-result-${results[index].id}'),
                entry: results[index],
                // Return opens the first result, so a keyboard shows which.
                marked: index == 0 && AppPlatform.hasPointer,
                onTap: () => onOpen(results[index]),
              ),
          ],
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
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final row = SettingsNavigationRow(
      icon: entry.icon,
      title: entry.title,
      subtitle: entry.place,
      onTap: onTap,
    );
    return marked ? ColoredBox(color: palette.hover, child: row) : row;
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
