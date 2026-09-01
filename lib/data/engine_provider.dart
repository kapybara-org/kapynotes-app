import 'package:flutter/foundation.dart';

import '../calc/engine.dart';
import '../calc/highlight.dart';
import 'rates.dart';

/// Keeps a [CalcEngine] in step with the current exchange rates.
///
/// The engine's unit table is immutable, so a rate change means building a
/// new engine rather than patching one — which also guarantees no line is
/// ever evaluated against a half-updated currency table.
class EngineProvider extends ChangeNotifier {
  final RatesRepository _rates;

  late CalcEngine _engine;
  late Highlighter _highlighter;
  int _ratesRevision = -1;

  EngineProvider(this._rates) {
    _rebuild();
    _rates.addListener(_onRatesChanged);
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

  void _rebuild() {
    _engine = CalcEngine(ratesPerUsd: _rates.rates);
    _highlighter = Highlighter(_engine.registry);
  }

  @override
  void dispose() {
    _rates.removeListener(_onRatesChanged);
    super.dispose();
  }
}
