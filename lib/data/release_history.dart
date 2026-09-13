import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'local_store.dart';

/// One release, as the changelog describes it.
@immutable
class ReleaseNote {
  const ReleaseNote({
    required this.version,
    required this.date,
    required this.summary,
    required this.changes,
    this.highlights = const [],
  });

  final String version;

  /// The day it published, as the changelog writes it: `2026-09-10`. Kept as
  /// text rather than a [DateTime] because it is a day, not an instant — the
  /// pane formats it, and a date it cannot read it simply leaves out.
  final String date;

  /// One line on what the release is for.
  final String summary;

  /// What changed, in the order the changelog puts it.
  final List<String> changes;

  /// Short, scan-friendly lines for an update prompt.
  ///
  /// Older releases predate this field, so update surfaces fall back to the
  /// complete notes. The full history always uses [changes].
  final List<String> highlights;

  List<String> get updateHighlights =>
      highlights.isEmpty ? changes : highlights;

  /// An entry the site would not recognise is dropped rather than drawn
  /// half-empty: a release with no version cannot be matched against the
  /// running build, and one with no changes has nothing to say.
  static ReleaseNote? fromJson(Object? decoded) {
    if (decoded is! Map) return null;
    final version = decoded['version'];
    if (version is! String || version.trim().isEmpty) return null;
    final changes = decoded['changes'];
    if (changes is! List) return null;
    final lines = [
      for (final change in changes)
        if (change is String && change.trim().isNotEmpty) change,
    ];
    if (lines.isEmpty) return null;
    final highlights = decoded['highlights'];
    final shortLines = [
      if (highlights is List)
        for (final highlight in highlights)
          if (highlight is String && highlight.trim().isNotEmpty) highlight,
    ];
    final date = decoded['date'];
    final summary = decoded['summary'];
    return ReleaseNote(
      version: version,
      date: date is String ? date : '',
      summary: summary is String ? summary : '',
      changes: lines,
      highlights: shortLines,
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'date': date,
    'summary': summary,
    'changes': changes,
    'highlights': highlights,
  };
}

/// Every release of Kapy Notes, newest first, for the list of them in
/// Settings › Updates.
///
/// Read from the site rather than shipped in the app, and for one reason: the
/// changelog is written once, in the website's `src/data/releases.ts`, and
/// /changelog.json is that same array served as data. A copy inside the app
/// would be a third one after the page and the Play listing, and the only one
/// nobody would remember to correct. It also means an installed build can
/// describe the releases that came after it, which is the version of this
/// list somebody deciding whether to update actually wants.
///
/// The cost is a request, so it is only ever made for somebody looking at the
/// pane, at most once a day, and the answer is kept. What is on disk is what
/// the pane draws while the network is asked, and what it goes on drawing if
/// the answer never comes.
class ReleaseHistory extends ChangeNotifier {
  static const String _key = 'changelog.v1';

  /// Served by the website, from the file the changelog page renders.
  static final Uri url = Uri.parse('https://kapynotes.com/changelog.json');

  /// How long a fetched list is trusted without asking again. A release is
  /// the only thing that changes it, and the update check itself only looks
  /// once a day.
  static const Duration staleAfter = Duration(hours: 24);

  static const Duration timeout = Duration(seconds: 8);

  final LocalStore _store;
  http.Client? _client;

  List<ReleaseNote> _releases = const [];
  DateTime? _fetchedAt;
  bool _loading = false;
  bool _failed = false;
  bool _cacheLoaded = false;
  bool _disposed = false;

  ReleaseHistory(this._store, {http.Client? client}) : _client = client;

  /// Newest first, exactly as the changelog orders them. Empty until the
  /// first answer — from disk or from the network — has arrived.
  List<ReleaseNote> get releases => _releases;

  bool get isLoading => _loading;

  /// Whether the last attempt to read the changelog came back with nothing.
  /// Only worth saying while there is also nothing to show.
  bool get hasFailed => _failed;

  /// Reads the cache, and asks the site only if what is on disk is missing or
  /// a day old. Safe to call on every build of the pane: the work happens
  /// once.
  Future<void> load() async {
    if (_disposed) return;
    _loadCache();
    final fetchedAt = _fetchedAt;
    final fresh =
        _releases.isNotEmpty &&
        fetchedAt != null &&
        DateTime.now().isBefore(fetchedAt.add(staleAfter));
    if (fresh) return;
    await refresh();
  }

  /// Makes sure the history contains the release an updater is about to
  /// install.
  ///
  /// A fresh cache can still predate a release discovered by the update
  /// manifest. In that case [load] would trust the cache for the rest of the
  /// day and the update pane would describe an older build. The updater only
  /// needs one exact entry, so keep an existing match and refresh otherwise.
  Future<void> loadForVersion(String version) async {
    if (_disposed) return;
    _loadCache();
    if (_releases.any((release) => release.version == version)) return;
    await refresh();
  }

  /// Asks the site now, whatever is on disk. The button somebody presses when
  /// the list came back empty.
  Future<void> refresh() async {
    if (_disposed || _loading) return;
    _loadCache();
    _loading = true;
    _failed = false;
    notifyListeners();
    try {
      final client = _client ??= http.Client();
      final response = await client.get(url).timeout(timeout);
      if (_disposed) return;
      if (response.statusCode != 200) {
        debugPrint(
          'KapyNotes: the changelog returned HTTP ${response.statusCode}',
        );
        _failed = true;
        return;
      }
      final releases = _releasesIn(jsonDecode(utf8.decode(response.bodyBytes)));
      // An answer nothing could be read out of is a failure, not an empty
      // changelog: the list already on disk is better than the blank one this
      // would otherwise leave behind.
      if (releases.isEmpty) {
        debugPrint('KapyNotes: the changelog was malformed');
        _failed = true;
        return;
      }
      _releases = releases;
      _fetchedAt = DateTime.now();
      _store.put(_key, {
        'fetchedAt': _fetchedAt!.toIso8601String(),
        'releases': [for (final release in releases) release.toJson()],
      });
    } catch (error) {
      // Offline, timed out, or answered with something else entirely. The
      // pane says so and offers to ask again.
      debugPrint('KapyNotes: could not read the changelog: $error');
      _failed = true;
    } finally {
      _loading = false;
      if (!_disposed) notifyListeners();
    }
  }

  void _loadCache() {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    final cached = _store.read<Map<String, Object?>>(_key);
    final releases = _releasesIn(cached);
    if (releases.isEmpty) return;
    _releases = releases;
    final fetchedAt = cached?['fetchedAt'];
    _fetchedAt = fetchedAt is String ? DateTime.tryParse(fetchedAt) : null;
  }

  /// The list inside either the endpoint's answer or the cache, which are
  /// written in the same shape on purpose: one reader, one set of rules about
  /// what counts as an entry.
  static List<ReleaseNote> _releasesIn(Object? decoded) {
    if (decoded is! Map) return const [];
    final entries = decoded['releases'];
    if (entries is! List) return const [];
    return [for (final entry in entries) ?ReleaseNote.fromJson(entry)];
  }

  @override
  void dispose() {
    _disposed = true;
    _client?.close();
    super.dispose();
  }
}
