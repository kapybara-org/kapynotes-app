import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../data/blob_store.dart';
import 'local_models.dart';
import 'runtime_pack.dart';

/// Where a model is in its life on this device.
enum LocalModelStatus {
  /// Never fetched, or fetched and thrown away. Some of it may still be on
  /// disk as a part file; that is a detail of resuming, not a state the user
  /// is shown.
  absent,

  /// The engine's own code is being fetched, ahead of the model. Only ever
  /// seen on a phone, where the runtimes are a Play module rather than part
  /// of the app — see [RuntimePack].
  fetchingRuntime,

  /// Bytes are moving.
  downloading,

  /// All the bytes are here and are being checked against their hashes. A
  /// separate state because it takes seconds on a model this size and a
  /// progress bar stuck at 100% looks like a hang.
  verifying,

  /// Complete, checked, and on disk.
  ready,

  /// The last attempt did not finish. [LocalModelState.error] says why.
  failed,
}

/// What the settings card draws.
@immutable
class LocalModelState {
  const LocalModelState({
    required this.status,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });

  final LocalModelStatus status;

  /// Includes bytes already on disk from an interrupted attempt, so resuming
  /// a download does not restart the bar at zero.
  final int receivedBytes;
  final int totalBytes;
  final String? error;

  bool get isBusy =>
      status == LocalModelStatus.fetchingRuntime ||
      status == LocalModelStatus.downloading ||
      status == LocalModelStatus.verifying;

  /// 0 to 1, and 0 rather than NaN before the total is known.
  double get progress {
    if (totalBytes <= 0) return 0;
    final ratio = receivedBytes / totalBytes;
    return ratio.clamp(0.0, 1.0);
  }
}

/// The models this device has downloaded, and the machinery to get more.
///
/// Owned above the settings dialog rather than inside it, because a 670 MB
/// download must not be cancelled by closing the window that started it.
/// Nothing here touches the disk until [refresh] is called, so a user who
/// never opens the voice pane pays nothing at launch for it existing.
///
/// Deliberately no engine: this fetches and keeps model files, and knows
/// nothing about what reads them — a speech recogniser and a language model
/// are the same problem to it, which is why [DownloadableModel] is all it
/// asks for. Whatever runs them finds them through [directoryFor].
class LocalModelStore extends ChangeNotifier {
  LocalModelStore({
    this.catalogue = const <DownloadableModel>[
      ...localSpeechModels,
      ...localSummaryModels,
    ],
    Directory? directory,
    http.Client? client,
    RuntimePack runtime = const BundledRuntimePack(),
  }) : _directory = directory,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _runtime = runtime;

  final List<DownloadableModel> catalogue;

  /// The native code every model here needs, where the app does not carry
  /// it. Fetched before the first model and released after the last.
  final RuntimePack _runtime;

  final http.Client _client;
  final bool _ownsClient;

  Directory? _directory;
  Future<Directory>? _resolving;

  final Map<String, LocalModelState> _states = {};

  /// The download running for a model, if one is. Held so that removing a
  /// model can wait for its download to actually stop before deleting the
  /// files out from under it, and so a second press cannot start a second
  /// download of the same thing.
  final Map<String, Future<void>> _running = {};

  /// Set while a download should stop. Read between chunks, which is as often
  /// as cancelling can be honoured without abandoning the connection mid-write
  /// and leaving a part file whose length lies.
  final Set<String> _cancelling = {};

  /// Rebuilding the pane on every chunk would spend more time laying out than
  /// downloading. Progress is a smooth quantity; five updates a second is
  /// past what anyone can read.
  static const Duration _progressInterval = Duration(milliseconds: 200);

  /// A connection that goes quiet for this long is dead, whatever the socket
  /// thinks. There is no overall deadline: the whole point of a resumable
  /// download is that it may legitimately take an hour.
  static const Duration _stallTimeout = Duration(seconds: 60);

  DateTime _lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _disposed = false;

  /// What the model is doing, without having to look at the disk.
  ///
  /// Answers [LocalModelStatus.absent] for a model nobody has asked about
  /// yet, which is the right answer until [refresh] says otherwise and keeps
  /// the first build of the pane synchronous.
  LocalModelState stateOf(DownloadableModel model) =>
      _states[model.id] ??
      LocalModelState(status: LocalModelStatus.absent, totalBytes: model.bytes);

  Future<Directory> _root() async {
    final existing = _directory;
    if (existing != null) return existing;
    return _resolving ??= () async {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/speech-models');
      await dir.create(recursive: true);
      _directory = dir;
      return dir;
    }();
  }

