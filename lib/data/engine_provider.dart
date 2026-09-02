import 'package:flutter/foundation.dart';

import '../calc/engine.dart';
import '../calc/format.dart';
import '../calc/highlight.dart';
import 'layout_prefs.dart';
import 'rates.dart';

/// Keeps a [CalcEngine] in step with the current exchange rates and the
/// number system the user has chosen.
///
/// The engine is immutable in both, so either change means building a new
/// one rather than patching it — which also guarantees no line is ever
/// evaluated against a half-updated currency table.
class EngineProvider extends ChangeNotifier {
  final RatesRepository _rates;
  final LayoutPrefs _prefs;

  late CalcEngine _engine;
  late Highlighter _highlighter;
  int _ratesRevision = -1;
  late DigitGrouping _grouping;

  EngineProvider(this._rates, this._prefs) {
    _grouping = _prefs.digitGrouping;
    _rebuild();
    _rates.addListener(_onRatesChanged);
    _prefs.addListener(_onPrefsChanged);
  }

  CalcEngine get engine => _engine;
  Highlighter get highlighter => _highlighter;

  void _onRatesChanged() {
    final revision = _rates.snapshot?.fetchedAt.millisecondsSinceEpoch ?? -1;
    if (revision == _ratesRevision) return;
    _ratesRevision = revision;
    _rebuild();
    notifyListeners();
  }

  /// [LayoutPrefs] also notifies for panel drags, so only a grouping change
  /// is worth rebuilding for.
  void _onPrefsChanged() {
    final grouping = _prefs.digitGrouping;
    if (grouping == _grouping) return;
    _grouping = grouping;
    _rebuild();
    notifyListeners();
  }

  void _rebuild() {
    _engine = CalcEngine(ratesPerUsd: _rates.rates, grouping: _grouping);
    _highlighter = Highlighter(_engine.registry);
  }

  @override
  void dispose() {
    _rates.removeListener(_onRatesChanged);
    _prefs.removeListener(_onPrefsChanged);
    super.dispose();
  }
}
