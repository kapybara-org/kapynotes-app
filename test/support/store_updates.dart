import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/store_updates.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The changelog's entries for the two releases About & updates is drawn
/// with on its board (1E0B-0): 1.35.4 installed, and 1.35.5 after it.
List<Map<String, Object?>> aboutReleases() => [
  {
    'version': '1.35.5',
    'build': 47,
    'date': '2026-11-25',
    'summary':
        'Swipe actions on notes, a Back that goes where you expect, and a '
        'calmer Home and Folders.',
    'highlights': [
      'Swipe a note on Home to pin or archive it.',
      'Back and a swipe from the edge close what’s open, one step at a time.',
      'Home and Folders put your notes first.',
    ],
    'changes': [
      'Swipe a note on Home to pin or archive it.',
      'Back and a swipe from the edge close what’s open, one step at a time.',
      'Home and Folders put your notes first.',
      'Folders open where you left them.',
    ],
  },
  {
    'version': '1.35.4',
    'build': 46,
    'date': '2026-11-23',
    'summary':
        'Phones get a new bar, note page and Upcoming, and computers get a '
        'cleaner note view, notes list, Settings and Tasks.',
    'highlights': [
      'On a phone, the bar has Notes, Folders and Kapy AI. Press and hold + '
          'to make a task or drawing.',
      'A new note page on phones, with the week at the top and a month '
          'sheet to move a note to another day.',
      'Notes for a later day wait in Upcoming, named Tomorrow, Tue 24 or '
          '7 Dec.',
      'On a computer, a cleaner note view, notes list, Settings and Tasks.',
      'Undo right after removing someone from a shared note takes it back, '
          'so they keep the note.',
    ],
    'changes': [
      'On a phone, the bar has Notes, Folders and Kapy AI. Press and hold + '
          'to make a task or drawing.',
      'A new note page on phones, with the week at the top and a month '
          'sheet to move a note to another day.',
      'Notes for a later day wait in Upcoming, named Tomorrow, Tue 24 or '
          '7 Dec.',
      'On a computer, a cleaner note view, notes list, Settings and Tasks.',
      'Undo right after removing someone from a shared note takes it back, '
          'so they keep the note.',
      'Tasks remember the folder they were made in.',
    ],
  },
];

/// What a phone hears from its store, for a test: it runs [installed] as
/// [build], the store answers with [answer] (nothing, when it is left out),
/// and the changelog, when given, is [releases] as read today. Nothing
/// reaches the network, and the test disposes of it when it ends.
StoreUpdates fakeStoreUpdates(
  LocalStore store, {
  String installed = '1.35.4',
  int build = 46,
  Future<StoreOffer?> Function()? answer,
  List<Map<String, Object?>>? releases,
}) {
  if (releases != null) {
    store.data['changelog.v1'] = {
      'fetchedAt': DateTime.now().toIso8601String(),
      'releases': releases,
    };
  }
  final updates = StoreUpdates(
    store,
    client: MockClient((_) async => throw StateError('no network in a test')),
    packageInfo: PackageInfo(
      appName: 'Kapy Notes',
      packageName: StoreUpdates.bundleId,
      version: installed,
      buildNumber: '$build',
    ),
    lookup: (_) async => answer?.call(),
  );
  addTearDown(updates.dispose);
  return updates;
}
