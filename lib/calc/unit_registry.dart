import 'unit.dart';

/// Every unit the engine knows about, indexed by exact and folded aliases.
///
/// Currencies are layered on top of the static table at build time because
/// their conversion factors come from live exchange rates.
class UnitRegistry {
  final Map<String, List<UnitDef>> _byAlias = {};
  final Map<String, List<UnitDef>> _byExactAlias = {};
  final Set<String> _currencyCodes = {};

  UnitRegistry({Map<String, double> ratesPerUsd = const {}}) {
    for (final def in _standardUnits) {
      _add(def);
    }
    _registerCurrencies(ratesPerUsd);
  }

  Set<String> get currencyCodes => _currencyCodes;

  bool get hasCurrencies => _currencyCodes.isNotEmpty;

  /// Resolves a written unit name, tolerating case and simple plurals.
  UnitDef? lookup(String raw, {Dimension? dimension}) {
    final exact = _pick(_byExactAlias[raw], dimension);
    if (exact != null) return exact;

    // Compact SI symbols are case-sensitive (`MB` is megabytes, `Mb` is
    // megabits, and `mB` is millibytes). Long names remain forgiving below.
    final compact = _compactSiUnit(raw, dimension);
    if (compact != null) return compact;

    final key = raw.toLowerCase();
    final candidates = <String>[key];
    // "kilometers", "hours", "dollars" — retry without the plural suffix.
    // Try the ordinary trailing `s` first. `miles` must resolve to `mile`,
    // not the distinct print unit `mil`; irregular `-es` forms fall through.
    if (key.endsWith('s') && key.length > 2) {
      candidates.add(key.substring(0, key.length - 1));
    }
    if (key.endsWith('es') && key.length > 3) {
      candidates.add(key.substring(0, key.length - 2));
    }
    for (final candidate in candidates) {
      final direct = _pick(_byAlias[candidate], dimension);
      if (direct != null) return direct;
      final derived = _siUnit(candidate, dimension);
      if (derived != null) return derived;
    }
    return null;
  }

  /// Derives long-form SI units such as `picometer`, `milliwatt` and
  /// `microgram` from a small set of metric bases. Written prefixes are
  /// unambiguous and case-free; compact symbols that rely on case (`mW` vs
  /// `MW`) remain explicit registry entries.
  UnitDef? _siUnit(String key, Dimension? dimension) {
    for (final prefix in _siPrefixes) {
      if (!key.startsWith(prefix.name) || key.length == prefix.name.length) {
        continue;
      }
      final base = _pick(
        _byAlias[key.substring(prefix.name.length)],
        dimension,
      );
      if (base == null || !_siBaseSymbols.contains(base.symbol)) continue;
      return UnitDef(
        symbol: '${prefix.symbol}${base.symbol}',
        dimension: base.dimension,
        factor: base.factor * prefix.factor,
        aliases: [key],
        category: base.category,
        offset: base.offset,
      );
    }
    return null;
  }

  UnitDef? _compactSiUnit(String raw, Dimension? dimension) {
    for (final prefix in _compactSiPrefixes) {
      if (!raw.startsWith(prefix.symbol) ||
          raw.length == prefix.symbol.length) {
        continue;
      }
      final base = _pick(
        _byExactAlias[raw.substring(prefix.symbol.length)],
        dimension,
      );
      if (base == null || !_siBaseSymbols.contains(base.symbol)) continue;
      return UnitDef(
        symbol: '${prefix.symbol}${base.symbol}',
        dimension: base.dimension,
        factor: base.factor * prefix.factor,
        aliases: [raw],
        category: base.category,
        offset: base.offset,
      );
    }
    return null;
  }

  static UnitDef? _pick(List<UnitDef>? candidates, Dimension? dimension) {
    if (candidates == null || candidates.isEmpty) return null;
    if (dimension == null) return candidates.last;
    for (final candidate in candidates.reversed) {
      if (candidate.dimension == dimension) return candidate;
    }
    return null;
  }

  bool isUnit(String raw) => lookup(raw) != null;

  bool isCurrency(String raw) => lookup(raw)?.isCurrency ?? false;

