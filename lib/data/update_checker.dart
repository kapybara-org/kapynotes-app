import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../core/platform.dart';
import 'local_store.dart';
import 'release_history.dart';
import 'update_installer.dart';
import 'update_manifest.dart';

export 'update_installer.dart' show StagedUpdate, UpdateInstaller;
export 'update_manifest.dart';

/// Keeps the desktop app current: a quiet daily check for a newer release,
/// a download in the background, and one click to install it and restart.
///
/// The check is our own rather than Sparkle's. Sparkle's scheduler puts its
/// update panel on screen the moment it finds something, which is exactly
/// the interruption this avoids. So the quiet half — a few hundred bytes of
/// JSON, once a day — is done here, and the platform's [UpdateInstaller] is
/// only asked to fetch a release once one is known to exist.
///
/// With "Download updates automatically" on, which it is unless someone turns
/// it off, that happens straight away and nothing is asked of the user until
/// the release is on disk and checked. Then the notes list offers "Update and
/// restart", and that one click is the whole of the update. Turned off, the
/// release waits for a Download button instead.
///
/// Failures are silent by design. A missed check is not worth a toast, and an
/// unreachable manifest must never look like "you are up to date".
class UpdateChecker extends ChangeNotifier {
  static const String _key = 'updates.v1';
  static const String _autoDownloadKey = 'updates.autoDownload.v1';

  /// Small, mutable, and short-cached — unlike the immutable artifacts it
  /// points at. Sparkle reads the macOS appcast; this reads the JSON, which
  /// also carries the Windows installer. All three are written by the same
  /// release step from the same values.
  static final Uri manifestUrl = Uri.parse(
    'https://dl.kapynotes.com/latest.json',
  );

  /// Sparkle's feed. Compared against `CFBundleVersion`, so it carries the
  /// build number where the manifest leads with the release triple.
  static const String feedUrl = 'https://dl.kapynotes.com/appcast-macos.xml';

  static const Duration checkEvery = Duration(hours: 24);
  static const Duration retryAfter = Duration(hours: 2);
  static const Duration timeout = Duration(seconds: 8);

  /// How long Sparkle gets to close the app after the click. Longer than any
  /// quit takes — the app root flushes notes on the way out — and short
  /// enough that a quit someone cancelled does not leave the button dead.
  static const Duration restartTimeout = Duration(seconds: 30);

  final LocalStore _store;
  final http.Client? _injectedClient;
  http.Client? _client;

  final UpdateInstaller? _injectedInstaller;
  UpdateInstaller? _installer;
  bool _installerMade = false;

  AvailableUpdate? _available;
  DateTime? _lastChecked;
  PackageInfo? _packageInfo;
  bool _checking = false;
  bool _disposed = false;
  bool _cacheLoaded = false;
  Timer? _timer;

  bool _downloading = false;
  double? _progress;
  StagedUpdate? _staged;
  String? _downloadError;
  DateTime? _retryDownloadAfter;
  Timer? _downloadRetry;
  bool _restored = false;
  bool _installing = false;
  Timer? _restartWatchdog;

  /// Invoked once the Windows installer is running, which needs this process
  /// gone before it can replace its files. The app root wires this to the
  /// same orderly quit the tray uses, which flushes notes and stops
  /// intercepting the close first. macOS needs nothing: Sparkle asks the app
  /// to quit the ordinary way, and the app root flushes on that too.
  Future<void> Function()? onBeforeQuitForUpdate;

  /// Every release, for the pane that lists them.
  ///
  /// Kept here because it answers the other half of the same question — this
  /// class says whether there is a newer build, and this says what any of
  /// them changed — and because it means the pane that shows both is handed
  /// one object rather than two.
  final ReleaseHistory history;

  UpdateChecker(
    LocalStore store, {
    http.Client? client,
    PackageInfo? packageInfo,
    UpdateInstaller? installer,
  }) : _store = store,
       _injectedClient = client,
       _client = client,
       _packageInfo = packageInfo,
       _injectedInstaller = installer,
       history = ReleaseHistory(store, client: client);

  /// Made on first use rather than in the constructor, so an app that never
  /// finds an update never wakes Sparkle, or touches its channel at all.
  UpdateInstaller? get _updater {
    if (!_installerMade) {
      _installerMade = true;
      _installer =
          _injectedInstaller ??
          UpdateInstaller.forCurrentPlatform(
            macFeedUrl: feedUrl,
            client: _injectedClient,
          );
    }
    return _installer;
  }

