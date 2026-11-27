import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../core/theme.dart';
import '../../recaps/recap_lines.dart';
import '../../recaps/recap_period.dart';
import '../../recaps/recap_story.dart';
import '../../speech/moments.dart';
import '../editor/voice_chip.dart';
import '../sidebar_timestamp.dart';
import '../tag_ui.dart' show TagDot, tagColourOf;

/// The colours a recap is drawn in: the page, the card and the orange tint,
/// with the text and marks that sit on them, from the design system's Modern
/// ladder, so a story reads the same in every theme.
@immutable
class RecapTones {
  const RecapTones._({
    required this.page,
    required this.card,
    required this.tint,
    required this.text,
    required this.secondary,
    required this.tertiary,
    required this.fill,
    required this.hairline,
    required this.ring,
    required this.bar,
    required this.track,
    required this.accent,
    required this.accentInk,
    required this.onAccent,
    required this.cardEdge,
    required this.quietButton,
    required this.onQuietButton,
    required this.strongButton,
    required this.onStrongButton,
    required this.levels,
  });

  factory RecapTones.of(Brightness brightness) =>
      brightness == Brightness.dark ? _dark : _light;

  static const _dark = RecapTones._(
    page: Color(0xFF0D0D0D),
    card: Color(0xFF1A1A1A),
    tint: Color(0xFF2B1C12),
    text: Color(0xFFEDEDED),
    secondary: Color(0xFFA3A3A3),
    tertiary: Color(0xFF8F8F8F),
    fill: Color(0xFF262626),
    hairline: Color(0xFF262626),
    ring: Color(0xFF5C5C5C),
    bar: Color(0xFF3A3A3A),
    track: Color(0x38EDEDED),
    accent: Color(0xFFE8772E),
    accentInk: Color(0xFFE8772E),
    onAccent: Color(0xFF1A0E06),
    cardEdge: Color(0x12FFFFFF),
    quietButton: Color(0xFF3A2A1E),
    onQuietButton: Color(0xFFEDEDED),
    strongButton: Color(0xFFEDEDED),
    onStrongButton: Color(0xFF0D0D0D),
    levels: [
      Color(0xFF1A1A1A),
      Color(0xFF262626),
      Color(0xFF3A3A3A),
      Color(0xFF5C5C5C),
    ],
  );

  static const _light = RecapTones._(
    page: Color(0xFFF4F4F4),
    card: Color(0xFFFFFFFF),
    tint: Color(0xFFFBEADF),
    text: Color(0xFF171717),
    secondary: Color(0xFF525252),
    tertiary: Color(0xFF6B6B6B),
    fill: Color(0xFFEDEDED),
    hairline: Color(0xFFE5E5E5),
    ring: Color(0xFFA3A3A3),
    bar: Color(0xFFA3A3A3),
    track: Color(0x24171717),
    accent: Color(0xFFD9692A),
    accentInk: Color(0xFFB9551A),
    onAccent: Color(0xFF1A0E06),
    cardEdge: Color(0x0F000000),
    quietButton: Color(0xFFFFFFFF),
    onQuietButton: Color(0xFF171717),
    strongButton: Color(0xFF171717),
    onStrongButton: Color(0xFFFFFFFF),
    levels: [
      Color(0xFFFFFFFF),
      Color(0xFFE5E5E5),
      Color(0xFFD4D4D4),
      Color(0xFFA3A3A3),
    ],
  );

  final Color page;
  final Color card;

  /// The cover's and the closing card's.
  final Color tint;
  final Color text;
  final Color secondary;
  final Color tertiary;
  final Color fill;
  final Color hairline;

  /// An open task's circle.
  final Color ring;

  /// A chart's bars, the busiest in [accent].
  final Color bar;

  /// The progress bars' track.
  final Color track;
  final Color accent;

  /// Orange marks on the page and the tint.
  final Color accentInk;
  final Color onAccent;
  final Color cardEdge;
  final Color quietButton;
  final Color onQuietButton;
  final Color strongButton;
  final Color onStrongButton;

  /// The calendar's days, from none to many, under the busiest in [accent].
  final List<Color> levels;

