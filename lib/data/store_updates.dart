import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../core/platform.dart';
import '../core/system_region.dart';
import 'local_store.dart';
import 'release_history.dart';

/// The newest Kapy Notes the App Store or Google Play offers this phone, as
/// the store itself answered.
@immutable
class StoreOffer {
  const StoreOffer({
    this.version = '',
    this.build,
    this.notes = '',
    this.released = '',
  });

  /// The version the App Store sells, such as `1.35.4`. Empty from Google
  /// Play, which names a release only by its [build].
  final String version;

  /// The version code Google Play offers. Null from the App Store.
  final int? build;

  /// What the App Store says the version brought, for when the changelog has
  /// no entry for it yet. Google Play says nothing.
  final String notes;

  /// When the App Store released [version], as it wrote it.
  final String released;

  /// What the store calls the release: its build on Google Play, its version
  /// on the App Store.
  String get name => build?.toString() ?? version;

  /// An answer that names no release this app can read is no answer.
  static StoreOffer? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    final version = decoded['version'];
    final build = decoded['build'];
    final notes = decoded['notes'];
    final released = decoded['released'];
    final offer = StoreOffer(
      version: version is String ? version.trim() : '',
      build: build is int && build > 0 ? build : null,
      notes: notes is String ? notes : '',
      released: released is String ? released : '',
    );
    if (offer.build == null && compareVersions(offer.version, '0') == null) {
      return null;
    }
    return offer;
  }

  Map<String, Object?> toJson() => {
    if (version.isNotEmpty) 'version': version,
    'build': ?build,
    if (notes.isNotEmpty) 'notes': notes,
    if (released.isNotEmpty) 'released': released,
  };
}

/// Orders two versions written like `1.35.4`, part by part as numbers, so
/// 1.35.10 comes after 1.35.9. Null when either is written any other way,
/// so that an answer nobody can read never counts as newer.
int? compareVersions(String a, String b) {
  final left = _versionParts(a);
  final right = _versionParts(b);
  if (left == null || right == null) return null;
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final diff = (i < left.length ? left[i] : 0).compareTo(
      i < right.length ? right[i] : 0,
    );
    if (diff != 0) return diff;
  }
  return 0;
}

final RegExp _versionPattern = RegExp(r'^\d{1,6}(\.\d{1,6}){0,3}$');

List<int>? _versionParts(String version) {
  final trimmed = version.trim();
  if (!_versionPattern.hasMatch(trimmed)) return null;
  return [for (final part in trimmed.split('.')) int.parse(part)];
}

/// Asks a store for the newest release it offers [installed], or null when
/// it would not say.
typedef StoreLookup = Future<StoreOffer?> Function(PackageInfo installed);

/// Whether the App Store or Google Play has a newer Kapy Notes than this
/// phone runs, and what each version brought.
///
/// A phone updates through its store, so only the store can say an update is
/// there. The changelog cannot: the site publishes a release before either
/// store has finished reviewing it, so the newest version it lists can be
/// days from reaching anyone. It only says what a version brought, once the
/// store has said that version is there.
///
/// Asking costs a request, so the store is asked only when Settings opens,
/// at most once a day whether or not it answers, and the answer is kept.
/// Anything that goes wrong (no network, a timeout, an answer nobody can
/// read, a copy Google Play did not install) leaves the last answer standing
/// and adds nothing. A check that got no answer must never look like an
/// update, nor like "you have the latest version".
class StoreUpdates extends ChangeNotifier {
  StoreUpdates(
    LocalStore store, {
    http.Client? client,
    StoreLookup? lookup,
    PackageInfo? packageInfo,
  }) : _store = store,
       _client = client,
       _lookup = lookup,
       _packageInfo = packageInfo,
       history = ReleaseHistory(store, client: client);

  static const String _key = 'storeUpdate.v1';
  static const String _seenKey = 'storeUpdate.seen.v1';

  static const Duration staleAfter = Duration(hours: 24);
  static const Duration timeout = Duration(seconds: 8);

  static const String bundleId = 'com.kapybara.kapynotes';