  /// Where [model]'s files live, whether or not they are there yet.
  ///
  /// The recogniser will want this; so does anyone debugging a download.
  Future<Directory> directoryFor(DownloadableModel model) async {
    final root = await _root();
    return Directory('${root.path}/${model.id}');
  }

  /// Reads the disk and works out what is already here.
  ///
  /// Cheap by construction: it compares recorded hashes and file lengths
  /// rather than re-hashing, because re-hashing 670 MB every time the pane
  /// opens would be a visible freeze in exchange for catching a case — a
  /// file corrupted in place after being verified — that the recogniser will
  /// fail on loudly anyway.
  Future<void> refresh() async {
    try {
      await _scan();
    } catch (_) {
      // A store that cannot reach its own directory — no plugin registrar in
      // a widget test, a sandbox that said no — has nothing installed, which
      // is exactly what the cards should show. A real problem surfaces on the
      // download, with the reason attached, rather than out of a scan nobody
      // asked for.
    }
  }

  Future<void> _scan() async {
    // A model whose files are all here but whose engine is not cannot run,
    // and "ready" would be a lie the first transcript exposed. It reads as
    // absent with every byte received, which the card offers as Resume — and
    // resuming is exactly what fetches the engine.
    final runtimeHere = await _runtime.isInstalled();
    for (final model in catalogue) {
      // A download in flight already knows more about itself than the disk
      // does; asking now would report its part files as a broken install.
      if (_running.containsKey(model.id)) continue;
      final installed = runtimeHere && await _isInstalled(model);
      final received = installed ? model.bytes : await _bytesOnDisk(model);
      // Reading the disk takes long enough for someone to have pressed
      // Download in the middle of it, and what they started outranks what
      // this found.
      if (_running.containsKey(model.id)) continue;
      _set(
        model,
        LocalModelState(
          status: installed ? LocalModelStatus.ready : LocalModelStatus.absent,
          receivedBytes: received,
          totalBytes: model.bytes,
        ),
      );
    }
  }

  /// Fetches every file of [model], resuming anything already part-downloaded.
  ///
  /// Safe to call on a model that is already here: it verifies and returns.
  /// Pressing Download twice joins the download already running rather than
  /// starting a second one over the same files.
  Future<void> download(DownloadableModel model) {
    final running = _running[model.id];
    if (running != null) return running;
    // A block body, not an arrow: `remove` hands back the very future being
    // chained here, and `whenComplete` waits on whatever its callback
    // returns — so an arrow would make this future wait for itself.
    final job = _download(model).whenComplete(() {
      _running.remove(model.id);
    });
    _running[model.id] = job;
    return job;
  }

  Future<void> _download(DownloadableModel model) async {
    _cancelling.remove(model.id);
    _lastProgressAt = DateTime.fromMillisecondsSinceEpoch(0);

    final total = model.bytes;
    var carried = 0;

    try {
      // The engine first, where it is not in the app. Its stage owns the
      // card until it is done, so the initial state is one or the other.
      if (!await _runtime.isInstalled()) {
        await _fetchRuntime(model, total);
        if (_cancelling.contains(model.id)) {
          _set(
            model,
            LocalModelState(
              status: LocalModelStatus.absent,
              receivedBytes: await _bytesOnDisk(model),
              totalBytes: total,
            ),
          );
          return;
        }
      } else {
        _set(
          model,
          LocalModelState(
            status: LocalModelStatus.downloading,
            receivedBytes: await _bytesOnDisk(model),
            totalBytes: total,
          ),
        );
      }

      final dir = await directoryFor(model);
      await dir.create(recursive: true);

      for (final file in model.files) {
        final target = File('${dir.path}/${file.name}');

        // Already here and the right length: this is a resumed download
        // finishing the files it had not reached yet.
        if (await _looksComplete(target, file)) {
          carried += file.bytes;
          _progress(model, carried, total);
          continue;
        }

        await _fetch(model, file, target, carried, total);
        if (_cancelling.contains(model.id)) {
          _set(
            model,
            LocalModelState(
              status: LocalModelStatus.absent,
              receivedBytes: await _bytesOnDisk(model),
              totalBytes: total,
            ),
          );
          return;
        }
        carried += file.bytes;
        _progress(model, carried, total);
      }

      _set(
        model,
        LocalModelState(
          status: LocalModelStatus.verifying,
          receivedBytes: total,
          totalBytes: total,
        ),
      );

      final installed = <String, String>{};
      for (final file in model.files) {
        final target = File('${dir.path}/${file.name}');
        final digest = await BlobStore.hashFile(target);
        if (digest != file.sha256) {
          // Do not keep bytes that failed their own checksum: a retry has to
          // start clean, and a half-right model is worse than none.
          await _quietlyDelete(target);
          throw const _ModelError(
            'The download did not match its checksum. Try again.',
          );
        }
        installed[file.name] = digest;
      }
      await _writeMarker(dir, installed);

      _set(
        model,
        LocalModelState(
          status: LocalModelStatus.ready,
          receivedBytes: total,
          totalBytes: total,
        ),
      );
    } catch (error) {
      if (_disposed) return;
      _set(
        model,
        LocalModelState(
          status: LocalModelStatus.failed,
          receivedBytes: await _bytesOnDisk(model),
          totalBytes: total,
          error: _messageFor(error),
        ),
      );
    }
  }