  /// What [card] is drawn on: the tint for the cover and the closing card,
  /// the card colour for a single line, the page for the rest.
  Color surface(RecapCard card) => switch (card) {
    RecapCard.cover || RecapCard.closing => tint,
    RecapCard.voice || RecapCard.line => this.card,
    _ => page,
  };
}

/// Interface text on the design system's ladder, tracked by size.
TextStyle recapText(
  double size,
  double line,
  double weight,
  Color color, {
  bool tabular = false,
  double? spacing,
}) => chromeStyle(
  size: size,
  line: line,
  weight: weight,
  color: color,
  tabular: tabular,
  letterSpacing: spacing ?? _tracking(size),
);

TextStyle _hand(
  double size,
  double line,
  double weight,
  Color color, {
  double spacing = 0,
}) => chromeStyle(
  size: size,
  line: line,
  weight: weight,
  color: color,
  family: 'Shantell Sans',
  letterSpacing: spacing,
);

double _tracking(double size) => switch (size) {
  >= 18 => 0,
  >= 17 => -0.2,
  >= 16 => -0.1,
  >= 15 => -0.05,
  >= 14 => 0,
  >= 13 => 0.1,
  _ => 0.15,
};

/// What a card hands back to the viewer.
class RecapCardActions {
  const RecapCardActions({required this.openNote, required this.play});

  final void Function(RecapHighlight highlight) openNote;
  final void Function(RecapQuote quote) play;
}

/// One of [story]'s cards, without the viewer's progress, header or the
/// closing card's buttons: what Share as image draws.
class RecapCardBody extends StatelessWidget {
  const RecapCardBody({
    super.key,
    required this.story,
    required this.card,
    required this.tones,
    required this.actions,
  });

  final RecapStory story;
  final RecapCard card;
  final RecapTones tones;
  final RecapCardActions actions;

  @override
  Widget build(BuildContext context) {
    final t = tones;
    return switch (card) {
      RecapCard.cover => _Cover(story, t),
      RecapCard.numbers => _Numbers(story, t),
      RecapCard.week => _Week(story, t),
      RecapCard.calendar => _Calendar(story, t),
      RecapCard.highlights => _Highlights(story, t, actions.openNote),
      RecapCard.topics => _Topics(story, t),
      RecapCard.tasks => _Tasks(story, t),
      RecapCard.voice => _Voice(story, t, actions.play),
      RecapCard.months => _Months(story, t),
      RecapCard.moments => _Moments(story, t),
      RecapCard.line => _Line(story, t),
      RecapCard.closing => _Closing(story, t),
    };
  }
}

/// A card's column: what it says from the top, and what it keeps at the
/// bottom, scrolling instead of clipping when large text makes it longer
/// than the card.
class _Column extends StatelessWidget {
  const _Column({required this.top, this.bottom = const []});

  final List<Widget> top;
  final List<Widget> bottom;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: IntrinsicHeight(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [...top, const Spacer(), ...bottom],
          ),
        ),
      ),
    ),
  );
}

Widget _eyebrow(String text, RecapTones t) =>
    Text(text, style: recapText(15, 20, 500, t.secondary));

Widget _heading(String text, RecapTones t) => Padding(
  padding: const EdgeInsets.only(top: 10),
  child: Text(
    text,
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    style: recapText(28, 34, 600, t.text, spacing: -0.4),
  ),
);

Widget _label(String text, Color color) =>
    Text(text, style: recapText(13, 16, 500, color));

String _coverLabel(RecapStory story) {
  final first = story.period.first;
  final last = story.period.last;
  String month(DateTime day) => SidebarTimestamp.monthName(day);
  return switch (story.kind) {
    RecapKind.day => SidebarTimestamp.fullDay(first),
    RecapKind.week =>
      first.month == last.month
          ? '${first.day}–${last.day} ${month(last)}'
          : '${first.day} ${month(first)} – ${last.day} ${month(last)}',
    RecapKind.month => '${month(first)} ${first.year}',
    RecapKind.year => 'Your year in Kapy Notes',
  };
}