  /// Our listing, in the store's own app first, and on the web when that
  /// will not open.
  static final Uri appStoreApp = Uri.parse(
    'itms-apps://apps.apple.com/app/id6807810082',
  );
  static final Uri appStorePage = Uri.parse(
    'https://apps.apple.com/app/id6807810082',
  );
  static final Uri playApp = Uri.parse('market://details?id=$bundleId');
  static final Uri playPage = Uri.parse(
    'https://play.google.com/store/apps/details?id=$bundleId',
  );

  /// Google Play's answer, from the Play Core library behind it.
  static const MethodChannel playChannel = MethodChannel(
    'kapynotes/store_update',
  );

  /// What each release brought, from the changelog.
  final ReleaseHistory history;

  final LocalStore _store;
  final StoreLookup? _lookup;
  http.Client? _client;
  PackageInfo? _packageInfo;

  StoreOffer? _latest;

  /// When the store gave [_latest].
  DateTime? _answeredAt;

  /// When the store was last asked, whether or not it answered.
  DateTime? _askedAt;
  bool _cacheLoaded = false;
  bool _checking = false;
  bool _disposed = false;

  /// The version this phone runs, empty until it has been read.
  String get installedVersion => _packageInfo?.version.trim() ?? '';

  /// The store's last answer, whatever it says.
  StoreOffer? get latest => _latest;

  /// The newer release the store offers, or null.
  ///
  /// Measured against what this phone runs on every read rather than stored:
  /// the answer is kept on disk, and outlives the update it found.
  StoreOffer? get update => (_order ?? 0) > 0 ? _latest : null;

  /// Whether the store said, within the last day, that it has nothing newer
  /// than this phone runs. An older answer may be out of date by now.
  bool get isLatest => (_order ?? 1) <= 0 && _withinADay(_answeredAt);

  /// How the store's answer stands against what this phone runs: above zero
  /// when it is newer. Null without an answer, or when the two can't be
  /// compared, which says neither that there is an update nor that there
  /// isn't.
  int? get _order {
    final offer = _latest;
    final installed = installedVersion;
    if (offer == null || installed.isEmpty) return null;
    final build = offer.build;
    if (build == null) return compareVersions(offer.version, installed);
    final installedBuild = int.tryParse(_packageInfo?.buildNumber.trim() ?? '');
    return installedBuild == null ? null : build.compareTo(installedBuild);
  }

  static bool _withinADay(DateTime? at) {
    if (at == null) return false;
    final now = DateTime.now();
    return !now.isBefore(at) && now.isBefore(at.add(staleAfter));
  }

  /// Whether [update] waits for somebody who has not seen About & updates
  /// since it turned up.
  bool get updateUnseen {
    final offer = update;
    return offer != null && _store.read<String>(_seenKey) != offer.name;
  }

  /// About & updates has been seen with [update] on it.
  void markSeen() {
    final offer = update;
    if (_disposed || offer == null || !updateUnseen) return;
    _store.putNow(_seenKey, offer.name);
    notifyListeners();
  }

  /// The changelog's entry for [offer], once the changelog has it.
  ReleaseNote? noteFor(StoreOffer offer) {
    final build = offer.build;
    for (final release in history.releases) {
      if (build == null
          ? release.version == offer.version
          : release.build == build) {
        return release;
      }
    }
    return null;
  }

  /// The changelog's entry for the version this phone runs.
  ReleaseNote? get installedNote {
    final installed = installedVersion;
    for (final release in history.releases) {
      if (release.version == installed) return release;
    }
    return null;
  }