  /// The engine before the model: Play's module, reported on the same card
  /// as its own stage so a phone user sees why the bar has not reached the
  /// model yet.
  ///
  /// A cancelled fetch is not a failure. The pack throws when Play stops,
  /// and the caller reads [_cancelling] to tell the two apart.
  Future<void> _fetchRuntime(DownloadableModel model, int total) async {
    _set(
      model,
      LocalModelState(
        status: LocalModelStatus.fetchingRuntime,
        receivedBytes: 0,
        totalBytes: 0,
      ),
    );
    try {
      await _runtime.install(
        onProgress: (received, packTotal) {
          if (_disposed || !_running.containsKey(model.id)) return;
          final now = DateTime.now();
          if (now.difference(_lastProgressAt) < _progressInterval &&
              received < packTotal) {
            return;
          }
          _lastProgressAt = now;
          _set(
            model,
            LocalModelState(
              status: LocalModelStatus.fetchingRuntime,
              receivedBytes: received,
              totalBytes: packTotal,
            ),
          );
        },
      );
    } on RuntimePackException {
      if (_cancelling.contains(model.id)) return;
      rethrow;
    }
    if (_cancelling.contains(model.id)) return;
    _set(
      model,
      LocalModelState(
        status: LocalModelStatus.downloading,
        receivedBytes: await _bytesOnDisk(model),
        totalBytes: total,
      ),
    );
  }

  /// Stops a download between chunks, keeping what has arrived so that
  /// starting again resumes rather than refetches.
  void cancel(DownloadableModel model) {
    if (!_running.containsKey(model.id)) return;
    _cancelling.add(model.id);
    if (stateOf(model).status == LocalModelStatus.fetchingRuntime) {
      unawaited(_runtime.cancel());
    }
  }

