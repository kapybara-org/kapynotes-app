import 'dart:async';
import 'dart:convert';

import 'package:auto_updater/auto_updater.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../core/platform.dart';
import 'local_store.dart';

/// A release newer than the running build, as advertised by the manifest.
class AvailableUpdate {
  const AvailableUpdate({
    required this.version,
    required this.build,
    required this.notesUrl,
  });

  final String version;
  final int build;
  final String notesUrl;

  static AvailableUpdate? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    final version = decoded['version'];
    final build = decoded['build'];
    if (version is! String || version.isEmpty) return null;
    if (build is! int) return null;
    final notes = decoded['notesUrl'];
    return AvailableUpdate(
      version: version,
      build: build,
      notesUrl: notes is String ? notes : '',
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'build': build,
    'notesUrl': notesUrl,
  };
}

/// Watches for new desktop releases without ever downloading one uninvited.
///
/// The check is deliberately ours rather than Sparkle's. Sparkle's own
/// background check runs against [SPUStandardUserDriver] and puts its update
/// panel on screen the moment it finds something, which is exactly the
/// interruption this is meant to avoid. So the quiet half — a few hundred
/// bytes of JSON, once a day — is done here, and the framework is only woken
/// up when someone actually clicks. Nothing is fetched, staged, or installed
/// before that click.
///
/// Failures are silent by design. A missed check is not worth a toast, and an
/// unreachable manifest must never look like "you are up to date".
class UpdateChecker extends ChangeNotifier with UpdaterListener {
  static const String _key = 'updates.v1';

  /// Small, mutable, and short-cached — unlike the immutable artifacts it
  /// points at. Sparkle and WinSparkle read the XML; this reads the JSON.
  /// Both are written by the same release step from the same values.
  static final Uri manifestUrl = Uri.parse(
    'https://dl.kapynotes.com/latest.json',
  );
  /// One feed per platform, because the two frameworks compare against
  /// different fields — Sparkle against `CFBundleVersion`, WinSparkle against
  /// the `.rc`'s `ProductVersion` string — and carry different signature
  /// attributes over different enclosures. A shared feed could only be right
  /// for one of them.
  static String get feedUrl => AppPlatform.isMacOS
      ? 'https://dl.kapynotes.com/appcast-macos.xml'
      : 'https://dl.kapynotes.com/appcast-windows.xml';

  static const Duration checkEvery = Duration(hours: 24);
  static const Duration retryAfter = Duration(hours: 2);
  static const Duration timeout = Duration(seconds: 8);

  final LocalStore _store;
  http.Client? _client;

  AvailableUpdate? _available;
  DateTime? _lastChecked;
  PackageInfo? _packageInfo;
  bool _checking = false;
  bool _disposed = false;
  bool _cacheLoaded = false;
  bool _installing = false;
  bool _listening = false;
  Timer? _timer;

  UpdateChecker(this._store, {http.Client? client, PackageInfo? packageInfo})
    : _client = client,
      _packageInfo = packageInfo;

  /// The newer release, or null when the running build is the latest known.
  AvailableUpdate? get available => _available;
  bool get hasUpdate => _available != null;
  bool get isChecking => _checking;

  /// True while the handoff to the native updater is in flight. It clears as
  /// soon as Sparkle owns the screen — latching it until the install finished
  /// would leave the button dead forever if the user simply closed the panel,
  /// which emits no event we could recover from.
  bool get isInstalling => _installing;

  String get currentVersion => _packageInfo?.version ?? '';

  DateTime? get lastChecked => _lastChecked;

  /// Publishes the last known result without touching the network, so the
  /// settings row is already correct the first time it is opened.
  void loadCache() {
    if (_disposed || _cacheLoaded) return;
    _cacheLoaded = true;
    final cached = _store.read<Map<String, Object?>>(_key);
    _available = AvailableUpdate.fromJson(cached?['available']);
    final checkedAt = cached?['checkedAt'];
    _lastChecked = checkedAt is String ? DateTime.tryParse(checkedAt) : null;
    notifyListeners();
  }

  bool get _isDue {
    final checked = _lastChecked;
    if (checked == null) return true;
    return !DateTime.now().isBefore(checked.add(checkEvery));
  }

  /// Checks at most once a day. Called on launch and on every resume.
  Future<void> checkIfDue() async {
    if (_disposed) return;
    loadCache();
    if (_isDue) {
      await check();
    } else {
      _scheduleNextCheck();
    }
  }