  void _registerCurrencies(Map<String, double> ratesPerUsd) {
    // USD is the pivot: every rate is "units of X per 1 USD", so one X is
    // worth 1/rate USD.
    final usd = UnitDef(
      symbol: 'USD',
      dimension: Dimension.base(Dimension.currency),
      factor: 1,
      aliases: const ['usd', r'$', 'dollar', 'dollars', 'usdollar'],
      category: 'currency',
    );
    _add(usd);
    _currencyCodes.add('USD');

    ratesPerUsd.forEach((code, rate) {
      final upper = code.toUpperCase();
      if (upper == 'USD') return;
      if (!rate.isFinite || rate <= 0) return;
      final def = UnitDef(
        symbol: upper,
        dimension: Dimension.base(Dimension.currency),
        factor: 1 / rate,
        aliases: [upper.toLowerCase(), ..._symbolsFor(upper)],
        category: 'currency',
      );
      _add(def);
      _currencyCodes.add(upper);
    });
  }

  void _add(UnitDef def) {
    for (final alias in def.aliases) {
      (_byExactAlias[alias] ??= []).add(def);
      (_byAlias[alias.toLowerCase()] ??= []).add(def);
    }
  }

  /// Currency symbols are only bound when the matching rate is available, so
  /// `€` never silently resolves to nothing mid-expression.
  static List<String> _symbolsFor(String code) {
    switch (code) {
      case 'EUR':
        return const ['€', 'euro', 'euros'];
      case 'GBP':
        return const ['£', 'pound', 'pounds', 'quid'];
      case 'JPY':
        return const ['¥', 'yen'];
      case 'INR':
        return const ['₹', 'rs', 'rupee', 'rupees'];
      case 'KRW':
        return const ['₩', 'won'];
      case 'RUB':
        return const ['₽', 'ruble', 'rubles'];
      case 'TRY':
        return const ['₺', 'lira'];
      case 'NGN':
        return const ['₦', 'naira'];
      case 'PHP':
        return const ['₱', 'peso', 'pesos'];
      case 'VND':
        return const ['₫', 'dong'];
      case 'THB':
        return const ['฿', 'baht'];
      case 'ILS':
        return const ['₪', 'shekel', 'shekels'];
      case 'UAH':
        return const ['₴', 'hryvnia'];
      case 'BRL':
        return const ['real', 'reais'];
      case 'CHF':
        return const ['franc', 'francs'];
      case 'CNY':
        return const ['yuan', 'rmb'];
      default:
        return const [];
    }
  }
}

const Set<String> _siBaseSymbols = {
  'm',
  'g',
  's',
  'B',
  'b',
  'L',
  'J',
  'W',
  'N',
  'Pa',
  'Hz',
  'K',
};

const List<({String name, String symbol, double factor})> _siPrefixes = [
  (name: 'yotta', symbol: 'Y', factor: 1e24),
  (name: 'zetta', symbol: 'Z', factor: 1e21),
  (name: 'exa', symbol: 'E', factor: 1e18),
  (name: 'peta', symbol: 'P', factor: 1e15),
  (name: 'tera', symbol: 'T', factor: 1e12),
  (name: 'giga', symbol: 'G', factor: 1e9),
  (name: 'mega', symbol: 'M', factor: 1e6),
  (name: 'kilo', symbol: 'k', factor: 1e3),
  (name: 'hecto', symbol: 'h', factor: 1e2),
  (name: 'deca', symbol: 'da', factor: 1e1),
  (name: 'deci', symbol: 'd', factor: 1e-1),
  (name: 'centi', symbol: 'c', factor: 1e-2),
  (name: 'milli', symbol: 'm', factor: 1e-3),
  (name: 'micro', symbol: 'µ', factor: 1e-6),
  (name: 'nano', symbol: 'n', factor: 1e-9),
  (name: 'pico', symbol: 'p', factor: 1e-12),
  (name: 'femto', symbol: 'f', factor: 1e-15),
  (name: 'atto', symbol: 'a', factor: 1e-18),
];

