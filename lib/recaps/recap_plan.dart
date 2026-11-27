import '../ai/kapy_ai.dart';
import '../ui/sidebar_timestamp.dart';
import 'recap_material.dart';
import 'recap_period.dart';

/// A digest one part of a recap made: its text, and the titles it was sent,
/// in lower case, each to the note it names.
class RecapPiece {
  const RecapPiece(this.text, [this.sent = const {}]);

  final String text;
  final Map<String, String> sent;
}

/// One digest call in a recap's plan, over [first] to [last].
class RecapSlice {
  const RecapSlice(this.kind, this.first, this.last, this.key, {this.ready});

  final RecapKind kind;
  final DateTime first;
  final DateTime last;

  /// The days and a fingerprint of what they hold: a digest kept under it
  /// is good for as long as they hold the same.
  final String key;

  /// Its digest when one is already made: kept from an earlier try, or a
  /// month's own recap for a year. Asking for it costs nothing.
  final RecapPiece? ready;

  /// What the recap call calls its digest: "17–20 Nov", or "November" in a
  /// year.
  String get label => kind == RecapKind.year
      ? SidebarTimestamp.monthName(first)
      : SidebarTimestamp.dayRange(first, last);
}

/// The calls a recap takes, one at a time: a digest of each slice of the
/// period that holds anything, then the recap, which reads the digests and
/// [rest] as it is.
///
/// - A day is one call.
/// - A week is two: Monday to Thursday (from its first weekday) as a
///   digest, then the recap reads it with the other three days.
/// - A month is a digest each of 1–7, 8–14, 15–21, 22–28 and 29 to the
///   end, then the recap: 6 calls, and 5 for February, whose 29th goes
///   with the 22nd.
/// - A year is a digest a month, then the recap: 13 calls, less each month
///   whose own recap gives its digest, so 1 after twelve monthly recaps.
///
/// A slice with nothing in it is no call at all.
class RecapPlan {
  RecapPlan._(this.material, this.slices, this.rest);

  factory RecapPlan.of(
    RecapMaterial material, {
    RecapPiece? Function(RecapSlice slice)? ready,
  }) {
    final period = material.period;
    final first = period.first;
    DateTime day(int index) =>
        DateTime(first.year, first.month, first.day + index);
    final ranges = switch (period.kind) {
      RecapKind.day => const <(DateTime, DateTime)>[],
      RecapKind.week => [(first, day(3))],
      RecapKind.month => [
        for (var start = 0; start < 28; start += 7)
          (
            day(start),
            start == 21 && period.days < 30 ? period.last : day(start + 6),
          ),
        if (period.days >= 30) (day(28), period.last),
      ],
      RecapKind.year => [
        for (var month = 1; month <= 12; month++)
          (DateTime(first.year, month), DateTime(first.year, month + 1, 0)),
      ],
    };
    final slices = <RecapSlice>[];
    for (final (from, to) in ranges) {
      final items = material.within(from, to);
      final slice = RecapSlice(
        period.kind,
        from,
        to,
        '${_iso(from)}/${_iso(to)}/${recapFingerprint(items)}',
      );
      final made = ready?.call(slice);
      if (items.isEmpty && made == null) continue;
      slices.add(RecapSlice(period.kind, from, to, slice.key, ready: made));
    }
    return RecapPlan._(
      material,
      List.unmodifiable(slices),
      switch (period.kind) {
        RecapKind.day => (first, period.last),
        RecapKind.week => (day(4), period.last),
        RecapKind.month || RecapKind.year => null,
      },
    );
  }

  final RecapMaterial material;
  final List<RecapSlice> slices;
  final (DateTime, DateTime)? rest;

  RecapPeriod get period => material.period;

  /// Every part, made already or not: "Part 2 of 6".
  int get parts => slices.length + 1;

  /// The calls still to make, which is what Kapy AI Cloud counts: one
  /// answer each, and a call that fails is handed back.
  int get calls => slices.where((slice) => slice.ready == null).length + 1;

  /// What it costs of the month's Kapy AI answers: nothing through the
  /// person's own account or on the device.
  int credits(KapyModel model) => model.kind == KapyModelKind.cloud ? calls : 0;
}

String _iso(DateTime day) =>
    '${day.year}-${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';