  /// Throws the model away, part files and all.
  Future<void> remove(DownloadableModel model) async {
    cancel(model);
    // Deleting files a download is still writing into would leave debris the
    // next attempt mistakes for progress, so let it stop first. Its failures
    // are its own — they are already on the card — and must not come out of
    // a press on Remove.
    await _running[model.id]?.catchError((Object _) {});
    final dir = await directoryFor(model);
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // A file held open by something else. The state below still reflects
      // the disk, because that is what the next refresh will read.
    }
    _set(
      model,
      LocalModelState(
        status: LocalModelStatus.absent,
        receivedBytes: await _bytesOnDisk(model),
        totalBytes: model.bytes,
      ),
    );
    // The engine is only worth its space while something needs it. Play
    // takes the module back on its own schedule; a model downloaded in the
    // meantime simply finds it still there.
    if (!await _anyInstalled()) await _runtime.remove();
  }

  Future<bool> _anyInstalled() async {
    for (final other in catalogue) {
      if (_running.containsKey(other.id)) return true;
      if (await _isInstalled(other)) return true;
    }
    return false;
  }

  /// One file, resuming from whatever is already in its part file.
  Future<void> _fetch(
    DownloadableModel model,
    LocalModelFile file,
    File target,
    int carried,
    int total,
  ) async {
    final part = File('${target.path}.part');
    var have = 0;
    if (await part.exists()) {
      have = await part.length();
      // More than the file is: someone else's leftovers under our name.
      if (have >= file.bytes) {
        have = 0;
        await _quietlyDelete(part);
      }
    }

    final request = http.Request('GET', Uri.parse(file.url));
    if (have > 0) request.headers['range'] = 'bytes=$have-';

    final response = await _client.send(request).timeout(_stallTimeout);

    // A server that ignores the range header answers 200 with the whole file,
    // and appending that to what we have would produce a file of the right
    // length made of the wrong bytes. Start over instead.
    if (response.statusCode == HttpStatus.ok) {
      have = 0;
    } else if (response.statusCode != HttpStatus.partialContent) {
      throw _ModelError(
        'The download server answered ${response.statusCode}. Try again later.',
      );
    }

    final sink = part.openWrite(
      mode: have > 0 ? FileMode.writeOnlyAppend : FileMode.writeOnly,
    );
    var written = have;
    try {
      await for (final chunk in response.stream.timeout(_stallTimeout)) {
        if (_cancelling.contains(model.id)) break;
        sink.add(chunk);
        written += chunk.length;
        _progress(model, carried + written, total);
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    if (_cancelling.contains(model.id)) return;

    final length = await part.length();
    if (length != file.bytes) {
      // Truncated: the connection closed early. Keeping the part file lets
      // the next attempt pick up where this one stopped.
      throw const _ModelError('The connection dropped. Try again.');
    }
    await part.rename(target.path);
  }

  /// Whether every file is present, the right length, and recorded as having
  /// been verified when it landed.
  Future<bool> _isInstalled(DownloadableModel model) async {
    final dir = await directoryFor(model);
    final marker = await _readMarker(dir);
    if (marker == null) return false;
    for (final file in model.files) {
      if (marker[file.name] != file.sha256) return false;
      if (!await _looksComplete(File('${dir.path}/${file.name}'), file)) {
        return false;
      }
    }
    return true;
  }

  Future<bool> _looksComplete(File target, LocalModelFile file) async {
    if (!await target.exists()) return false;
    return await target.length() == file.bytes;
  }

  /// How much of the model is on disk, finished files and part files alike.
  Future<int> _bytesOnDisk(DownloadableModel model) async {
    final dir = await directoryFor(model);
    if (!await dir.exists()) return 0;
    var bytes = 0;
    for (final file in model.files) {
      for (final path in [
        '${dir.path}/${file.name}',
        '${dir.path}/${file.name}.part',
      ]) {
        final candidate = File(path);
        if (await candidate.exists()) {
          // Never claim more of a file than the file is, or a stale part file
          // could push the bar past the end.
          final length = await candidate.length();
          bytes += length > file.bytes ? file.bytes : length;
          break;
        }
      }
    }
    return bytes;
  }

  static const String _markerName = 'installed.json';

  Future<Map<String, String>?> _readMarker(Directory dir) async {
    final marker = File('${dir.path}/$_markerName');
    try {
      if (!await marker.exists()) return null;
      final decoded = jsonDecode(await marker.readAsString());
      if (decoded is! Map) return null;
      final files = decoded['files'];
      if (files is! Map) return null;
      return {
        for (final entry in files.entries) '${entry.key}': '${entry.value}',
      };
    } catch (_) {
      // Unreadable or half-written: treat it as not installed, which costs a
      // download and cannot cost correctness.
      return null;
    }
  }

  Future<void> _writeMarker(Directory dir, Map<String, String> files) async {
    final marker = File('${dir.path}/$_markerName');
    await marker.writeAsString(jsonEncode({'version': 1, 'files': files}));
  }

  Future<void> _quietlyDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  void _progress(DownloadableModel model, int received, int total) {
    final now = DateTime.now();
    final current = stateOf(model);
    final next = LocalModelState(
      status: current.status,
      receivedBytes: received,
      totalBytes: total,
    );
    _states[model.id] = next;
    if (now.difference(_lastProgressAt) < _progressInterval) return;
    _lastProgressAt = now;
    if (!_disposed) notifyListeners();
  }

  void _set(DownloadableModel model, LocalModelState state) {
    _states[model.id] = state;
    // A state change is the thing the pane must not miss, so it skips the
    // throttle — and resets it, so the next progress tick is a full interval
    // away rather than immediate.
    _lastProgressAt = DateTime.now();
    if (!_disposed) notifyListeners();
  }

  static String _messageFor(Object error) {
    if (error is _ModelError) return error.message;
    if (error is RuntimePackException) return error.message;
    if (error is TimeoutException) {
      return 'The download stopped responding. Try again.';
    }
    if (error is SocketException || error is http.ClientException) {
      return 'Could not reach the download server. Check your connection.';
    }
    if (error is FileSystemException) {
      // Overwhelmingly a full disk, and saying so is more use than the OS
      // message, which names a path the user has never seen.
      return 'Could not write the model to disk. Check you have room for it.';
    }
    return 'The download did not finish. Try again.';
  }

  @override
  void dispose() {
    _disposed = true;
    for (final model in catalogue) {
      _cancelling.add(model.id);
    }
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

/// A failure with something worth showing the user attached.
class _ModelError implements Exception {
  const _ModelError(this.message);
  final String message;

  @override
  String toString() => message;
}