const List<({String symbol, double factor})> _compactSiPrefixes = [
  (symbol: 'da', factor: 1e1),
  (symbol: 'Y', factor: 1e24),
  (symbol: 'Z', factor: 1e21),
  (symbol: 'E', factor: 1e18),
  (symbol: 'P', factor: 1e15),
  (symbol: 'T', factor: 1e12),
  (symbol: 'G', factor: 1e9),
  (symbol: 'M', factor: 1e6),
  (symbol: 'k', factor: 1e3),
  (symbol: 'h', factor: 1e2),
  (symbol: 'd', factor: 1e-1),
  (symbol: 'c', factor: 1e-2),
  (symbol: 'm', factor: 1e-3),
  (symbol: 'u', factor: 1e-6),
  (symbol: 'µ', factor: 1e-6),
  (symbol: 'n', factor: 1e-9),
  (symbol: 'p', factor: 1e-12),
  (symbol: 'f', factor: 1e-15),
  (symbol: 'a', factor: 1e-18),
];

const double _pi = 3.1415926535897932;

Dimension _dim(Map<int, int> parts) => Dimension.of(parts);

final Dimension _length = Dimension.base(Dimension.length);
final Dimension _mass = Dimension.base(Dimension.mass);
final Dimension _time = Dimension.base(Dimension.time);
final Dimension _temp = Dimension.base(Dimension.temperature);
final Dimension _data = Dimension.base(Dimension.data);
final Dimension _angle = Dimension.base(Dimension.angle);
final Dimension _area = Dimension.base(Dimension.length, 2);
final Dimension _volume = Dimension.base(Dimension.length, 3);
final Dimension _speed = _dim({Dimension.length: 1, Dimension.time: -1});
final Dimension _force = _dim({
  Dimension.mass: 1,
  Dimension.length: 1,
  Dimension.time: -2,
});
final Dimension _energy = _dim({
  Dimension.mass: 1,
  Dimension.length: 2,
  Dimension.time: -2,
});
final Dimension _power = _dim({
  Dimension.mass: 1,
  Dimension.length: 2,
  Dimension.time: -3,
});
final Dimension _pressure = _dim({
  Dimension.mass: 1,
  Dimension.length: -1,
  Dimension.time: -2,
});
final Dimension _frequency = _dim({Dimension.time: -1});

UnitDef _u(
  String symbol,
  Dimension dimension,
  double factor,
  List<String> aliases,
  String category, {
  double offset = 0,
}) => UnitDef(
  symbol: symbol,
  dimension: dimension,
  factor: factor,
  aliases: aliases,
  category: category,
  offset: offset,
);