  /// Reads what this phone runs and the last answer, and asks the store again
  /// once it was last asked a day ago. Safe to call each time Settings opens:
  /// the store hears from this phone at most once a day, answer or not.
  Future<void> check() async {
    if (_disposed || _checking) return;
    _checking = true;
    try {
      final installed = _packageInfo ??= await PackageInfo.fromPlatform();
      _loadCache();
      if (_withinADay(_askedAt)) return;
      // Counted as the request goes out, so that a store that never answers
      // this phone is not asked again on every visit.
      _askedAt = DateTime.now();
      _save();
      final offer = await (_lookup ?? _ask)(installed).timeout(timeout);
      if (_disposed || offer == null) return;
      _latest = offer;
      _answeredAt = DateTime.now();
      _save();
    } catch (error) {
      debugPrint('KapyNotes: could not ask the store about updates: $error');
    } finally {
      _checking = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Reads the changelog for About & updates: the entry for the release the
  /// store offers when there is one, and the daily read otherwise.
  Future<void> loadNotes() {
    final offer = update;
    final build = offer?.build;
    if (offer == null) return history.load();
    return build == null
        ? history.loadForVersion(offer.version)
        : history.loadForBuild(build);
  }

  /// Written as soon as it changes rather than after the store's usual pause:
  /// a phone that asked must still know it did if the app closes right away.
  void _save() => _store.putNow(_key, {
    'askedAt': ?_askedAt?.toIso8601String(),
    'answeredAt': ?_answeredAt?.toIso8601String(),
    'offer': ?_latest?.toJson(),
  });

  void _loadCache() {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    final cached = _store.read<Map<String, Object?>>(_key);
    if (cached == null) return;
    _askedAt = _time(cached['askedAt']);
    final offer = StoreOffer.fromJson(cached['offer']);
    final answeredAt = _time(cached['answeredAt']);
    if (offer == null || answeredAt == null) return;
    _latest = offer;
    _answeredAt = answeredAt;
  }

  static DateTime? _time(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;

  Future<StoreOffer?> _ask(PackageInfo installed) {
    if (AppPlatform.isIOS) return _askAppStore();
    if (AppPlatform.isAndroid) return _askPlay(installed);
    return Future.value();
  }

  /// The App Store's lookup for our bundle id, in the storefront the phone's
  /// Region names. StoreKit can name the storefront itself, but only by a
  /// three-letter code the lookup refuses, and every storefront sells the
  /// same build, so the country only decides whose copy of the notes comes
  /// back. The request carries the bundle id and that country, nothing else.
  Future<StoreOffer?> _askAppStore() async {
    final country = await SystemRegion.read();
    final client = _client ??= http.Client();
    final response = await client.get(
      Uri.https('itunes.apple.com', '/lookup', {
        'bundleId': bundleId,
        'country': ?country?.toLowerCase(),
      }),
    );
    if (response.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    final results = decoded is Map ? decoded['results'] : null;
    if (results is! List) return null;
    for (final result in results) {
      if (result is! Map || result['bundleId'] != bundleId) continue;
      // A version this phone's iOS can't run is one the App Store won't
      // offer it, and the lookup can't say which older one it would.
      final minimum = result['minimumOsVersion'];
      if (minimum is String &&
          (compareVersions(minimum, _systemVersion) ?? 0) > 0) {
        return null;
      }
      return StoreOffer.fromJson({
        'version': result['version'],
        'notes': result['releaseNotes'],
        'released': result['currentVersionReleaseDate'],
      });
    }
    return null;
  }

  /// The version of the system this runs on, such as `18.2`, or empty.
  static String get _systemVersion =>
      RegExp(
        r'\d+(\.\d+)*',
      ).firstMatch(Platform.operatingSystemVersion)?.group(0) ??
      '';

  /// Google Play's in-app update check. Play answers only for a copy it
  /// installed: a sideloaded or debug build, or a phone with no Play, gets
  /// nothing back. Nothing newer comes back as the build this phone runs.
  Future<StoreOffer?> _askPlay(PackageInfo installed) async {
    final answer = await playChannel.invokeMapMethod<String, Object?>('check');
    final code = answer?['versionCode'];
    final build = int.tryParse(installed.buildNumber.trim());
    return switch (answer?['available']) {
      true when code is int && code > 0 => StoreOffer(build: code),
      false when build != null && build > 0 => StoreOffer(build: build),
      _ => null,
    };
  }

  @override
  void dispose() {
    _disposed = true;
    history.dispose();
    _client?.close();
    super.dispose();
  }
}
