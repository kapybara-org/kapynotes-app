import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The bundled faces' licences, each shipped beside its font, for the
/// licences page to list under the family's name.
const fontLicenses = {
  'Geist Mono': 'assets/fonts/GeistMono-OFL.txt',
  'Inter': 'assets/fonts/Inter-OFL.txt',
  'Shantell Sans': 'assets/fonts/ShantellSans-OFL.txt',
};

void registerFontLicenses() => LicenseRegistry.addLicense(fontLicenseEntries);

Stream<LicenseEntry> fontLicenseEntries() async* {
  for (final MapEntry(key: family, value: asset) in fontLicenses.entries) {
    yield LicenseEntryWithLineBreaks([
      family,
    ], await rootBundle.loadString(asset));
  }
}