  Future<void> check() async {
    if (_disposed || _checking || !AppPlatform.hasAutoUpdate) return;
    _timer?.cancel();
    _checking = true;
    notifyListeners();

    try {
      final info = _packageInfo ??= await PackageInfo.fromPlatform();
      if (_disposed) return;

      final client = _client ??= http.Client();
      final response = await client.get(manifestUrl).timeout(timeout);
      if (_disposed) return;
      if (response.statusCode != 200) {
        debugPrint(
          'KapyNotes: update manifest returned HTTP ${response.statusCode}',
        );
        return;
      }

      final latest = AvailableUpdate.fromJson(jsonDecode(response.body));
      if (latest == null) {
        debugPrint('KapyNotes: update manifest was malformed');
        return;
      }

      // Only a check that actually reached the manifest may clear a pending
      // update or move the clock forward. A network failure leaves both the
      // cached result and the retry schedule alone.
      _available = _isNewerThanInstalled(latest, info) ? latest : null;
      _lastChecked = DateTime.now();
      _store.put(_key, {
        'available': _available?.toJson(),
        'checkedAt': _lastChecked!.toIso8601String(),
      });
    } catch (error) {
      // Offline, timed out, or malformed. The next resume tries again.
      debugPrint('KapyNotes: update check failed: $error');
    } finally {
      _checking = false;
      if (!_disposed) {
        notifyListeners();
        _scheduleNextCheck();
      }
    }
  }

  /// Hands over to Sparkle on macOS and WinSparkle on Windows.
  ///
  /// This is the first moment anything is downloaded. From here the native
  /// framework owns the flow: it verifies the release signature against the
  /// public key built into the app, installs, and relaunches.
  Future<void> startInstall() async {
    if (_disposed || _installing || !AppPlatform.hasAutoUpdate) return;
    _installing = true;
    notifyListeners();
    try {
      // Registered here rather than in the constructor so the plugin's event
      // channel is never touched by an app whose user has not asked for an
      // update.
      if (!_listening) {
        _listening = true;
        autoUpdater.addListener(this);
      }
      await autoUpdater.setFeedURL(feedUrl);
      // Sparkle's own scheduler would surface its panel unprompted; the only
      // check that should ever show native UI is this one.
      await autoUpdater.setScheduledCheckInterval(0);
      await autoUpdater.checkForUpdates();
    } catch (error) {
      debugPrint('KapyNotes: could not start the updater: $error');
    } finally {
      _installing = false;
      if (!_disposed) notifyListeners();
    }
  }

  // UpdaterListener. Only two of these change anything; the rest exist so the
  // native flow is traceable when an update goes wrong on someone's machine.

  @override
  void onUpdaterError(UpdaterError? error) {
    debugPrint('KapyNotes: the updater failed: ${error?.message}');
  }

  @override
  void onUpdaterCheckingForUpdate(Appcast? appcast) {}

  @override
  void onUpdaterUpdateAvailable(AppcastItem? item) {}

  /// The feed disagreed with the manifest — most likely the two were read
  /// either side of a release, or the appcast has not propagated yet. Clear
  /// the notice rather than leave a dot that opens a panel saying otherwise.
  @override
  void onUpdaterUpdateNotAvailable(UpdaterError? error) {
    if (_disposed || _available == null) return;
    _available = null;
    _store.put(_key, {
      'available': null,
      'checkedAt': (_lastChecked ?? DateTime.now()).toIso8601String(),
    });
    notifyListeners();
  }

  @override
  void onUpdaterUpdateDownloaded(AppcastItem? item) {}

  @override
  void onUpdaterBeforeQuitForUpdate(AppcastItem? item) {
    // The install replaces the bundle the moment this returns, so anything
    // still sitting in the debounced write queue has to reach disk now.
    unawaited(_store.flush());
  }

  void _scheduleNextCheck() {
    if (_disposed || AppPlatform.isFlutterTest) return;
    _timer?.cancel();
    final checked = _lastChecked;
    final untilDue = checked?.add(checkEvery).difference(DateTime.now());
    final delay = untilDue != null && untilDue > Duration.zero
        ? untilDue
        : retryAfter;
    _timer = Timer(delay, () => unawaited(checkIfDue()));
  }

  /// Compares the release triple first and the build number only as a
  /// tie-break, so a release that forgets to bump `+build` is still offered.
  static bool _isNewerThanInstalled(AvailableUpdate latest, PackageInfo info) {
    final comparison = _compareVersions(latest.version, info.version);
    if (comparison != 0) return comparison > 0;
    return latest.build > (int.tryParse(info.buildNumber) ?? 0);
  }

  static int _compareVersions(String a, String b) {
    final left = _parts(a);
    final right = _parts(b);
    for (var i = 0; i < 3; i++) {
      final diff = left[i].compareTo(right[i]);
      if (diff != 0) return diff;
    }
    return 0;
  }

  static List<int> _parts(String version) {
    final numbers = version
        .split('.')
        .map((part) => int.tryParse(part.trim()) ?? 0)
        .toList();
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return numbers;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _client?.close();
    if (_listening) autoUpdater.removeListener(this);
    super.dispose();
  }
}