  /// The newer release, or null when the running build is the latest known.
  ///
  /// Measured against the installed build on every read, never trusted as
  /// stored. The cache outlives the app that wrote it: install the release it
  /// advertises and that same entry is still on disk afterwards, now naming a
  /// version already running. Nothing re-reads the manifest until the daily
  /// check comes due, so without this the notice survives the very update it
  /// asked for — and an entry written before an out-of-band install can name
  /// a version older than the one in the row above it.
  AvailableUpdate? get available {
    final cached = _available;
    final info = _packageInfo;
    if (cached == null || info == null) return cached;
    return _isNewerThanInstalled(cached.version, cached.build, info)
        ? cached
        : null;
  }

  bool get hasUpdate => available != null;
  bool get isChecking => _checking;

  /// Whether a release is downloading right now.
  bool get isDownloading => _downloading;

  /// How much of it has arrived, from 0 to 1, or null when the platform does
  /// not say. Sparkle never does; the Windows download always does.
  double? get downloadProgress => _downloading ? _progress : null;

  /// The downloaded, checked release that one click installs, or null.
  ///
  /// Judged against the installed build like [available], for the same
  /// reason: a release installed some other way overtakes it.
  StagedUpdate? get staged {
    final value = _staged;
    final info = _packageInfo;
    if (value == null || info == null) return value;
    return _isNewerThanInstalled(value.version, value.build, info)
        ? value
        : null;
  }

  bool get isReadyToInstall => staged != null;

  /// Why the last download or install did not happen, until the next try.
  String? get downloadError => _downloadError;

  /// True from the click on "Update and restart" until the process ends.
  bool get isInstalling => _installing;

  /// Whether a release is fetched as soon as it is found. On unless turned
  /// off: someone who wants to choose when to spend fifty megabytes can, and
  /// everybody else never has to think about it.
  bool get autoDownload => _store.read<bool>(_autoDownloadKey) ?? true;

  set autoDownload(bool value) {
    if (_disposed || value == autoDownload) return;
    _store.putNow(_autoDownloadKey, value);
    notifyListeners();
    // Turning it on is as good as asking for the release already found.
    if (value) unawaited(_settleDownloads());
  }

  String get currentVersion => _packageInfo?.version ?? '';

  String get currentBuild => _packageInfo?.buildNumber ?? '';

  DateTime? get lastChecked => _lastChecked;

  /// Publishes the last known result without touching the network, so the
  /// settings rows are already correct the first time they are opened.
  ///
  /// The installed version is read here too. It costs one platform call and
  /// no network, and without it a launch whose daily check is not yet due
  /// would leave the version row blank until tomorrow.
  void loadCache() {
    if (_disposed || _cacheLoaded) return;
    _cacheLoaded = true;
    unawaited(_ensurePackageInfo());
    final cached = _store.read<Map<String, Object?>>(_key);
    _available = AvailableUpdate.fromJson(cached?['available']);
    final checkedAt = cached?['checkedAt'];
    _lastChecked = checkedAt is String ? DateTime.tryParse(checkedAt) : null;
    _forgetOvertakenUpdate();
    notifyListeners();
  }

  /// Throws away a cached notice the running build has already caught up
  /// with, rather than leaving it on disk to be published again at the next
  /// launch. [available] hides it either way; this is what stops it coming
  /// back. Called once the installed version is known, which on a cold start
  /// is a moment after [loadCache] has read the file.
  ///
  /// The clock is not touched. That check did happen, and its verdict is
  /// still sound: a release that was not newer than the version installed
  /// then cannot be newer than the one installed now.
  void _forgetOvertakenUpdate() {
    final cached = _available;
    final info = _packageInfo;
    if (cached == null || info == null) return;
    if (_isNewerThanInstalled(cached.version, cached.build, info)) return;
    _available = null;
    _store.put(_key, {
      'available': null,
      'checkedAt': _lastChecked?.toIso8601String(),
    });
  }

  bool get _isDue {
    final checked = _lastChecked;
    if (checked == null) return true;
    return !DateTime.now().isBefore(checked.add(checkEvery));
  }

  /// Checks at most once a day, and picks up a download that is owed. Called
  /// on launch and on every resume.
  Future<void> checkIfDue() async {
    if (_disposed) return;
    loadCache();
    await _ensurePackageInfo();
    if (_disposed) return;
    if (_isDue) {
      await check();
    } else {
      _scheduleNextCheck();
      await _settleDownloads();
    }
  }

