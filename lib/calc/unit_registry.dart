import 'unit.dart';

/// Every unit the engine knows about, indexed by lowercase alias.
///
/// Currencies are layered on top of the static table at build time because
/// their conversion factors come from live exchange rates.
class UnitRegistry {
  final Map<String, UnitDef> _byAlias = {};
  final Set<String> _currencyCodes = {};

  UnitRegistry({Map<String, double> ratesPerUsd = const {}}) {
    for (final def in _standardUnits) {
      for (final alias in def.aliases) {
        _byAlias[alias] = def;
      }
    }
    _registerCurrencies(ratesPerUsd);
  }

  Set<String> get currencyCodes => _currencyCodes;

  bool get hasCurrencies => _currencyCodes.isNotEmpty;

  /// Resolves a written unit name, tolerating case and simple plurals.
  UnitDef? lookup(String raw) {
    final key = raw.toLowerCase();
    final direct = _byAlias[key];
    if (direct != null) return direct;
    // "kilometers", "hours", "dollars" — retry without the plural suffix.
    if (key.endsWith('es') && key.length > 3) {
      final trimmed = _byAlias[key.substring(0, key.length - 2)];
      if (trimmed != null) return trimmed;
    }
    if (key.endsWith('s') && key.length > 2) {
      return _byAlias[key.substring(0, key.length - 1)];
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
      _byAlias[alias] = def;
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

  // ── Mass ──────────────────────────────────────────────────────────────
  _u('kg', _mass, 1, ['kg', 'kilogram', 'kilo'], 'mass'),
  _u('g', _mass, 0.001, ['g', 'gram', 'gramme'], 'mass'),
  _u('mg', _mass, 1e-6, ['mg', 'milligram'], 'mass'),
  _u('t', _mass, 1000, ['t', 'tonne', 'metricton'], 'mass'),
  _u('lb', _mass, 0.45359237, ['lb', 'lbs', 'pound', 'pounds'], 'mass'),
  _u('oz', _mass, 0.028349523125, ['oz', 'ounce'], 'mass'),
  _u('st', _mass, 6.35029318, ['st', 'stone'], 'mass'),
  _u('ton', _mass, 907.18474, ['ton', 'shortton'], 'mass'),

  // ── Time ──────────────────────────────────────────────────────────────
  _u('s', _time, 1, ['s', 'sec', 'second'], 'time'),
  _u('ms', _time, 0.001, ['ms', 'millisecond'], 'time'),
  _u('µs', _time, 1e-6, ['us', 'µs', 'microsecond'], 'time'),
  _u('ns', _time, 1e-9, ['ns', 'nanosecond'], 'time'),
  _u('min', _time, 60, ['min', 'minute'], 'time'),
  _u('h', _time, 3600, ['h', 'hr', 'hour'], 'time'),
  _u('day', _time, 86400, ['day', 'd'], 'time'),
  _u('week', _time, 604800, ['week', 'wk'], 'time'),
  _u('month', _time, 2629800, ['month', 'mo'], 'time'),
  _u('year', _time, 31557600, ['year', 'yr'], 'time'),

  // ── Temperature ───────────────────────────────────────────────────────
  _u('K', _temp, 1, ['k', 'kelvin'], 'temperature'),
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
  _u('ft²', _area, 0.09290304, ['sqft', 'ft2', 'squarefoot', 'ft^2'], 'area'),
  _u('mi²', _area, 2589988.110336, ['sqmi', 'mi2', 'mi^2'], 'area'),

  // ── Volume ────────────────────────────────────────────────────────────
  _u('L', _volume, 0.001, ['l', 'liter', 'litre'], 'volume'),
  _u('mL', _volume, 1e-6, ['ml', 'milliliter', 'millilitre'], 'volume'),
  _u('m³', _volume, 1, ['m3', 'cubicmeter', 'm^3'], 'volume'),
  _u('gal', _volume, 0.003785411784, ['gal', 'gallon'], 'volume'),
  _u('qt', _volume, 0.000946352946, ['qt', 'quart'], 'volume'),
  _u('pt', _volume, 0.000473176473, ['pt', 'pint'], 'volume'),
  _u('cup', _volume, 0.0002365882365, ['cup'], 'volume'),
  _u('floz', _volume, 2.95735295625e-5, ['floz', 'fluidounce'], 'volume'),
  _u('tbsp', _volume, 1.47867647813e-5, ['tbsp', 'tablespoon'], 'volume'),
  _u('tsp', _volume, 4.92892159375e-6, ['tsp', 'teaspoon'], 'volume'),

  // ── Data ──────────────────────────────────────────────────────────────
  _u('B', _data, 1, ['b', 'byte'], 'data'),
  _u('bit', _data, 0.125, ['bit'], 'data'),
  _u('kB', _data, 1e3, ['kb', 'kilobyte'], 'data'),
  _u('MB', _data, 1e6, ['mb', 'megabyte'], 'data'),
  _u('GB', _data, 1e9, ['gb', 'gigabyte'], 'data'),
  _u('TB', _data, 1e12, ['tb', 'terabyte'], 'data'),
  _u('PB', _data, 1e15, ['pb', 'petabyte'], 'data'),
  _u('KiB', _data, 1024, ['kib', 'kibibyte'], 'data'),
  _u('MiB', _data, 1048576, ['mib', 'mebibyte'], 'data'),
  _u('GiB', _data, 1073741824, ['gib', 'gibibyte'], 'data'),
  _u('TiB', _data, 1099511627776, ['tib', 'tebibyte'], 'data'),

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