/// "6 notes, 4 tasks done and a voice note": a day names its voice notes,
/// a longer period the time recorded.
String _counted(RecapStory story) {
  final counts = story.numbers.counts;
  String count(int n, String one, String many) =>
      '${recapFigures(n)} ${n == 1 ? one : many}';
  final parts = [
    count(counts.notes, 'note', 'notes'),
    if (counts.tasksDone > 0)
      count(counts.tasksDone, 'task done', 'tasks done'),
    if (story.kind == RecapKind.day && counts.voiceNotes > 0)
      counts.voiceNotes == 1
          ? 'a voice note'
          : '${counts.voiceNotes} voice notes',
    if (story.kind != RecapKind.day && counts.voiceMinutes > 0)
      '${recapDuration(counts.voiceMinutes)} recorded',
  ];
  return parts.length == 1
      ? parts.single
      : '${parts.take(parts.length - 1).join(', ')} and ${parts.last}';
}

class _Cover extends StatelessWidget {
  const _Cover(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) {
    final year = story.kind == RecapKind.year;
    return _Column(
      top: [
        _eyebrow(_coverLabel(story), t),
        if (year)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '${story.period.first.year}',
                style: _hand(108, 116, 600, t.text, spacing: -2),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text(
            recapShown(story.title),
            maxLines: year ? 3 : 5,
            overflow: TextOverflow.ellipsis,
            style: year
                ? _hand(30, 38, 500, t.text)
                : _hand(44, 50, 500, t.text),
          ),
        ),
      ],
      bottom: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                _counted(story),
                style: recapText(14, 20, 400, t.secondary, tabular: true),
              ),
            ),
            const SizedBox(width: 8),
            const ExcludeSemantics(
              child: Image(
                image: AssetImage('assets/mascot/kapy_standing.webp'),
                width: 150,
                height: 212,
                fit: BoxFit.contain,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// A big figure with what it counts beside it.
class _Figure extends StatelessWidget {
  const _Figure(
    this.value,
    this.icon,
    this.label,
    this.t, {
    this.first = false,
  });

  final String value;
  final KapyIconData icon;
  final String label;
  final RecapTones t;
  final bool first;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        border: first
            ? null
            : Border(top: BorderSide(color: t.hairline, width: 0.5)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 14,
        children: [
          Text(
            value,
            style: recapText(76, 76, 600, t.text, tabular: true, spacing: -3),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KapyIcon(icon, size: 18, color: t.secondary),
                const SizedBox(height: 6),
                Text(label, style: recapText(17, 22, 400, t.secondary)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// [minutes] as a figure and what it counts: "12" minutes recorded, "3 h
/// 20" recorded.
(String, String) _recorded(int minutes, {String unit = ' recorded'}) {
  if (minutes < 60) {
    return ('$minutes', '${minutes == 1 ? 'minute' : 'minutes'}$unit');
  }
  final hours = minutes ~/ 60;
  if (minutes % 60 == 0) {
    return (recapFigures(hours), '${hours == 1 ? 'hour' : 'hours'}$unit');
  }
  return ('$hours h ${minutes % 60}', unit.isEmpty ? 'recorded' : unit.trim());
}

class _Numbers extends StatelessWidget {
  const _Numbers(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) {
    final counts = story.numbers.counts;
    final day = story.kind == RecapKind.day;
    final (minutes, recorded) = _recorded(counts.voiceMinutes);
    final run = story.numbers.longestRun;
    final figures = [
      (
        recapFigures(counts.notes),
        KapyIcons.noteOutlined,
        counts.notes == 1 ? 'note written' : 'notes written',
      ),
      if (counts.tasksDone > 0)
        (
          recapFigures(counts.tasksDone),
          KapyIcons.checkCircleRounded,
          counts.tasksDone == 1 ? 'task done' : 'tasks done',
        ),
      if (counts.voiceMinutes > 0) (minutes, KapyIcons.micRounded, recorded),
      if (!day && run > 1)
        (
          recapFigures(run),
          KapyIcons.fireOutlined,
          'days in a row, your best run',
        ),
    ];
    return _Column(
      top: [
        _eyebrow(day ? 'Your day in numbers' : 'Your year in numbers', t),
        const SizedBox(height: 8),
        for (final (i, (value, icon, label)) in figures.indexed)
          _Figure(value, icon, label, t, first: i == 0),
      ],
      bottom: [
        if (day)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              story.comparison,
              style: recapText(15, 22, 400, t.secondary, tabular: true),
            ),
          ),
      ],
    );
  }
}

/// The period's counts side by side on cards.
class _Tiles extends StatelessWidget {
  const _Tiles(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) {
    final counts = story.numbers.counts;
    final (minutes, recorded) = _recorded(counts.voiceMinutes, unit: '');
    final tiles = [
      (recapFigures(counts.notes), counts.notes == 1 ? 'note' : 'notes'),
      (recapFigures(counts.tasksDone), 'tasks done'),
      if (counts.voiceMinutes > 0) (minutes, recorded),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        for (final (value, label) in tiles)
          Expanded(
            child: MergeSemantics(
              child: _Panel(
                t,
                radius: 18,
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 4,
                  children: [
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        value,
                        style: recapText(
                          26,
                          30,
                          600,
                          t.text,
                          tabular: true,
                          spacing: -0.6,
                        ),
                      ),
                    ),
                    Text(label, style: recapText(13, 16, 400, t.secondary)),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A card on the card: the card colour, with its edge.
class _Panel extends StatelessWidget {
  const _Panel(
    this.t, {
    required this.child,
    required this.radius,
    required this.padding,
  });

  final RecapTones t;
  final Widget child;
  final double radius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: t.card,
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: t.cardEdge, width: 0.5),
    ),
    child: Padding(padding: padding, child: child),
  );
}

/// Bars for [values], the one at [busiest] in orange, each over its label.
class _Bars extends StatelessWidget {
  const _Bars({
    required this.values,
    required this.labels,
    required this.names,
    required this.busiest,
    required this.height,
    required this.width,
    required this.t,
  });

  final List<int> values;
  final List<String> labels;

  /// What a screen reader says for each bar.
  final List<String> names;
  final int? busiest;
  final double height;
  final double width;
  final RecapTones t;

  @override
  Widget build(BuildContext context) {
    final most = values.fold(0, math.max);
    final words = MediaQuery.textScalerOf(context).scale(14);
    final room = math.max(24, height - 2 * (words + 6));
    return SizedBox(
      height: math.max(height, 2 * (words + 6) + 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 4,
        children: [
          for (var i = 0; i < values.length; i++)
            Expanded(
              child: Semantics(
                label:
                    '${names[i]}, ${values[i]} ${values[i] == 1 ? 'note' : 'notes'}',
                child: ExcludeSemantics(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    spacing: 6,
                    children: [
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          '${values[i]}',
                          style: recapText(
                            12,
                            14,
                            500,
                            i == busiest ? t.text : t.tertiary,
                            tabular: true,
                          ),
                        ),
                      ),
                      Container(
                        width: width,
                        height: most == 0
                            ? 4
                            : math.max(4, room * values[i] / most).toDouble(),
                        decoration: BoxDecoration(
                          color: i == busiest ? t.accent : t.bar,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          labels[i],
                          style: recapText(
                            12,
                            14,
                            i == busiest ? 500 : 400,
                            i == busiest ? t.text : t.tertiary,
                          ),
                        ),
                      ),
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

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

class _Week extends StatelessWidget {
  const _Week(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) {
    final busiest = story.busiest;
    final days = [
      for (var i = 0; i < story.numbers.chart.length; i++) story.day(i),
    ];
    return _Column(
      top: [
        _eyebrow('Your week', t),
        if (busiest != null)
          _heading(
            '${_weekdays[story.day(busiest).weekday - 1]} was the busiest day',
            t,
          ),
        const SizedBox(height: 22),
        _Bars(
          values: story.numbers.chart,
          labels: [for (final day in days) SidebarTimestamp.shortWeekday(day)],
          names: [for (final day in days) SidebarTimestamp.fullDay(day)],
          busiest: busiest,
          height: 214,
          width: 32,
          t: t,
        ),
      ],
      bottom: [
        Padding(
          padding: const EdgeInsets.only(top: 16),
          child: _Tiles(story, t),
        ),
      ],
    );
  }
}

class _Calendar extends StatelessWidget {
  const _Calendar(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) {
    final chart = story.numbers.chart;
    final written = chart.where((n) => n > 0).length;
    final most = chart.fold(0, math.max);
    final busiest = story.busiest;
    final start = story.record.firstWeekday;
    final lead = (story.period.first.weekday - start) % 7;
    final cells = <int?>[
      for (var i = 0; i < lead; i++) null,
      for (var i = 0; i < chart.length; i++) i,
    ];
    final run = story.run;
    Widget cell(int? i) {
      if (i == null) return const SizedBox(width: 38, height: 38);
      final count = chart[i];
      final level = count == 0 ? 0 : math.min(3, (count * 3 / most).ceil());
      final top = count * 4 > most * 3;
      final day = story.day(i);
      return Semantics(
        label:
            '${SidebarTimestamp.fullDay(day)}, $count ${count == 1 ? 'note' : 'notes'}',
        child: ExcludeSemantics(
          child: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: top ? t.accent : t.levels[level],
              borderRadius: BorderRadius.circular(10),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${day.day}',
                style: recapText(
                  12,
                  14,
                  500,
                  top
                      ? t.onAccent
                      : level >= 2
                      ? t.text
                      : t.tertiary,
                  tabular: true,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return _Column(
      top: [
        _eyebrow('Days you wrote', t),
        _heading('$written of ${chart.length} days', t),
        const SizedBox(height: 22),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: [
              ExcludeSemantics(
                child: Row(
                  spacing: 6,
                  children: [
                    for (var i = 0; i < 7; i++)
                      SizedBox(
                        width: 38,
                        child: Text(
                          'MTWTFSS'[(start - 1 + i) % 7],
                          textAlign: TextAlign.center,
                          style: recapText(12, 14, 400, t.tertiary),
                        ),
                      ),
                  ],
                ),
              ),
              for (var row = 0; row * 7 < cells.length; row++)
                Row(
                  spacing: 6,
                  children: [
                    for (final i in cells.skip(row * 7).take(7)) cell(i),
                  ],
                ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ExcludeSemantics(
                  child: Row(
                    spacing: 4,
                    children: [
                      Text('Fewer', style: recapText(12, 14, 400, t.tertiary)),
                      const SizedBox(width: 2),
                      for (final colour in [...t.levels.skip(1), t.accent])
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: colour,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      const SizedBox(width: 2),
                      Text('More', style: recapText(12, 14, 400, t.tertiary)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
      bottom: [
        if (run != null)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: MergeSemantics(
              child: _Panel(
                t,
                radius: 18,
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: KapyIcon(
                        KapyIcons.fireOutlined,
                        size: 20,
                        color: t.accentInk,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 4,
                        children: [
                          Text(
                            '${story.numbers.longestRun} days in a row',
                            style: recapText(
                              17,
                              22,
                              500,
                              t.text,
                              tabular: true,
                            ),
                          ),
                          Text(
                            'Your longest run, '
                            '${SidebarTimestamp.dayRange(run.$1, run.$2)}.'
                            '${busiest == null ? '' : ' ${SidebarTimestamp.weekdayAndDay(story.day(busiest))} was the busiest day.'}',
                            style: recapText(
                              14,
                              20,
                              400,
                              t.secondary,
                              tabular: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A highlight: the note it is about, and Kapy AI's line about it. Tapping
/// it opens the note.
class _HighlightCard extends StatelessWidget {
  const _HighlightCard(this.highlight, this.t, this.open);

  final RecapHighlight highlight;
  final RecapTones t;
  final void Function(RecapHighlight highlight) open;

  @override
  Widget build(BuildContext context) {
    final title = recapShown(highlight.title);
    final line = recapShown(highlight.line);
    return RecapPress(
      label: 'Open $title. $line',
      onTap: () => open(highlight),
      child: _Panel(
        t,
        radius: 20,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          spacing: 12,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: recapText(15, 20, 500, t.text),
                  ),
                  Text(
                    line,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: recapText(14, 20, 400, t.secondary, tabular: true),
                  ),
                ],
              ),
            ),
            KapyIcon(
              KapyIcons.chevronRightRounded,
              size: 16,
              color: t.tertiary,
            ),
          ],
        ),
      ),
    );
  }
}

/// A topic's row: its name, how many notes carry it, and Kapy AI's line.
class _TopicRow extends StatelessWidget {
  const _TopicRow(this.topic, this.t, {this.most});

  final RecapTopicRow topic;
  final RecapTones t;

  /// The most notes any topic has, for a bar under each, or null for none.
  final int? most;

  @override
  Widget build(BuildContext context) {
    final notes = topic.notes;
    final line = topic.line;
    final most = this.most;
    return MergeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: t.hairline, width: 0.5)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 10,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 8,
                  children: [
                    if (topic.colour case final colour?)
                      TagDot(tagColourOf(colour)),
                    Flexible(
                      child: Text(
                        recapShown(topic.name),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: recapText(17, 22, 500, t.text),
                      ),
                    ),
                  ],
                ),
                if (notes != null)
                  Text(
                    '${recapFigures(notes)} ${notes == 1 ? 'note' : 'notes'}',
                    style: recapText(14, 18, 400, t.tertiary, tabular: true),
                  ),
              ],
            ),
            if (line != null)
              Text(
                recapShown(line),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: recapText(14, 20, 400, t.secondary, tabular: true),
              ),
            if (most != null && notes != null && most > 0)
              ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: SizedBox(
                    height: 6,
                    child: Stack(
                      children: [
                        Positioned.fill(child: ColoredBox(color: t.fill)),
                        FractionallySizedBox(
                          widthFactor: notes / most,
                          heightFactor: 1,
                          child: ColoredBox(color: t.secondary),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Highlights extends StatelessWidget {
  const _Highlights(this.story, this.t, this.open);

  final RecapStory story;
  final RecapTones t;
  final void Function(RecapHighlight highlight) open;

  @override
  Widget build(BuildContext context) {
    final highlights = story.lines.highlights;
    final week = story.kind == RecapKind.week;
    return _Column(
      top: [
        _eyebrow('Highlights', t),
        _heading(
          week
              ? 'What the week was about'
              : highlights.length == 1
              ? 'One note stood out'
              : '${highlights.length} notes stood out',
          t,
        ),
        if (week) ...[
          const SizedBox(height: 14),
          for (final topic in story.topics) _TopicRow(topic, t),
        ],
        const SizedBox(height: 22),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [for (final it in highlights) _HighlightCard(it, t, open)],
        ),
      ],
      bottom: [
        if (highlights.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'Tap a note to open it',
              textAlign: TextAlign.center,
              style: recapText(13, 18, 400, t.tertiary),
            ),
          ),
      ],
    );
  }
}

/// [names] as a sentence: "Work, Acme and Lisbon".
String _listed(List<String> names) => names.length < 2
    ? names.join()
    : '${names.take(names.length - 1).join(', ')} and ${names.last}';

class _Topics extends StatelessWidget {
  const _Topics(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) {
    final topics = story.topics;
    final counted = story.numbers.topics;
    final most = counted.fold(0, (most, topic) => math.max(most, topic.notes));
    final month = story.kind == RecapKind.month;
    return _Column(
      top: [
        _eyebrow(
          month
              ? 'In ${SidebarTimestamp.monthName(story.period.first)}'
              : 'What your year was about',
          t,
        ),
        if (counted.isNotEmpty)
          _heading(
            _listed([for (final topic in counted) recapShown(topic.name)]),
            t,
          ),
        if (month) ...[const SizedBox(height: 22), _Tiles(story, t)],
        if (topics.isNotEmpty) ...[
          const SizedBox(height: 20),
          if (month) _label('Most written about', t.tertiary),
          for (final topic in topics) _TopicRow(topic, t, most: most),
        ],
      ],
    );
  }
}

/// A task's circle: filled and ticked when it is done.
class _TaskMark extends StatelessWidget {
  const _TaskMark(this.done, this.t);

  final bool done;
  final RecapTones t;

  @override
  Widget build(BuildContext context) => Container(
    width: 18,
    height: 18,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: done ? t.tertiary : null,
      border: done ? null : Border.all(color: t.ring, width: 1.5),
    ),
    child: done
        ? Center(
            child: KapyIcon(KapyIcons.checkRounded, size: 12, color: t.page),
          )
        : null,
  );
}

List<Widget> _taskList(
  String label,
  List<String> tasks,
  bool done,
  RecapTones t, {
  Color? labelColor,
}) => [
  _label(label, labelColor ?? t.tertiary),
  for (final task in tasks)
    MergeSemantics(
      child: Semantics(
        checked: done,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Row(
            spacing: 12,
            children: [
              _TaskMark(done, t),
              Expanded(
                child: Text(
                  recapShown(task),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: recapText(16, 22, 400, done ? t.secondary : t.text),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
];

class _Tasks extends StatelessWidget {
  const _Tasks(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) {
    final done = story.numbers.counts.tasksDone;
    final total = done + story.numbers.tasksOpen;
    final marks = math.min(total, 12);
    final filled = total == 0 ? 0 : (done * marks / total).round();
    return _Column(
      top: [
        _eyebrow('Tasks', t),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: MergeSemantics(
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: 10,
              children: [
                Text(
                  recapFigures(done),
                  style: recapText(
                    76,
                    80,
                    600,
                    t.text,
                    tabular: true,
                    spacing: -3,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'of ${recapFigures(total)} done',
                    style: recapText(22, 28, 500, t.secondary, tabular: true),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: ExcludeSemantics(
            child: Row(
              spacing: 4,
              children: [
                for (var i = 0; i < marks; i++)
                  Expanded(
                    child: Container(
                      height: 6,
                      decoration: BoxDecoration(
                        color: i < filled ? t.text : t.fill,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (story.done.isNotEmpty) ...[
          const SizedBox(height: 22),
          ..._taskList('Done', story.done, true, t),
        ],
        if (story.open.isNotEmpty) ...[
          const SizedBox(height: 12),
          ..._taskList('Still open', story.open, false, t),
        ],
      ],
    );
  }
}

/// The voice quote, the recording's waveform played up to its moment, and
/// Play this part.
class _Voice extends StatelessWidget {
  const _Voice(this.story, this.t, this.play);

  final RecapStory story;
  final RecapTones t;
  final void Function(RecapQuote quote) play;

  @override
  Widget build(BuildContext context) {
    final quote = story.lines.quote!;
    final voice = story.voice;
    final where =
        '${recapShown(quote.title)} · at ${formatVoiceDuration(quote.at)}';
    return _Column(
      top: [
        Row(
          spacing: 10,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: t.tint, shape: BoxShape.circle),
              child: Center(
                child: KapyIcon(
                  KapyIcons.micRounded,
                  size: 16,
                  color: t.accentInk,
                ),
              ),
            ),
            Expanded(child: _eyebrow('From a voice note', t)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 44),
          child: Text(
            recapShown(quote.line),
            maxLines: 7,
            overflow: TextOverflow.ellipsis,
            style: recapText(29, 38, 500, t.text, spacing: -0.5),
          ),
        ),
      ],
      bottom: [
        if (voice != null)
          ExcludeSemantics(
            child: SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerLeft,
                child: CustomPaint(
                  size: const Size(44 * 5, 30),
                  painter: VoiceWaveformPainter(
                    peaks: voice.peaks,
                    progress: voice.durationMs == 0
                        ? null
                        : (quote.at.inMilliseconds / voice.durationMs)
                              .clamp(0, 1)
                              .toDouble(),
                    played: t.text,
                    unplayed: t.bar,
                    bars: 44,
                  ),
                ),
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: RecapPress(
            label: 'Play this part, $where',
            onTap: () => play(quote),
            child: Row(
              spacing: 12,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: t.strongButton,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: KapyIcon(
                      KapyIcons.playRounded,
                      size: 20,
                      color: t.onStrongButton,
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        'Play this part',
                        style: recapText(15, 20, 500, t.text),
                      ),
                      Text(
                        where,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: recapText(
                          13,
                          18,
                          400,
                          t.tertiary,
                          tabular: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Months extends StatelessWidget {
  const _Months(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) {
    final chart = story.numbers.chart;
    final busiest = story.busiest;
    var quietest = 0;
    for (var i = 1; i < chart.length; i++) {
      if (chart[i] < chart[quietest]) quietest = i;
    }
    String month(int i) => SidebarTimestamp.monthName(DateTime(2000, i + 1));
    final quiet = chart.isEmpty ? 0 : chart[quietest];
    return _Column(
      top: [
        _eyebrow('Month by month', t),
        if (busiest != null)
          _heading('${month(busiest)} was your busiest month', t),
        const SizedBox(height: 22),
        _Bars(
          values: chart,
          labels: [for (var i = 0; i < chart.length; i++) month(i)[0]],
          names: [for (var i = 0; i < chart.length; i++) month(i)],
          busiest: busiest,
          height: 234,
          width: 20,
          t: t,
        ),
      ],
      bottom: [
        if (busiest != null && quietest != busiest)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              'Your quietest month was ${month(quietest)}, with '
              '${quiet == 0 ? 'no notes' : '${recapFigures(quiet)} ${quiet == 1 ? 'note' : 'notes'}'}.',
              style: recapText(15, 22, 400, t.secondary, tabular: true),
            ),
          ),
      ],
    );
  }
}

class _Moments extends StatelessWidget {
  const _Moments(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) => _Column(
    top: [
      _eyebrow('A few moments', t),
      _heading('The days you’ll remember', t),
      const SizedBox(height: 14),
      for (final moment in story.lines.moments)
        MergeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: t.hairline, width: 0.5)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              spacing: 12,
              children: [
                SizedBox(
                  width: 36,
                  child: Text(
                    SidebarTimestamp.monthName(
                      DateTime(2000, moment.month),
                    ).substring(0, 3),
                    style: recapText(13, 18, 400, t.tertiary),
                  ),
                ),
                Expanded(
                  child: Text(
                    recapShown(moment.line),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: recapText(16, 22, 500, t.text),
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );
}

class _Line extends StatelessWidget {
  const _Line(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) => _Column(
    top: [
      _eyebrow('Your line of the year', t),
      Padding(
        padding: const EdgeInsets.only(top: 44),
        child: Text(
          recapShown(story.lines.line!),
          maxLines: 7,
          overflow: TextOverflow.ellipsis,
          style: recapText(32, 40, 500, t.text, spacing: -0.5),
        ),
      ),
    ],
  );
}

/// How tall the viewer's Save as note and Share as image are. The closing
/// card keeps room for them at its foot, but they are not part of it, so
/// Share as image never draws them.
const double recapActionsHeight = 50;

class _Closing extends StatelessWidget {
  const _Closing(this.story, this.t);

  final RecapStory story;
  final RecapTones t;

  @override
  Widget build(BuildContext context) {
    final next = story.lines.next;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _Column(
          top: [
            _eyebrow(story.closingLabel, t),
            if (story.wordsGone)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  'Some notes this recap read are hidden now, so what Kapy AI '
                  'wrote was taken out. Remake it from your notes as they are '
                  'now.',
                  style: recapText(22, 30, 500, t.text),
                ),
              )
            else if (next != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(
                  recapShown(next),
                  maxLines: 5,
                  overflow: TextOverflow.ellipsis,
                  style: _hand(36, 44, 500, t.text),
                ),
              ),
            if (story.open.isNotEmpty) ...[
              const SizedBox(height: 14),
              ..._taskList(
                'Still open',
                story.open.take(4).toList(),
                false,
                t,
                labelColor: t.secondary,
              ),
            ],
          ],
          bottom: [
            SizedBox(
              height:
                  MediaQuery.textScalerOf(context).scale(recapActionsHeight) +
                  16,
            ),
          ],
        ),
        const Positioned(
          right: -28,
          bottom: 106,
          child: ExcludeSemantics(
            child: Image(
              image: AssetImage('assets/mascot/kapy_cursor_peek.webp'),
              width: 84,
              height: 158,
              fit: BoxFit.contain,
            ),
          ),
        ),
      ],
    );
  }
}

/// Something a tap, a click, Enter or Space presses, read as a button.
class RecapPress extends StatelessWidget {
  const RecapPress({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) => onTap(),
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    ),
  );
}