  Future<bool> check() async {
    if (_disposed || _checking || !AppPlatform.hasAutoUpdate) return false;
    _timer?.cancel();
    _checking = true;
    notifyListeners();

    var reached = false;
    try {
      final info = _packageInfo ??= await PackageInfo.fromPlatform();
      if (_disposed) return false;

      final client = _client ??= http.Client();
      final response = await client.get(manifestUrl).timeout(timeout);
      if (_disposed) return false;
      if (response.statusCode != 200) {
        debugPrint(
          'KapyNotes: update manifest returned HTTP ${response.statusCode}',
        );
        return false;
      }

      final latest = AvailableUpdate.fromJson(jsonDecode(response.body));
      if (latest == null) {
        debugPrint('KapyNotes: update manifest was malformed');
        return false;
      }

      // Only a check that actually reached the manifest may clear a pending
      // update or move the clock forward. A network failure leaves both the
      // cached result and the retry schedule alone.
      _available = _isNewerThanInstalled(latest.version, latest.build, info)
          ? latest
          : null;
      _lastChecked = DateTime.now();
      _store.put(_key, {
        'available': _available?.toJson(),
        'checkedAt': _lastChecked!.toIso8601String(),
      });
      reached = true;
      return true;
    } catch (error) {
      // Offline, timed out, or malformed. The next resume tries again.
      debugPrint('KapyNotes: update check failed: $error');
      return false;
    } finally {
      _checking = false;
      if (!_disposed) {
        notifyListeners();
        _scheduleNextCheck();
        // Not awaited: the button that asked for the check reports on the
        // check, and a download takes as long as it takes.
        if (reached) unawaited(_settleDownloads());
      }
    }
  }

  /// Brings the download in line with what is known: finds one an earlier
  /// run finished, tidies away ones that are no longer wanted, and starts the
  /// one that is owed, if downloads are automatic.
  Future<void> _settleDownloads() async {
    final installer = _updater;
    if (_disposed || installer == null) return;
    if (!_restored) {
      _restored = true;
      final update = available;
      if (update != null && _staged == null) {
        final restored = await installer.restore(update);
        if (_disposed) return;
        if (restored != null) {
          _staged = restored;
          notifyListeners();
        }
      }
      unawaited(installer.cleanUp(keep: available));
    }
    if (!autoDownload) return;
    final retry = _retryDownloadAfter;
    if (retry != null && DateTime.now().isBefore(retry)) return;
    // Started, not awaited: a check that finds a release is finished when it
    // has found it, however long the download then takes.
    unawaited(download());
  }

  /// Fetches the pending release so that one click installs it. Called by
  /// the automatic path and by the Download button; returns whether a
  /// release is ready afterwards.
  Future<bool> download() async {
    if (_disposed || _downloading || _installing) return false;
    final installer = _updater;
    var update = available;
    if (installer == null || update == null) return false;
    final ready = staged;
    if (ready != null && !_isAhead(update, ready)) return true;

    _downloading = true;
    _progress = null;
    _downloadError = null;
    notifyListeners();
    try {
      // The Windows download needs the installer's address and signature,
      // which a notice cached before the manifest carried them does not
      // have. Reading it again costs a few hundred bytes.
      if (AppPlatform.isWindows && update.windows == null) {
        await check();
        final fresh = available;
        if (_disposed || fresh == null) return false;
        update = fresh;
      }
      final result = await installer.download(
        update,
        onProgress: _reportProgress,
      );
      if (_disposed) return false;
      _staged = result;
      _retryDownloadAfter = null;
      _downloadRetry?.cancel();
      return true;
    } catch (error) {
      if (_disposed) return false;
      debugPrint('KapyNotes: the update download failed: $error');
      _downloadError = error is UpdateInstallerException
          ? error.message
          : 'Could not download the update';
      _retryDownloadAfter = DateTime.now().add(retryAfter);
      _scheduleDownloadRetry();
      return false;
    } finally {
      _downloading = false;
      _progress = null;
      if (!_disposed) notifyListeners();
    }
  }

  /// Rebuilds for every whole percent rather than every chunk: a fifty
  /// megabyte download arrives in about a thousand of them.
  void _reportProgress(double? fraction) {
    if (_disposed) return;
    final before = _progress;
    _progress = fraction;
    int percent(double? value) => value == null ? -1 : (value * 100).floor();
    if (percent(fraction) != percent(before)) notifyListeners();
  }

