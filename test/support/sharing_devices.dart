// The devices and harness the sharing tests share: an unlocked account on
// test/sync/fake_server.dart's server with everything the share sheet talks
// to, the sheet opened the way the app opens it, and the joining endpoints
// the fake server does not know. test/share_dialog_test.dart, the other
// sharing widget tests and the sharing integration tests import it, so none
// of them imports another test file.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/image_sync.dart';
import 'package:kapy_notes/sync/joining.dart';
import 'package:kapy_notes/sync/sharing.dart';
import 'package:kapy_notes/sync/space_keyring.dart';
import 'package:kapy_notes/sync/sync_service.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/sync/trust.dart';
import 'package:kapy_notes/ui/share_dialog.dart';
import 'package:material_ui/material_ui.dart';

import '../sync/fake_server.dart';

class MemoryStore extends LocalStore {
  MemoryStore() : super(fileName: 'share-dialog-test.json');
  @override
  Future<void> load() async {}
  @override
  Future<void> flush() async {}
  @override
  void put(String key, Object? value) => data[key] = value;
  @override
  void putNow(String key, Object? value) => data[key] = value;
}

/// One unlocked account against the fake server, with everything the share
/// sheet talks to.
class Device {
  Device(
    this.server, {
    required this.userId,
    required this.device,
    Directory? media,
  }) {
    server.seedBundle(userId);
    store = MemoryStore();
    notes = media == null
        ? NotesStore(store)
        : NotesStore(store, blobs: BlobStore(directory: media));
    final api = FakeApi(server, device: device, userId: userId);
    images = media == null
        ? null
        : ImageSync(api: api, store: notes.blobs, notes: notes);
    final vault = vaultFor(userId);
    keyring = SpaceKeyring(
      userId: userId,
      store: store,
      trust: TrustStore(store),
    );
    sync = SyncService(
      notes: notes,
      state: SyncState(store),
      api: api,
      keyring: keyring,
      docs: DocStore(MemoryDocStorage(), replica: device),
      images: images,
      vault: vault,
      sendDelay: const Duration(hours: 1),
    );
    sharing = Sharing(
      api: api,
      vault: vault,
      keyring: keyring,
      notes: notes,
      sync: sync,
      images: images,
    );
  }

  final FakeServer server;
  final String userId;
  final String device;
  late final MemoryStore store;
  late final NotesStore notes;
  late final SpaceKeyring keyring;
  late final SyncService sync;
  late final Sharing sharing;
  late final ImageSync? images;

  String get email => server.user(userId).email;

  Future<void> boot() async {
    await notes.load();
    await sync.syncNow();
  }

  bool _disposed = false;

  /// Idempotent: a test that has to tear a device down before the framework
  /// checks for stray timers disposes it early, and tearDown does it again.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    sharing.dispose();
    sync.dispose();
    images?.dispose();
  }
}

Widget harness(Widget child) => MaterialApp(
  theme: KapyTheme.dark(),
  debugShowCheckedModeBanner: false,
  home: Scaffold(body: child),
);

/// Opens the sheet through a button, the way the app reaches it.
Widget opener(Note note, Sharing sharing, {Billing? billing}) => harness(
  Builder(
    builder: (context) => TextButton(
      onPressed: () => showShareDialog(
        context,
        note: note,
        sharing: sharing,
        billing: billing,
      ),
      child: const Text('open'),
    ),
  ),
);

/// The joining endpoints the fake server does not know.
class FakeSend {
  final calls = <(String, String, Map<String, Object?>?)>[];

  bool sawPath(String method, String path) =>
      calls.any((call) => call.$1 == method && call.$2 == path);

  Object? Function(String method, String path, Map<String, Object?>? payload)?
  fallback;

  Future<Map<String, Object?>> call(
    String method,
    String path, {
    Map<String, Object?>? payload,
  }) async {
    calls.add((method, path, payload));
    final answer = fallback?.call(method, path, payload);
    if (answer != null) {
      if (answer is Exception) throw answer;
      return (answer as Map<String, Object?>?) ?? const {};
    }
    if (path.endsWith('/link')) {
      if (method == 'PUT') {
        return {
          'token': 'tok-1',
          'url': 'https://kapynotes.com/space/tok-1',
          'role': payload?['role'],
          'approval': payload?['approval'],
          'expiresAt': null,
        };
      }
      return {'link': null};
    }
    return const {};
  }
}

Joining joiningOver(FakeSend send) =>
    Joining(send: send.call, refreshSpaces: () async {}, requestSync: () {});
