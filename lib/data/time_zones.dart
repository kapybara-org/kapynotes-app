import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// Bundled IANA time-zone rules used for note timestamps.
///
/// A null zone means the device's current zone. Explicit zones are converted
/// from the original instant, so daylight-saving transitions stay accurate.
class AppTimeZones {
  const AppTimeZones._();

  static bool _initialized = false;
  static List<String>? _locationIds;

  static void _ensureInitialized() {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    _initialized = true;
  }

  /// Canonical region-style locations suitable for a user-facing picker.
  /// Legacy aliases and implementation-only fixed-offset zones are omitted.
  static List<String> get locationIds {
    _ensureInitialized();
    final cached = _locationIds;
    if (cached != null) return cached;

    final ids =
        <String>[
          'UTC',
          ...tz.timeZoneDatabase.locations.keys.where(_isPickerLocation),
        ]..sort((a, b) {
          if (a == 'UTC') return -1;
          if (b == 'UTC') return 1;
          return a.compareTo(b);
        });
    return _locationIds = List.unmodifiable(ids);
  }

  /// Returns a valid stored location, or null to follow the device.
  static String? normalize(Object? value) {
    if (value is! String) return null;
    final id = value.trim();
    if (id.isEmpty) return null;
    _ensureInitialized();
    if (id == 'UTC' || tz.timeZoneDatabase.locations.containsKey(id)) {
      return id;
    }
    return null;
  }

  /// Shows [instant] in [locationId], preserving the represented instant.
  static DateTime convert(DateTime instant, String? locationId) {
    final id = normalize(locationId);
    if (id == null) return instant.toLocal();
    final location = id == 'UTC' ? tz.UTC : tz.getLocation(id);
    return tz.TZDateTime.from(instant, location);
  }

  static String displayName(String? locationId) {
    final id = normalize(locationId);
    if (id == null) return 'System time zone';
    return id.replaceAll('_', ' ');
  }

  /// A compact offset for the picker, evaluated at [instant] so DST is shown.
  static String offsetLabel(String? locationId, {DateTime? instant}) {
    final offset = convert(
      instant ?? DateTime.now(),
      locationId,
    ).timeZoneOffset;
    final minutes = offset.inMinutes;
    final sign = minutes < 0 ? '-' : '+';
    final absolute = minutes.abs();
    final hours = (absolute ~/ 60).toString().padLeft(2, '0');
    final remainder = (absolute % 60).toString().padLeft(2, '0');
    return 'UTC$sign$hours:$remainder';
  }

  static bool matches(String? locationId, String query) {
    final normalizedQuery = query.trim().toLowerCase();
    if (normalizedQuery.isEmpty) return true;
    final searchable = displayName(
      locationId,
    ).replaceAll('/', ' ').toLowerCase();
    return searchable.contains(normalizedQuery);
  }

  static bool _isPickerLocation(String id) {
    const regions = <String>{
      'Africa',
      'America',
      'Antarctica',
      'Arctic',
      'Asia',
      'Atlantic',
      'Australia',
      'Europe',
      'Indian',
      'Pacific',
    };
    final slash = id.indexOf('/');
    return slash > 0 && regions.contains(id.substring(0, slash));
  }
}