  /// The one click. Installs the downloaded release and restarts into it.
  ///
  /// Notes are written first, whatever happens next. On Windows the
  /// installer is started and then the app quits so it can replace the
  /// files; on macOS Sparkle quits the app itself and relaunches it.
  Future<bool> installAndRestart() async {
    if (_disposed || _installing) return false;
    final installer = _updater;
    if (installer == null || staged == null) return false;
    _installing = true;
    _downloadError = null;
    notifyListeners();
    try {
      await _store.flush();
      await installer.install();
      if (_disposed) return true;
      if (installer.quitsTheApp) {
        _restartWatchdog?.cancel();
        _restartWatchdog = Timer(restartTimeout, _restartTimedOut);
      } else {
        final quit = onBeforeQuitForUpdate;
        if (quit != null) await _quitForUpdate(quit);
      }
      return true;
    } catch (error) {
      if (_disposed) return false;
      debugPrint('KapyNotes: the update did not install: $error');
      _installing = false;
      _downloadError = error is UpdateInstallerException
          ? error.message
          : 'Could not install the update';
      // Whatever broke may have taken the download with it — a damaged file
      // is deleted, and Sparkle can lose its installer. Ask rather than
      // guess, so the row offers a button that can still work.
      final update = available;
      _staged = update == null ? null : await installer.restore(update);
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  void _restartTimedOut() {
    if (_disposed || !_installing) return;
    _installing = false;
    _downloadError = 'Kapy Notes did not restart';
    notifyListeners();
  }

  Future<void> _quitForUpdate(Future<void> Function() quit) async {
    try {
      await quit();
    } catch (error) {
      debugPrint('KapyNotes: could not quit cleanly for the update: $error');
      await _store.flush();
    }
  }

  /// Reads the running build's version once, and survives a platform channel
  /// that has nothing to say — a nameless version is a cosmetic loss, not a
  /// reason to fail a check.
  Future<void> _ensurePackageInfo() async {
    if (_disposed || _packageInfo != null) return;
    try {
      final info = await PackageInfo.fromPlatform();
      if (_disposed || _packageInfo != null) return;
      _packageInfo = info;
      // The first moment a cached notice can be judged against the build it
      // claims to be ahead of.
      _forgetOvertakenUpdate();
      notifyListeners();
    } catch (error) {
      debugPrint('KapyNotes: could not read the installed version: $error');
    }
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

  /// A failed download tries again by itself later. Resuming the app would
  /// get there too, but a window that stays in front all day never resumes.
  void _scheduleDownloadRetry() {
    if (_disposed || AppPlatform.isFlutterTest) return;
    _downloadRetry?.cancel();
    _downloadRetry = Timer(retryAfter, () => unawaited(_settleDownloads()));
  }

  /// Compares the release triple first and the build number only as a
  /// tie-break, so a release that forgets to bump `+build` is still offered.
  ///
  /// A build number the platform will not tell us is not a zero. Windows has
  /// nowhere to put one: package_info_plus recovers it by splitting the
  /// executable's `ProductVersion` on `+`, and `windows/runner/Runner.rc`
  /// writes the bare release triple there, because WinSparkle — which older
  /// builds still update with — reads that same string and mis-orders
  /// `1.9.0+10` against a feed's `1.9.0`. So every Windows build reports an
  /// empty build number, and reading that as 0 made the tie-break fire on
  /// every release: 1.9.0 installed, 1.9.0 advertised, 10 > 0, update
  /// available. Permanently, because the next daily check said it again.
  ///
  /// Where the build is unknown the triple is the whole answer. Nothing is
  /// lost by that on Windows: the installer is named after the triple, so a
  /// build-only bump would not have been a different download anyway.
  ///
  /// A version that is missing entirely is treated the same way. It means the
  /// running build could not be identified at all, and an app that does not
  /// know what it is must not claim to be behind.
  static bool _isNewerThanInstalled(
    String version,
    int? build,
    PackageInfo info,
  ) {
    if (info.version.trim().isEmpty) return false;
    final comparison = _compareVersions(version, info.version);
    if (comparison != 0) return comparison > 0;
    final installedBuild = int.tryParse(info.buildNumber.trim());
    return installedBuild != null && build != null && build > installedBuild;
  }

  /// Whether the manifest has moved past what is already downloaded, which
  /// is worth a second download: installing the older one would only lead
  /// to a third.
  static bool _isAhead(AvailableUpdate update, StagedUpdate staged) {
    final comparison = _compareVersions(update.version, staged.version);
    if (comparison != 0) return comparison > 0;
    final build = staged.build;
    return build != null && update.build > build;
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
    onBeforeQuitForUpdate = null;
    _timer?.cancel();
    _downloadRetry?.cancel();
    _restartWatchdog?.cancel();
    _installer?.dispose();
    history.dispose();
    _client?.close();
    super.dispose();
  }
}