/// Base units per dimension: metre, kilogram, second, kelvin, byte, radian.
final List<UnitDef> _standardUnits = [
  // ── Length ────────────────────────────────────────────────────────────
  _u('m', _length, 1, ['m', 'meter', 'metre'], 'length'),
  _u('km', _length, 1000, ['km', 'kilometer', 'kilometre'], 'length'),
  _u('cm', _length, 0.01, ['cm', 'centimeter', 'centimetre'], 'length'),
  _u('mm', _length, 0.001, ['mm', 'millimeter', 'millimetre'], 'length'),
  _u('µm', _length, 1e-6, ['um', 'µm', 'micrometer', 'micron'], 'length'),
  _u('nm', _length, 1e-9, ['nm', 'nanometer'], 'length'),
  _u('mi', _length, 1609.344, ['mi', 'mile'], 'length'),
  _u('yd', _length, 0.9144, ['yd', 'yard'], 'length'),
  _u('ft', _length, 0.3048, ['ft', 'foot', 'feet'], 'length'),
  _u('in', _length, 0.0254, ['in', 'inch', 'inche'], 'length'),
  _u('nmi', _length, 1852, ['nmi', 'nauticalmile'], 'length'),
  _u('ly', _length, 9.4607304725808e15, ['ly', 'lightyear'], 'length'),
  _u('au', _length, 1.495978707e11, ['au', 'astronomicalunit'], 'length'),
  _u('mil', _length, 0.0000254, ['mil', 'thou'], 'length'),
  _u('line', _length, 0.0254 / 6, ['line'], 'length'),
  _u('hand', _length, 0.1016, ['hand'], 'length'),
  _u('rod', _length, 5.0292, ['rod', 'perch', 'pole'], 'length'),
  _u('chain', _length, 20.1168, ['chain'], 'length'),
  _u('fur', _length, 201.168, ['fur', 'furlong'], 'length'),
  _u('cable', _length, 185.2, ['cable', 'cablelength'], 'length'),
  _u('league', _length, 4828.032, ['league'], 'length'),
  // CSS/print defaults: 96 px per inch, 72 pt per inch, 16 px per em.
  _u('px', _length, 0.0254 / 96, ['px', 'pixel'], 'length'),
  _u('pt', _length, 0.0254 / 72, ['pt', 'point'], 'length'),
  _u('pc', _length, 0.0254 / 6, ['pc', 'pica'], 'length'),
  _u('em', _length, 16 * 0.0254 / 96, ['em'], 'length'),

  // ── Mass ──────────────────────────────────────────────────────────────
  _u('kg', _mass, 1, ['kg', 'kilogram', 'kilo'], 'mass'),
  _u('g', _mass, 0.001, ['g', 'gram', 'gramme'], 'mass'),
  _u('mg', _mass, 1e-6, ['mg', 'milligram'], 'mass'),
  _u('t', _mass, 1000, ['t', 'tonne', 'metricton'], 'mass'),
  _u('lb', _mass, 0.45359237, ['lb', 'lbs', 'pound', 'pounds'], 'mass'),
  _u('oz', _mass, 0.028349523125, ['oz', 'ounce'], 'mass'),
  _u('st', _mass, 6.35029318, ['st', 'stone'], 'mass'),
  _u('ton', _mass, 907.18474, ['ton', 'shortton'], 'mass'),
  _u('ct', _mass, 0.0002, ['ct', 'carat'], 'mass'),
  _u('q', _mass, 100, ['q', 'centner', 'quintal'], 'mass'),

  // ── Time ──────────────────────────────────────────────────────────────
  _u('s', _time, 1, ['s', 'sec', 'second'], 'time'),
  _u('ms', _time, 0.001, ['ms', 'millisecond'], 'time'),
  _u('µs', _time, 1e-6, ['us', 'µs', 'microsecond'], 'time'),
  _u('ns', _time, 1e-9, ['ns', 'nanosecond'], 'time'),
  _u('min', _time, 60, ['min', 'minute'], 'time'),
  _u('h', _time, 3600, ['h', 'hr', 'hour'], 'time'),
  _u('day', _time, 86400, ['day', 'd'], 'time'),
  _u('week', _time, 604800, ['week', 'wk'], 'time'),
  _u('month', _time, 2628000, ['month', 'mo'], 'time'),
  _u('year', _time, 31536000, ['year', 'yr'], 'time'),

  // ── Temperature ───────────────────────────────────────────────────────
  _u('K', _temp, 1, ['K', 'kelvin'], 'temperature'),
  _u(
    '°C',
    _temp,
    1,
    ['c', 'degc', 'celsius', 'centigrade', '°c'],
    'temperature',
    offset: 273.15,
  ),
  _u(
    '°F',
    _temp,
    5 / 9,
    ['f', 'degf', 'fahrenheit', '°f'],
    'temperature',
    offset: 255.3722222222222,
  ),

  // ── Area ──────────────────────────────────────────────────────────────
  _u('m²', _area, 1, ['m2', 'sqm', 'squaremeter', 'm^2'], 'area'),
  _u('km²', _area, 1e6, ['km2', 'sqkm', 'km^2'], 'area'),
  _u('cm²', _area, 1e-4, ['cm2', 'sqcm', 'cm^2'], 'area'),
  _u('ha', _area, 1e4, ['ha', 'hectare'], 'area'),
  _u('acre', _area, 4046.8564224, ['acre'], 'area'),
  _u('a', _area, 100, ['are'], 'area'),
  _u('ft²', _area, 0.09290304, ['sqft', 'ft2', 'squarefoot', 'ft^2'], 'area'),
  _u('mi²', _area, 2589988.110336, ['sqmi', 'mi2', 'mi^2'], 'area'),

  // ── Volume ────────────────────────────────────────────────────────────
  _u('L', _volume, 0.001, ['l', 'liter', 'litre'], 'volume'),
  _u('mL', _volume, 1e-6, ['ml', 'milliliter', 'millilitre'], 'volume'),
  _u('m³', _volume, 1, ['m3', 'cbm', 'cum', 'cubicmeter', 'm^3'], 'volume'),
  _u('gal', _volume, 0.003785411784, ['gal', 'gallon'], 'volume'),
  _u('qt', _volume, 0.000946352946, ['qt', 'quart'], 'volume'),
  _u('pt US', _volume, 0.000473176473, ['pint'], 'volume'),
  _u('cup', _volume, 0.0002365882365, ['cup'], 'volume'),
  _u('floz', _volume, 2.95735295625e-5, ['floz', 'fluidounce'], 'volume'),
  _u('tbsp', _volume, 1.47867647813e-5, ['tbsp', 'tablespoon'], 'volume'),
  _u('tsp', _volume, 4.92892159375e-6, ['tsp', 'teaspoon'], 'volume'),

  // ── Data ──────────────────────────────────────────────────────────────
  _u('B', _data, 1, ['B', 'byte'], 'data'),
  _u('b', _data, 0.125, ['b', 'bit'], 'data'),
  _u('kB', _data, 1e3, ['kB', 'kilobyte'], 'data'),
  _u('MB', _data, 1e6, ['MB', 'megabyte'], 'data'),
  _u('GB', _data, 1e9, ['GB', 'gigabyte'], 'data'),
  _u('TB', _data, 1e12, ['TB', 'terabyte'], 'data'),
  _u('PB', _data, 1e15, ['PB', 'petabyte'], 'data'),
  _u('KiB', _data, 1024, ['KiB', 'kibibyte'], 'data'),
  _u('MiB', _data, 1048576, ['MiB', 'mebibyte'], 'data'),
  _u('GiB', _data, 1073741824, ['GiB', 'gibibyte'], 'data'),
  _u('TiB', _data, 1099511627776, ['TiB', 'tebibyte'], 'data'),

  // ── Speed ─────────────────────────────────────────────────────────────
  _u('km/h', _speed, 1 / 3.6, ['kph', 'kmh', 'kmph'], 'speed'),
  _u('mph', _speed, 0.44704, ['mph'], 'speed'),
  _u('kn', _speed, 0.514444444444, ['kn', 'knot'], 'speed'),

  // ── Energy & power ────────────────────────────────────────────────────
  _u('J', _energy, 1, ['j', 'joule'], 'energy'),
  _u('kJ', _energy, 1000, ['kj', 'kilojoule'], 'energy'),
  _u('cal', _energy, 4.184, ['cal', 'calorie'], 'energy'),
  _u('kcal', _energy, 4184, ['kcal', 'kilocalorie'], 'energy'),
  _u('Wh', _energy, 3600, ['wh', 'watthour'], 'energy'),
  _u('kWh', _energy, 3.6e6, ['kwh', 'kilowatthour'], 'energy'),
  _u('W', _power, 1, ['w', 'watt'], 'power'),
  _u('kW', _power, 1000, ['kw', 'kilowatt'], 'power'),
  _u('MW', _power, 1e6, ['mw', 'megawatt'], 'power'),
  _u('hp', _power, 745.6998715823, ['hp', 'horsepower'], 'power'),

  // ── Force, pressure, frequency, angle ─────────────────────────────────
  _u('N', _force, 1, ['n', 'newton'], 'force'),
  _u('Pa', _pressure, 1, ['pa', 'pascal'], 'pressure'),
  _u('kPa', _pressure, 1000, ['kpa', 'kilopascal'], 'pressure'),
  _u('bar', _pressure, 1e5, ['bar'], 'pressure'),
  _u('psi', _pressure, 6894.757293168, ['psi'], 'pressure'),
  _u('atm', _pressure, 101325, ['atm', 'atmosphere'], 'pressure'),
  _u('Hz', _frequency, 1, ['hz', 'hertz'], 'frequency'),
  _u('kHz', _frequency, 1000, ['khz', 'kilohertz'], 'frequency'),
  _u('MHz', _frequency, 1e6, ['mhz', 'megahertz'], 'frequency'),
  _u('GHz', _frequency, 1e9, ['ghz', 'gigahertz'], 'frequency'),
  _u('rad', _angle, 1, ['rad', 'radian'], 'angle'),
  _u('°', _angle, _pi / 180, ['deg', 'degree', '°'], 'angle'),
];
