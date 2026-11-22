import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:image/image.dart' as img;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/billing/billing.dart';
import 'package:kapy_notes/core/appearance.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/auto_titles.dart';
import 'package:kapy_notes/data/folders.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_days.dart';
import 'package:kapy_notes/data/note_drawing.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/tags.dart';
import 'package:kapy_notes/data/task_library.dart';
import 'package:kapy_notes/sync/account.dart';
import 'package:kapy_notes/sync/doc_store.dart';
import 'package:kapy_notes/sync/key_store.dart';
import 'package:kapy_notes/sync/spaces.dart';
import 'package:kapy_notes/sync/sync_state.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/update_checker.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/images/note_image_provider.dart';
import 'package:kapy_notes/ui/app_logo.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/note_tabs.dart' show NoteTabRow;
import 'package:kapy_notes/ui/sidebar.dart' show NoteRow;
import 'package:package_info_plus/package_info_plus.dart';

import 'app_test.dart' show MemoryStore;
import 'billing/billing_fakes.dart';
import 'fake_update_installer.dart';
import 'support/note_driver.dart';
import 'sync/fake_server.dart';
import 'test_fonts.dart';

const _body = '''
Lisbon trip budget

Flights for two
flights = 412 eur
flights to usd

Hotel: 7 nights
nightly = 128 eur
nightly * 7

Food and getting around // rough guess
daily = 55 eur
daily * 7

total
total to usd''';

const _rates = <String, double>{'EUR': 0.861401, 'GBP': 0.738359};
final _goldenNow = DateTime(2026, 9, 1, 15, 38);

/// The task list's clock: [_goldenNow] unless a fixture moves it on, so the
/// tasks of notes added one after another keep that order rather than
/// tying and falling back to their random ids.
var _goldenTaskNow = _goldenNow;
final _goldenRatesFetchedAt = DateTime(2026, 9, 2, 12);

/// Renders the whole app at a fixed size for visual review.
///
/// Goldens depend on macOS system fonts (see [loadTestFonts]); regenerate
/// them on macOS with `flutter test --update-goldens`.
late LayoutPrefs goldenPrefs;

/// The notes the image was built from, for the few images that have to change
/// the list after it is on screen.
late NotesStore goldenNotes;
late TagStore goldenTags;
late FolderStore goldenFolders;

/// The task list, for the images that ask for one with `withTasks`.
late TaskLibrary goldenTasks;

/// A model on the device that is never asked, so Settings shows its row.
class _GoldenTitles implements TitleModel {
  @override
  Future<String?> unavailableReason() async => null;

  @override
  Future<String> name({required String instructions, required String prompt}) =>
      Completer<String>().future;
}

Future<void> pumpForGolden(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
  bool withNote = true,
  bool blankNote = false,
  bool withImages = false,
  bool withUpdates = false,
  bool updateAvailable = false,

  /// The pending release already downloaded, so the notes list offers
  /// "Update and restart". Implies [updateAvailable].
  bool updateReady = false,
  bool firstRun = false,
  bool sidebarVisible = true,
  bool withPinnedNote = false,

  /// Drawings in the store, the newest pinned, for the Drawings space.
  bool withDrawings = false,
  bool cards = true,

  /// Tasks on the rail, read from the notes' checklist lines.
  bool withTasks = false,

  /// Notes written earlier in the week, for the page's days and their dots.
  bool withWeek = false,

  /// A tagged note last edited yesterday, for a phone's list of days.
  bool withYesterday = false,

  /// The notes' own days, for Tasks' Later row.
  NoteDayStore? days,

  /// Signed in to an account on Pro with two invitations waiting, so that
  /// Settings has its account, its sharing and every one of its categories.
  bool signedIn = false,

  /// Which build the image is of.
  ///
  /// Sizes in this app resolve from [AppPlatform.hasPointer], not from the
  /// window, so a phone-sized window on a Mac still renders every control at
  /// desktop density. Without this a "phone" golden documents a narrow desktop
  /// window and nothing about the phone.
  TargetPlatform? platform,
}) async {
  if (platform != null) {
    AppPlatform.debugTargetPlatformOverride = platform;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
  }
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

  final store = MemoryStore();
  // These images document the app in use rather than the moment it is
  // installed; the welcome goldens below ask for that moment by name.
  if (!firstRun) store.data[Onboarding.storeKey] = Onboarding.welcomeRevision;
  store.data['rates.v1'] = RateSnapshot(
    base: 'USD',
    date: '01 Sep 2026',
    fetchedAt: _goldenRatesFetchedAt,
    rates: _rates,
  ).toJson();

  UpdateChecker? updates;
  if (updateReady) {
    withUpdates = true;
    updateAvailable = true;
  }
  if (withUpdates) {
    // A checked, current app: the state the pane is in almost all the time,
    // and the only one whose copy does not move with the calendar.
    store.data['updates.v1'] = {
      'available': updateAvailable
          ? {
              'version': '1.2.0',
              'build': 12,
              'notesUrl': 'https://kapynotes.com/changelog/1.2.0',
            }
          : null,
      'checkedAt': DateTime.now().toIso8601String(),
    };
    // The list of releases too, and fresh, so the image is of the pane with
    // its changelog rather than of the pane failing to read one — and so the
    // golden never depends on the network.
    store.data['changelog.v1'] = {
      'fetchedAt': DateTime.now().toIso8601String(),
      'releases': [
        if (updateAvailable)
          {
            'version': '1.2.0',
            'date': '2026-09-04',
            'summary': 'A faster, calmer update for the tools you use most.',
            'highlights': [
              'Clearer controls and more readable supporting text.',
              'Faster startup and smoother note editing.',
              'A shorter update summary that is easy to scan.',
            ],
            'changes': [
              'The complete explanation remains available in release history.',
            ],
          },
        {
          'version': '1.1.0',
          'date': '2026-09-03',
          'summary': 'The first release that can update itself.',
          'changes': [
            'Kapy Notes checks for new releases once a day and offers them in '
                'the corner. Nothing downloads until you ask.',
            'Tab nests list items, and the footer buttons do it on touch.',
          ],
        },
        {
          'version': '1.0.0',
          'date': '2026-09-02',
          'summary': 'The first public build, for macOS and Windows.',
          'changes': ['A notebook that does the math.'],
        },
      ],
    };
    updates = UpdateChecker(
      store,
      client: MockClient((_) async => throw StateError('no network here')),
      packageInfo: PackageInfo(
        appName: 'Kapy Notes',
        packageName: 'com.kapybara.kapynotes',
        version: '1.1.0',
        buildNumber: '11',
      ),
      installer: updateReady
          ? (FakeUpdateInstaller()
              ..onDisk = const StagedUpdate(version: '1.2.0', build: 12))
          : null,
    );
    // Picks the download up the way a launch does. Nothing is due, so the
    // only thing this reaches is the installer's record of it.
    if (updateReady) await updates.checkIfDue();
  }

  final notes = NotesStore(
    store,
    now: () => _goldenNow,
    blobs: withImages ? _imageStore : null,
  );
  final prefs = LayoutPrefs(store);
  goldenPrefs = prefs;
  goldenNotes = notes;
  goldenTags = TagStore(store);
  await goldenTags.load();
  goldenFolders = FolderStore(store);
  await goldenFolders.load();
  final rates = RatesRepository(store);
  final shortcuts = ShortcutPrefs(store)..load();
  _goldenTaskNow = _goldenNow;
  final tasks = withTasks
      ? goldenTasks = TaskLibrary(
          notes: notes,
          store: store,
          storage: MemoryDocStorage(),
          now: () => _goldenTaskNow,
        )
      : null;

  if (withWeek) {
    Map<String, Object?> note(String id, String body, DateTime edited) => {
      'id': id,
      'body': body,
      'createdAt': edited.millisecondsSinceEpoch,
      'updatedAt': edited.millisecondsSinceEpoch,
    };
    store.data['notes.v1'] = [
      note(
        'standup',
        'Standup notes\nShip the week',
        DateTime(2026, 8, 31, 10, 5),
      ),
      note(
        'gym',
        'Gym plan\nLegs, then a long walk',
        DateTime(2026, 8, 31, 19, 30),
      ),
      note(
        'books',
        'Book ideas\nPiranesi, The Overstory',
        DateTime(2026, 8, 31, 22, 10),
      ),
      note(
        'pricing',
        'Pricing ideas\n1,799 INR',
        DateTime(2026, 8, 29, 16, 20),
      ),
    ];
  }
  if (withYesterday) {
    final edited = DateTime(2026, 8, 31, 18, 40).millisecondsSinceEpoch;
    store.data['notes.v1'] = [
      {
        'id': 'ferry',
        'body': 'Trip to Goa\nBook the ferry',
        'createdAt': edited,
        'updatedAt': edited,
      },
    ];
  }
  await notes.load();
  if (withYesterday) {
    goldenTags.setTags('ferry', [goldenTags.create('Trip')!.id]);
  }
  await tasks?.load();
  prefs.load();
  // These images document the app in use, where the notes list has been
  // opened at least once. A new install starts with it closed, which is what
  // the first-launch images ask for.
  if (prefs.sidebarVisible != sidebarVisible) prefs.toggleSidebar();
  prefs.noteCards = cards;
  if (withDrawings) _seedDrawings(notes);
  if (withNote) {
    final note = notes.create();
    if (withImages) {
      notes.updateDocument(note.id, _imageBody, const [], _imageAttachments());
    } else if (!blankNote) {
      notes.updateBody(note.id, _body);
    }
    if (withPinnedNote) {
      notes.togglePinned(note.id);
      notes.create(body: 'Today\nFollow up on the launch checklist');
    }
  }
  // Publish the cached rates without going near the network.
  rates.loadCache();
  final account = signedIn ? await _signIn(tester, store, notes) : null;

  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates,
      prefs: prefs,
      shortcuts: shortcuts,
      account: account,
      updates: updates,
      tags: goldenTags,
      folders: goldenFolders,
      tasks: tasks,
      days: days,
      titleModel: _GoldenTitles(),
    ),
  );
  if (withImages) {
    await _warmVisibleNoteImages(tester);
    // Existing Image states still point at the fake-zone streams evicted
    // above. Re-resolve them against the now-warm target-sized cache entries.
    unawaited(tester.binding.reassembleApplication());
    await tester.pump();
  }
  // The mark is decoded at the size it is drawn, which is a cache entry of
  // its own: warming the asset itself leaves the first image to draw it
  // without one, and so an image that depends on which test ran before.
  await tester.runAsync(
    () => Future.wait([
      for (final image in tester.widgetList<Image>(find.byType(Image)))
        if (image.image case ResizeImage(
          imageProvider: AssetImage(assetName: AppLogo.assetPath),
        ))
          precacheImage(image.image, tester.element(find.byWidget(image))),
    ]),
  );
  await tester.pumpAndSettle();
}

/// The final boards' Tasks (D09, M13): Lisbon trip's three, Call Arjun with
/// no note, Book the room and Send the deck, in that order; Lisbon trip in
/// green and the two work notes in mustard; and Renewal notes' two waiting
/// in [days] for Fri 4, so Later shows.
Future<void> seedBoardTasks(WidgetTester tester, NoteDayStore days) async {
  final notes = goldenNotes;
  Future<Note> add(String body) async {
    final note = notes.create(body: body);
    await tester.runAsync(goldenTasks.reconcileNow);
    _goldenTaskNow = _goldenTaskNow.add(const Duration(seconds: 1));
    return note;
  }

  final lisbon = await add(
    'Lisbon trip\n☐ Ask Ana which Sintra palace to skip\n'
    '☐ Renew passport before the trip\n☐ Book the Sintra train tickets',
  );
  await add('Tasks\n☐ Call Arjun');
  final quote = await add('Quote for the deck\n☐ Book the room');
  final call = await add('Call with Arjun\n☐ Send the deck');
  final renewal = await add(
    'Renewal notes\n☐ Renew the domain\n☐ Renew the van insurance',
  );
  final travel = goldenTags.create('Travel')!;
  goldenTags.recolour(travel.id, 'sage');
  final work = goldenTags.create('Work')!;
  goldenTags.recolour(work.id, 'mustard');
  goldenTags.setTags(lisbon.id, [travel.id]);
  goldenTags.setTags(quote.id, [work.id]);
  goldenTags.setTags(call.id, [work.id]);
  days.setDay(renewal.id, DateTime(2026, 9, 4));
  await tester.pumpAndSettle();
}

/// An empty set of note days, for [seedBoardTasks].
Future<NoteDayStore> boardDays() async {
  final days = NoteDayStore(MemoryStore(), now: () => _goldenNow);
  await days.load();
  return days;
}

/// Sam, signed in on Pro against a server of the test's own, with Priya and
/// Arjun each waiting on an answer to an invitation.
///
/// The account loads its own tags and tasks, on the real clock its sign-in
/// needs: the image's own were loaded on the test's, and a load awaited
/// across the two never finishes.
Future<Account> _signIn(
  WidgetTester tester,
  MemoryStore store,
  NotesStore notes,
) async {
  final server = FakeServer();
  final sam = server.user('user-1')..name = 'Sam';
  for (final (index, name) in const ['Priya', 'Arjun'].indexed) {
    final owner = server.user('user-${index + 2}')..name = name;
    server.spaces['space-$name'] =
        FakeSpace(
            id: 'space-$name',
            kind: SpaceKind.team,
            name: '$name’s notes',
            ownerId: owner.id,
          )
          ..members[owner.id] = SpaceRole.owner
          ..invites['invite-$name'] = (
            email: sam.email,
            role: SpaceRole.member,
          );
  }
  final state = SyncState(store);
  final account = _SignedInAccount(
    auth: FakeAuth(id: sam.id, email: sam.email, name: sam.name),
    syncApi: (_) => FakeApi(server, device: 'device-1', userId: sam.id),
    keys: KeyStore(InMemorySecureStore()),
    notes: notes,
    state: state,
    store: store,
    tags: TagStore(store),
    tasks: TaskLibrary(
      notes: notes,
      store: store,
      state: state,
      storage: MemoryDocStorage(),
    ),
  );
  final plans = FakeBillingApi()..answer = () => entitlementsFor(pro: true);
  account.billing = Billing(
    session: account,
    userId: () => account.user?.id,
    token: () => account.token,
    api: (_) => plans,
    store: FakePurchaseStore(supported: false),
    cache: store,
  );
  addTearDown(account.dispose);
  await tester.runAsync(() async {
    await account.restore();
    await account.signIn(email: sam.email, password: 'x');
    await account.createPassphrase('a good passphrase');
    await account.billing!.refresh();
    await account.sharing!.refresh();
  });
  return account;
}

/// An account signed in before the app is pumped. The app restores the
/// account it is given off its first frames; this one has nothing left to
/// restore, and a second pass would start its sync again on the test's clock,
/// leaving a timer behind once the image is taken.
class _SignedInAccount extends Account {
  _SignedInAccount({
    required super.auth,
    required super.syncApi,
    required super.keys,
    required super.notes,
    required super.state,
    required super.store,
    required super.tasks,
    required super.tags,
  });

  bool _restored = false;

  @override
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    await super.restore();
  }
}

/// Five drawings, the first pinned: boxes, an arrow, a scribble and a word,
/// in the swatches the colour popover offers.
void _seedDrawings(NotesStore notes) {
  const titles = [
    'Q4 goals map',
    'App wireframe',
    'Onboarding flow',
    'Living room',
    'Garden plan',
  ];
  for (final (seed, title) in titles.indexed) {
    var z = 0;
    DrawElement element(
      DrawKind kind,
      List<double> points, {
      int? color,
      double width = 3,
      String text = '',
    }) => DrawElement(
      id: '$seed-$z',
      kind: kind,
      points: points,
      z: z++,
      color: color,
      width: width,
      text: text,
    );
    final note = notes.create(drawing: true);
    notes.updateDrawing(
      note.id,
      NoteDrawing([
        element(DrawKind.rect, [40, 40, 260, 160]),
        element(DrawKind.ellipse, [320, 60, 460, 170], color: 0xFF6F8F52),
        element(DrawKind.arrow, [260, 100, 320, 110]),
        element(DrawKind.text, [60, 80], text: seed.isEven ? 'Idea' : 'Herbs'),
        element(
          DrawKind.pen,
          [
            for (var i = 0; i < 30; i++) ...[
              60.0 + i * 12,
              240 + (i % 5) * 8.0,
            ],
          ],
          color: 0xFF3F8796,
          width: 4,
        ),
        if (seed.isOdd)
          element(DrawKind.ellipse, [120, 260, 220, 330], color: 0xFFD0663B),
      ]),
      title: title,
    );
    if (seed == titles.length - 1) notes.togglePinned(note.id);
  }
}

/// Opens Drawings from the rail, and [open] from its list when given.
Future<void> _openDrawings(WidgetTester tester, {String? open}) async {
  await tester.tap(find.byKey(const ValueKey('rail-drawings')));
  await tester.pumpAndSettle();
  if (open == null) return;
  await tester.tap(find.text(open).first);
  await tester.pumpAndSettle();
}

/// Resolves the exact size-aware keys the first frame requested. File I/O only
/// advances under `runAsync` in a widget test; the real app has no fake clock.
Future<void> _warmVisibleNoteImages(WidgetTester tester) async {
  final finder = find.byWidgetPredicate(
    (widget) => widget is Image && widget.image is NoteImageProvider,
  );
  final pending = <(NoteImageProvider, ImageConfiguration)>[];
  for (var index = 0; index < finder.evaluate().length; index++) {
    final current = finder.at(index);
    final image = tester.widget<Image>(current);
    final size = image.width == null || image.height == null
        ? null
        : Size(image.width!, image.height!);
    pending.add((
      image.image as NoteImageProvider,
      createLocalImageConfiguration(tester.element(current), size: size),
    ));
  }
  await tester.runAsync(() async {
    for (final (provider, configuration) in pending) {
      // The first build starts this key in the fake-async zone. Replace that
      // pending entry, then resolve it wholly on the real event loop.
      await provider.evict(configuration: configuration);
      await _warmNoteImage(provider, configuration);
    }
  });
}

Future<void> _warmNoteImage(
  NoteImageProvider provider,
  ImageConfiguration configuration,
) {
  final completer = Completer<void>();
  final stream = provider.resolve(configuration);
  late ImageStreamListener listener;
  listener = ImageStreamListener(
    (_, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    },
    onError: (error, _) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.completeError(error);
    },
  );
  stream.addListener(listener);
  return completer.future;
}

/// Opens settings through the affordance the current layout owns: the rail's
/// gear beside a wide window's notes list. Phones keep settings in the notes
/// drawer so the editor footer can stay focused on input.
Future<void> tapSettings(WidgetTester tester) async {
  final gear = find.byKey(const ValueKey('rail-settings'));
  if (gear.evaluate().isNotEmpty) {
    await tester.tap(gear);
    return;
  }
  final sidebar = find.byKey(const ValueKey('sidebar-settings'));
  final showNotes = find.byWidgetPredicate(
    (widget) =>
        widget is Tooltip && (widget.message ?? '').startsWith('Show notes'),
  );
  if (showNotes.evaluate().isNotEmpty) {
    await tester.tap(showNotes);
    await tester.pumpAndSettle();
  }
  await tester.tap(sidebar.first);
}

/// Pictures for the image golden, written once outside any test body: real
/// file I/O inside `testWidgets` never completes.
late Directory _imageDir;
late BlobStore _imageStore;
late List<String> _imageHashes;

/// Flat-coloured rectangles rather than photographs, so the golden is about
/// the layout — where a picture sits, how wide it is, what it does to the
/// lines around it — and not about a JPEG decoder's rounding.
Uint8List _swatch(int width, int height, img.ColorRgb8 colour) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  img.fill(image, color: colour);
  img.fillRect(
    image,
    x1: 0,
    y1: height - height ~/ 4,
    x2: width,
    y2: height,
    color: img.ColorRgb8(
      (colour.r * 0.7).round(),
      (colour.g * 0.7).round(),
      (colour.b * 0.7).round(),
    ),
  );
  return Uint8List.fromList(img.encodePng(image, level: 1));
}

/// A note that reads the way the feature is meant to: a line of writing, one
/// picture across the column, more writing, then three that became a row.
const String _imageBody =
    'Kitchen renovation\n'
    'Quote came in at 4200 eur\n'
    '\n'
    '\u{FFFC}\n'
    '\n'
    'Tiles we shortlisted\n'
    '\u{FFFC}\u{FFFC}\u{FFFC}\n'
    '\n'
    '4200 eur to usd';

List<NoteAttachmentRef> _imageAttachments() {
  final anchors = <int>[];
  for (var i = 0; i < _imageBody.length; i++) {
    if (_imageBody.codeUnitAt(i) == 0xFFFC) anchors.add(i);
  }
  const sizes = [(960, 600), (600, 600), (600, 600), (600, 600)];
  return [
    for (var i = 0; i < anchors.length; i++)
      NoteImageRef(
        offset: anchors[i],
        hash: _imageHashes[i],
        key: Uint8List(32),
        mime: 'image/png',
        width: sizes[i].$1,
        height: sizes[i].$2,
        bytes: 4096,
      ),
  ];
}

void main() {
  setUpAll(() async {
    await loadTestFonts();
    _imageDir = await Directory.systemTemp.createTemp('kapy-golden-images');
    _imageStore = BlobStore(directory: _imageDir);
    _imageHashes = [
      await _imageStore.put(_swatch(960, 600, img.ColorRgb8(86, 132, 196))),
      await _imageStore.put(_swatch(600, 600, img.ColorRgb8(206, 128, 92))),
      await _imageStore.put(_swatch(600, 600, img.ColorRgb8(104, 168, 128))),
      await _imageStore.put(_swatch(600, 600, img.ColorRgb8(158, 130, 198))),
    ];
  });

  tearDownAll(() async {
    if (await _imageDir.exists()) await _imageDir.delete(recursive: true);
  });

  testWidgets('desktop dark', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark.png'),
    );
  });

  // The one click an update asks for, in the title bar once the release is
  // downloaded.
  testWidgets('desktop dark, update ready to install', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      updateReady: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_update_ready.png'),
    );
  });

  testWidgets('desktop dark note actions', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    final note = goldenNotes.notes.single;
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(
      location: tester.getCenter(find.byKey(ValueKey(note.id)).first),
    );
    addTearDown(mouse.removePointer);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('note-actions-${note.id}')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_note_actions.png'),
    );
  });

  testWidgets('desktop dark editor context menu', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    final editor = find.descendant(
      of: find.byType(NoteEditor),
      matching: noteField,
    );
    final bounds = tester.getRect(editor);
    await tester.tapAt(
      Offset(bounds.left + 36, bounds.bottom - 32),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_editor_context_menu.png'),
    );
  });

  testWidgets('desktop dark pinned on top', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    // Keep on top has no button in the bar, so More is where it says the
    // window is floating: by offering to stop.
    goldenPrefs.toggleAlwaysOnTop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('page-more')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_pinned.png'),
    );
  });

  /// The archive with something in it, which is the only place a note can be
  /// thrown away for good. Two images: the resting state, and picking.
  Future<void> fillAndOpenArchive(WidgetTester tester) async {
    final notes = goldenNotes;
    for (final body in [
      'Old receipts\nCoffee: 12.40',
      'Trip ideas\nLisbon in April',
    ]) {
      notes.create(body: body);
    }
    await tester.pumpAndSettle();
    for (final note in [...notes.notes]) {
      notes.archive(note.id);
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-filter-archive')));
    await tester.pumpAndSettle();
  }

  testWidgets('desktop dark archive', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await fillAndOpenArchive(tester);
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_archive.png'),
    );
  });

  testWidgets('desktop dark archive, picking notes', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await fillAndOpenArchive(tester);
    await tester.tap(find.byKey(const ValueKey('archive-start-selecting')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-all')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_archive_selecting.png'),
    );
  });

  /// Two notes picked in the ordinary list: the bar over it, and the menu a
  /// right click opens on them.
  Future<void> pickTwo(WidgetTester tester) async {
    for (final body in [
      'Old receipts\nCoffee: 12.40',
      'Trip ideas\nLisbon in April',
    ]) {
      goldenNotes.create(body: body);
    }
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(NoteRow, 'Trip ideas'));
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.widgetWithText(NoteRow, 'Old receipts'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('desktop light notes, two picked', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.light,
      platform: TargetPlatform.macOS,
    );
    await pickTwo(tester);
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_light_notes_picked.png'),
    );
  });

  testWidgets('desktop dark notes, two picked, with their menu', (
    tester,
  ) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      platform: TargetPlatform.macOS,
    );
    await pickTwo(tester);
    await tester.tap(
      find.widgetWithText(NoteRow, 'Old receipts'),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_notes_picked_menu.png'),
    );
  });

  for (final scale in [1.0, 2.0, 3.1]) {
    testWidgets("Home's Pinned card holds its two lines whole at "
        '$scale× text', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpForGolden(
        tester,
        size: const Size(393, 852),
        brightness: Brightness.light,
        platform: TargetPlatform.iOS,
        withPinnedNote: true,
      );
      await tester.tap(find.byKey(const ValueKey('page-back')));
      await tester.pumpAndSettle();

      final card = tester.getRect(
        find.byKey(const ValueKey('home-pinned-card')),
      );
      final lines = tester.getRect(
        find.descendant(
          of: find.byKey(const ValueKey('home-pinned-card')),
          matching: find.byWidgetPredicate(
            (widget) => widget is Text && widget.maxLines == 2,
          ),
        ),
      );
      expect(lines.bottom, lessThanOrEqualTo(card.bottom - 14 + 0.5));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('desktop dark pinned note section', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withPinnedNote: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_note_pinned.png'),
    );
  });

  testWidgets('Tasks keeps Keep on top under More, with its shortcut', (
    tester,
  ) async {
    await pumpForGolden(
      tester,
      size: const Size(1000, 640),
      brightness: Brightness.dark,
      withTasks: true,
      platform: TargetPlatform.macOS,
    );
    await tester.tap(find.byKey(const ValueKey('rail-tasks')));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').startsWith('Keep on top'),
      ),
      findsNothing,
    );

    final more = find.byKey(const ValueKey('page-more'));
    final onTop = find.byKey(const ValueKey('page-more-on-top'));
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: onTop, matching: find.text('Keep on top')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: onTop, matching: find.text('⌃⌘T')),
      findsOneWidget,
    );
    await tester.tap(onTop);
    await tester.pumpAndSettle();
    expect(goldenPrefs.alwaysOnTop, isTrue);

    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: onTop, matching: find.text('Stop keeping on top')),
      findsOneWidget,
    );
  });

  testWidgets('desktop dark narrow, results at line ends', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(600, 630),
      brightness: Brightness.dark,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_narrow_results.png'),
    );
  });

  testWidgets('desktop dark narrow, notes list over the page', (tester) async {
    // The window a new install opens at, too narrow for the list beside the
    // page: the rail and the page stay, and the list opens over the page.
    await pumpForGolden(
      tester,
      size: LayoutPrefs.defaultWindowSize,
      brightness: Brightness.dark,
    );
    await tester.tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message ?? '').startsWith('Show notes'),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_narrow_list.png'),
    );
  });

  testWidgets('desktop dark compact header hover', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('page-more'))),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_header_hover.png'),
    );
  });

  testWidgets('desktop light', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.light,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_light.png'),
    );
  });

  testWidgets('first launch, desktop dark', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      // Everything a new install actually is: no notes of its own, no list
      // opened yet, and the welcome note in front of both.
      withNote: false,
      firstRun: true,
      sidebarVisible: false,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/welcome_desktop_dark.png'),
    );
  });

  testWidgets('desktop dark empty state', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withNote: false,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_empty.png'),
    );
  });

  testWidgets('desktop dark drawings', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1100, 720),
      brightness: Brightness.dark,
      withNote: false,
      withDrawings: true,
    );
    await _openDrawings(tester, open: 'Garden plan');
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_drawings.png'),
    );
  });

  testWidgets('desktop light drawings with the colour popover', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1100, 720),
      brightness: Brightness.light,
      withNote: false,
      withDrawings: true,
    );
    await _openDrawings(tester, open: 'Garden plan');
    await tester.tap(find.byKey(const ValueKey('draw-style')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_light_drawings_style.png'),
    );
  });

  testWidgets('desktop dark drawings list', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1100, 720),
      brightness: Brightness.dark,
      withNote: false,
      withDrawings: true,
      cards: false,
    );
    await _openDrawings(tester, open: 'Garden plan');
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_drawings_list.png'),
    );
  });

  testWidgets('desktop dark drawings, none yet and none open', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1100, 720),
      brightness: Brightness.dark,
      withNote: false,
    );
    await _openDrawings(tester);
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_drawings_empty.png'),
    );
  });

  // The Folders tab as r3's corrected 2GX5-0 draws it: a folder open two
  // levels down with the open note inside, closed folders with their
  // counts, New folder, then the notes in no folder.
  testWidgets('desktop dark folders', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1100, 720),
      brightness: Brightness.dark,
      withNote: false,
    );
    final folders = goldenFolders;
    final work = folders.create('Work')!;
    final clients = folders.create('Clients', parentId: work.id)!;
    final placed = {
      'Acme kickoff\nAgenda for Monday': folders.create(
        'Acme',
        parentId: clients.id,
      ),
      'Roadmap\nQ1 themes': folders.create('Product', parentId: work.id),
      'Gym plan\nVoice note': folders.create('Personal'),
      'Reading list\nThe Overstory, Piranesi': folders.create('Reading'),
      'Pricing ideas\n1,799 INR': clients,
      'Call with Arjun\nPricing page by Friday': clients,
      'Dentist\nThursday 4pm': null,
      'Morning pages\nSlept badly, but the walk helped': null,
    };
    for (final MapEntry(key: body, value: folder) in placed.entries) {
      final note = goldenNotes.create(body: body);
      if (folder != null) folders.file([note.id], folder.id);
    }
    goldenPrefs
      ..setFolderOpen(work.id, true)
      ..setFolderOpen(clients.id, true)
      ..foldersShown = true;
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('folders-tab')),
        matching: find.text('Call with Arjun'),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_folders.png'),
    );
  });

  // r5's folder in a tab (26IU-0): a note's tab and the folder's in front,
  // the page with the folder inside as a card and the notes at any depth,
  // and the folder marked in the tree.
  testWidgets('desktop dark folder in a tab', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1440, 900),
      brightness: Brightness.dark,
      withNote: false,
    );
    final folders = goldenFolders;
    final work = folders.create('Work')!;
    final clients = folders.create('Clients', parentId: work.id)!;
    final acme = folders.create('Acme', parentId: clients.id)!;
    final placed = {
      'Acme kickoff\nScope, dates and the first invoice': acme,
      'Invoice, March\nSent on the 3rd': acme,
      'Logo feedback\nVoice note': acme,
      'Roadmap\nQ1 themes': folders.create('Product', parentId: work.id),
      'Gym plan\nVoice note': folders.create('Personal'),
      'Reading list\nThe Overstory, Piranesi': folders.create('Reading'),
      'Pricing ideas\n1,799 INR': clients,
      'Call with Arjun\nPricing page by Friday': clients,
      'Dentist\nThursday 4pm': null,
      'Morning pages\nSlept badly, but the walk helped': null,
    };
    for (final MapEntry(key: body, value: folder) in placed.entries) {
      final note = goldenNotes.create(body: body);
      if (folder != null) folders.file([note.id], folder.id);
    }
    goldenPrefs
      ..setFolderOpen(work.id, true)
      ..setFolderOpen(clients.id, true)
      ..foldersShown = true;
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('folders-tab')),
        matching: find.text('Call with Arjun'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(find.byKey(ValueKey('folder-${clients.id}')));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(NoteTabRow),
        matching: find.text('Clients'),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_folder_in_a_tab.png'),
    );
  });

  // The pinned cards Paper's 5TS-0 draws: a checklist under a title too
  // long for one line, See all at the heading's end, and amounts in mono.
  // r5's week in row 1, to header r3 and Day cell r2: Mon 31 picked, so the
  // list is narrowed to it with its chip beside the filter, and the fill has
  // left today, whose weekday stays sage.
  for (final brightness in Brightness.values) {
    testWidgets('desktop ${brightness.name} week, a day picked', (
      tester,
    ) async {
      await pumpForGolden(
        tester,
        size: const Size(1280, 800),
        brightness: brightness,
        withWeek: true,
      );
      await tester.tap(find.byKey(const ValueKey('day-strip-2026-8-31')));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile(
          'goldens/desktop_${brightness.name}_week_day_picked.png',
        ),
      );
    });
  }

  // The month under "Aug–Sep ▾", on the picked day's month, with the days
  // that have notes brighter and September still to come.
  testWidgets('desktop dark week, the month open', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
      withWeek: true,
    );
    for (final key in ['day-strip-2026-8-31', 'day-strip-month']) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_week_month_open.png'),
    );
  });

  // With the list hidden there is nothing to narrow, so a day lists its
  // notes under the week.
  testWidgets('desktop dark week, a day listed', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(1280, 800),
      brightness: Brightness.dark,
      withWeek: true,
      sidebarVisible: false,
    );
    await tester.tap(find.byKey(const ValueKey('day-strip-2026-8-31')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_week_day_listed.png'),
    );
  });

  testWidgets('desktop dark tags', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withNote: false,
    );
    final work = goldenTags.create('Work')!;
    final money = goldenTags.create('Money')!;
    final travel = goldenTags.create('Travel')!;
    for (final (body, tags) in [
      ('Groceries\nMilk, eggs', <Tag>[]),
      ('land\n₹75,60,000', [money]),
      ('Trip budget\n₹28,000', [travel, money]),
      ('Reading list\nThree books', <Tag>[]),
      ('SnowSEO Issues\n☑ Crawl\n☐ Fix titles', [work]),
    ]) {
      final note = goldenNotes.create(body: body);
      goldenTags.setTags(note.id, [for (final tag in tags) tag.id]);
    }
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sidebar-notes-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('notes-filter-tags')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('tag-filter-${work.id}')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_tags.png'),
    );
  });

  // r4's 23HR-0: When's submenu beside the filter, with This week ticked
  // and its chip beside the filter's button.
  testWidgets('desktop dark When', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    for (final key in [
      'sidebar-notes-filter',
      'notes-filter-when',
      'notes-filter-when-thisWeek',
      'sidebar-notes-filter',
      'notes-filter-when',
    ]) {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_when.png'),
    );
  });

  testWidgets('desktop dark pinned cards', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withNote: false,
    );
    for (final (index, body) in [
      'Groceries\nMilk, eggs',
      'land\n₹75,60,000',
      'car issues\n₹18,400',
      'Ideas\nA quieter dock',
      'Goals - Oct 2026\nShip the redesign',
      'Todos\nRenew domain, gym',
      'Reading list\nThree books',
      'SnowSEO Issues backlog\n☑ Crawl\n☐ Fix titles\n☐ Sitemap',
    ].indexed) {
      final note = goldenNotes.create(body: body);
      if (index > 2) goldenNotes.togglePinned(note.id);
    }
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_pinned_cards.png'),
    );
  });

  testWidgets('desktop dark note with images', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 780),
      brightness: Brightness.dark,
      withImages: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_images.png'),
    );
  });

  testWidgets('desktop dark blank note sample', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      blankNote: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_blank_note.png'),
    );
  });

  testWidgets('desktop dark selection bubble', (tester) async {
    // With the list put away, so the whole note fits the page and the word
    // to select is on screen rather than scrolled above it.
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      sidebarVisible: false,
    );
    final note = NoteDriver(
      tester,
      find.descendant(of: find.byType(NoteEditor), matching: noteField),
    );
    final targetStart = _body.indexOf('Hotel');
    final wordBox = note
        .boxesFor(
          TextSelection(
            baseOffset: targetStart,
            extentOffset: targetStart + 'Hotel'.length,
          ),
        )
        .first;
    final start = note.toGlobal(
      Offset(wordBox.left + 1, (wordBox.top + wordBox.bottom) / 2),
    );
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.down(start);
    await tester.pump();
    await mouse.up();
    await mouse.removePointer();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(note.value.selection.isCollapsed, isFalse);
    final bubble = tester.getRect(
      find.byKey(const ValueKey('selection-bubble')),
    );
    expect(bubble.top, greaterThanOrEqualTo(0));
    expect(bubble.right, lessThanOrEqualTo(760));
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_selection_bubble.png'),
    );
  });

  testWidgets('desktop dark, sidebar collapsed', (tester) async {
    // The page starts a margin in from the rail, as in Paper's window with
    // the list hidden.
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    goldenPrefs.toggleSidebar();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_collapsed.png'),
    );
  });

  testWidgets('desktop dark settings', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings.png'),
    );
  });

  testWidgets('Windows desktop dark settings stays comfortably readable', (
    tester,
  ) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      platform: TargetPlatform.windows,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_windows_dark_settings.png'),
    );
  });

  testWidgets('Windows pending update stays concise and readable', (
    tester,
  ) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      platform: TargetPlatform.windows,
      withUpdates: true,
      updateAvailable: true,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_windows_dark_update.png'),
    );
  });

  // The bottom of the Notes pane, where number format and the rates credit
  // sit.
  testWidgets('desktop dark settings, notes scrolled', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-notes')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('rate-attribution')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings_notes_end.png'),
    );
  });

  testWidgets('desktop dark settings, shortcuts', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-shortcuts')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings_shortcuts.png'),
    );
  });

  testWidgets('desktop dark settings, about', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withUpdates: true,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-about')));
    await tester.pumpAndSettle();
    expect(
      find.text('The version you have, updates and what changed'),
      findsOneWidget,
      reason: 'the tap reached About, so the golden shows its pane',
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings_about.png'),
    );
  });

  // D13 and D12, the final boards for Settings, at the window they are drawn
  // in: signed in, so the rail has every category, with the update card and
  // the version at its foot.
  for (final (pane, brightness) in const [
    ('appearance', Brightness.light),
    ('appearance', Brightness.dark),
    ('notes', Brightness.dark),
  ]) {
    testWidgets('desktop ${brightness.name} settings, $pane', (tester) async {
      await pumpForGolden(
        tester,
        size: const Size(1440, 900),
        brightness: brightness,
        withUpdates: true,
        signedIn: true,
      );
      await tapSettings(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('settings-section-$pane')));
      await tester.pumpAndSettle();
      for (final key in const [
        'settings-section-account',
        'settings-section-sharing',
        'settings-section-about',
        'settings-version-status',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile(
          'goldens/desktop_${brightness.name}_settings_$pane.png',
        ),
      );
    });
  }

  // Phone · v2 on the three phones it is drawn for, an iPhone 15, a Pixel 8
  // and an iPhone SE, every screen and menu in both themes. A golden has no
  // keyboard to draw, so the room it takes is left empty under the page.
  for (final (phone, size, platform, keyboard) in const [
    ('iphone', Size(393, 852), TargetPlatform.iOS, 336.0),
    ('android', Size(412, 915), TargetPlatform.android, 300.0),
    ('se', Size(375, 667), TargetPlatform.iOS, 260.0),
  ]) {
    for (final brightness in Brightness.values) {
      final name = '${phone}_${brightness.name}';

      Future<void> pumpPhone(
        WidgetTester tester, {
        bool firstRun = false,
        NoteDayStore? days,
        bool signedIn = false,
      }) async {
        PackageInfo.setMockInitialValues(
          appName: 'Kapy Notes',
          packageName: 'com.kapybara.kapynotes',
          version: '1.34.0',
          buildNumber: '1',
          buildSignature: '',
        );
        await pumpForGolden(
          tester,
          size: size,
          brightness: brightness,
          platform: platform,
          withNote: !firstRun,
          firstRun: firstRun,
          withPinnedNote: !firstRun,
          withTasks: !firstRun,
          withDrawings: !firstRun,
          withYesterday: !firstRun,
          days: days,
          signedIn: signedIn,
        );
      }

      Future<void> tapAndSettle(WidgetTester tester, String key) async {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
      }

      Future<void> matches(String screen) => expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/phone_${screen}_$name.png'),
      );

      testWidgets('phone first launch, $name', (tester) async {
        await pumpPhone(tester, firstRun: true);
        await matches('first_launch');
      });

      testWidgets('phone page with the keyboard up, $name', (tester) async {
        await pumpPhone(tester);
        tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await matches('page');
      });

      testWidgets('phone page menu, $name', (tester) async {
        await pumpPhone(tester);
        await tapAndSettle(tester, 'page-more');
        await matches('page_menu');
      });

      testWidgets('phone notes home, $name', (tester) async {
        await pumpPhone(tester);
        await tapAndSettle(tester, 'page-back');
        await matches('notes_home');
      });

      testWidgets('phone notes, two picked, $name', (tester) async {
        await pumpPhone(tester);
        await tapAndSettle(tester, 'page-back');
        final rows = find.byType(NoteRow);
        await tester.longPress(rows.last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Select'));
        await tester.pumpAndSettle();
        await tester.tap(rows.first);
        await tester.pumpAndSettle();
        await matches('notes_picked');
      });

      testWidgets('phone notes filter, $name', (tester) async {
        await pumpPhone(tester);
        for (final tag in ['Work', 'Travel', 'Money']) {
          goldenTags.setTags(goldenNotes.notes.first.id, [
            goldenTags.create(tag)!.id,
          ]);
        }
        await tapAndSettle(tester, 'page-back');
        await tapAndSettle(tester, 'phone-filters');
        await tapAndSettle(tester, 'sidebar-notes-filter');
        await matches('notes_filter');
      });

      testWidgets('phone new menu, $name', (tester) async {
        await pumpPhone(tester);
        await tapAndSettle(tester, 'page-back');
        await tester.longPress(find.byKey(const ValueKey('phone-new')));
        await tester.pumpAndSettle();
        await matches('new_menu');
      });

      testWidgets('phone quick find, $name', (tester) async {
        await pumpPhone(tester);
        await tapAndSettle(tester, 'page-back');
        await tapAndSettle(tester, 'sidebar-search-field');
        await matches('quick_find');
      });

      testWidgets('phone tasks, $name', (tester) async {
        await pumpPhone(tester);
        // One note, so the list keeps the order its lines read: tasks that
        // two notes add at the same golden instant tie, and fall back to
        // their random ids.
        goldenNotes.create(
          body:
              'Lisbon trip\n☐ Book the Sintra train\n☐ Pack adapters\n'
              '☐ Pay the electricity bill',
        );
        await tester.runAsync(goldenTasks.reconcileNow);
        await tester.pumpAndSettle();
        await tapAndSettle(tester, 'page-back');
        await tapAndSettle(tester, 'bar-tasks');
        await matches('tasks');
      });

      // M13 with a search typed, and M13a: Do now over Up next, the line
      // after it and Later. The boards are drawn on an iPhone.
      if (phone == 'iphone') {
        Future<void> openBoardTasks(WidgetTester tester) async {
          final days = await boardDays();
          await pumpPhone(tester, days: days);
          await seedBoardTasks(tester, days);
          await tapAndSettle(tester, 'page-back');
          await tapAndSettle(tester, 'bar-tasks');
        }

        testWidgets('phone tasks, searching, $name', (tester) async {
          await openBoardTasks(tester);
          await tester.enterText(
            find.byKey(const ValueKey('tasks-search-field')),
            'sintra',
          );
          await tester.pumpAndSettle();
          await matches('tasks_search');
        });

        testWidgets('phone tasks, Do now and Up next, $name', (tester) async {
          await openBoardTasks(tester);
          await tapAndSettle(tester, 'tasks-pair-right');
          await tapAndSettle(tester, 'tasks-pair-right');
          await tapAndSettle(tester, 'tasks-start');
          await matches('tasks_up_next');
        });
      }

      testWidgets('phone drawings, $name', (tester) async {
        await pumpPhone(tester);
        await tapAndSettle(tester, 'page-back');
        await tapAndSettle(tester, 'bar-drawings');
        await matches('drawings');
      });

      // M16: signed in, with the mode chosen rather than followed, as the
      // board has it, and this version's notes not yet looked at.
      testWidgets('phone settings, $name', (tester) async {
        await pumpPhone(tester, signedIn: true);
        goldenPrefs.appearance = brightness == Brightness.dark
            ? AppearanceMode.dark
            : AppearanceMode.light;
        await tapAndSettle(tester, 'page-back');
        await tapAndSettle(tester, 'bar-settings');
        for (final text in [
          'Sam',
          'Account & sync · Pro',
          '2 invitations waiting',
          "What's new",
          'Version 1.34.0',
        ]) {
          expect(find.text(text), findsOneWidget);
        }
        await matches('settings');
      });

      testWidgets('phone settings, a category opened, $name', (tester) async {
        await pumpPhone(tester);
        await tapAndSettle(tester, 'page-back');
        await tapAndSettle(tester, 'bar-settings');
        await tapAndSettle(tester, 'settings-section-appearance');
        await matches('settings_appearance');
      });
    }
  }

  // From 720 pt a tablet keeps the desktop layout: the list beside the page
  // and no phone bar.
  for (final brightness in Brightness.values) {
    testWidgets('tablet at 744 pt, ${brightness.name}', (tester) async {
      await pumpForGolden(
        tester,
        size: const Size(744, 1133),
        brightness: brightness,
        platform: TargetPlatform.iOS,
        withPinnedNote: true,
      );
      expect(find.byKey(const ValueKey('phone-bar')), findsNothing);
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/tablet_${brightness.name}.png'),
      );
    });
  }

  // The whole Tasks window, for its sidebar (Today, Done, From notes, How
  // Tasks works and the credit) and Later, which the page's own images
  // crop out.
  group('desktop Tasks (D09)', () {
    Future<void> openTasks(WidgetTester tester) async {
      final days = await boardDays();
      await pumpForGolden(
        tester,
        size: const Size(1440, 900),
        brightness: Brightness.dark,
        withTasks: true,
        withNote: false,
        platform: TargetPlatform.macOS,
        days: days,
      );
      await seedBoardTasks(tester, days);
      await tester.tap(find.byKey(const ValueKey('rail-tasks')));
      await tester.pumpAndSettle();
    }

    testWidgets('first visit, with How Tasks works', (tester) async {
      await openTasks(tester);
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/desktop_dark_tasks_first_visit.png'),
      );
    });

    testWidgets('after Got it', (tester) async {
      await openTasks(tester);
      await tester.tap(find.byKey(const ValueKey('tasks-got-it')));
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/desktop_dark_tasks.png'),
      );
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('⌘K menu', () {
    /// The trip notes p-7-0 searches: two notes, two tasks in one of them, a
    /// drawing, and one more in Archive. Pumped at Paper's 1440 × 900.
    Future<void> pumpTrip(WidgetTester tester, Brightness brightness) async {
      await pumpForGolden(
        tester,
        size: const Size(1440, 900),
        brightness: brightness,
        withTasks: true,
      );
      final notes = goldenNotes;
      notes.archive(notes.create(body: 'Sintra in 2024\nThe palace queue').id);
      notes.create(
        body: 'Goals - Oct 2026\nSee Sintra and Cascais before December',
      );
      final drawing = notes.create(drawing: true);
      notes.updateDrawing(
        drawing.id,
        NoteDrawing.empty,
        title: 'Sintra day route',
      );
      notes.create(
        body:
            'Trip budget\nGo to Sintra on a weekday. The weekend queues are '
            'brutal.\n☐ Book the Sintra train tickets\n'
            '☐ Ask Ana which Sintra palace to skip',
      );
      await tester.runAsync(goldenTasks.reconcileNow);
      await tester.pumpAndSettle();
    }

    Future<void> openMenu(WidgetTester tester, [String text = '']) async {
      await tester.tap(find.byKey(const ValueKey('sidebar-search-field')));
      await tester.pumpAndSettle();
      if (text.isEmpty) return;
      await tester.enterText(
        find.byKey(const ValueKey('command-menu-field')),
        text,
      );
      await tester.pumpAndSettle();
    }

    testWidgets('before typing, dark', (tester) async {
      await pumpTrip(tester, Brightness.dark);
      await openMenu(tester);
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_dark.png'),
      );
    });

    testWidgets('while typing, dark', (tester) async {
      await pumpTrip(tester, Brightness.dark);
      await openMenu(tester, 'sintra');
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_dark_typing.png'),
      );
    });

    testWidgets('a setting, dark', (tester) async {
      await pumpTrip(tester, Brightness.dark);
      await openMenu(tester, 'text size');
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_dark_settings.png'),
      );
    });

    testWidgets('while typing, light', (tester) async {
      await pumpTrip(tester, Brightness.light);
      await openMenu(tester, 'sintra');
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_light_typing.png'),
      );
    });

    /// Work, Money and Travel on the trip notes, as SOW-0 lists them.
    Future<void> tagTrip(WidgetTester tester) async {
      final work = goldenTags.create('Work')!;
      final money = goldenTags.create('Money')!;
      final travel = goldenTags.create('Travel')!;
      for (final (title, tags) in [
        ('Trip budget', [travel, money]),
        ('Goals - Oct 2026', [work]),
      ]) {
        final note = goldenNotes.notes.firstWhere(
          (note) => note.title == title,
        );
        goldenTags.setTags(note.id, [for (final tag in tags) tag.id]);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('# filters by tag, dark', (tester) async {
      await pumpTrip(tester, Brightness.dark);
      await tagTrip(tester);
      await openMenu(tester, '#');
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_dark_hash.png'),
      );
    });

    testWidgets('Tag note…, dark', (tester) async {
      await pumpTrip(tester, Brightness.dark);
      await tagTrip(tester);
      await openMenu(tester, 'tag');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/command_menu_dark_tag_note.png'),
      );
    });
  });

  // Every theme's window and its card in Settings, Increase contrast on the
  // two themes it changes most, and the phone's picker with At night on.
  group('themes', () {
    Future<void> showAppearance(WidgetTester tester) async {
      await tapSettings(tester);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('settings-section-appearance')),
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('mode-setting'))),
      );
      await tester.pumpAndSettle();
    }

    for (final theme in AppTheme.values) {
      for (final side in Brightness.values) {
        if (theme == AppTheme.midnight && side == Brightness.light) continue;
        final name = '${theme.name}_${side.name}';

        // Riverbank's window is desktop_dark.png and desktop_light.png.
        if (theme != AppTheme.riverbank) {
          testWidgets('${theme.label} ${side.name}', (tester) async {
            await pumpForGolden(
              tester,
              size: const Size(760, 520),
              brightness: side,
            );
            goldenPrefs.theme = theme;
            await tester.pumpAndSettle();
            await expectLater(
              find.byType(KapyNotesApp),
              matchesGoldenFile('goldens/theme_$name.png'),
            );
          });
        }

        testWidgets('${theme.label} ${side.name}, picked in Settings', (
          tester,
        ) async {
          await pumpForGolden(
            tester,
            size: const Size(1000, 800),
            brightness: side,
          );
          goldenPrefs.theme = theme;
          await showAppearance(tester);
          await expectLater(
            find.byType(KapyNotesApp),
            matchesGoldenFile('goldens/theme_settings_$name.png'),
          );
        });
      }
    }

    for (final (theme, side) in [
      (AppTheme.riverbank, Brightness.dark),
      (AppTheme.graphite, Brightness.light),
    ]) {
      testWidgets('${theme.label} ${side.name} with Increase contrast on', (
        tester,
      ) async {
        await pumpForGolden(
          tester,
          size: const Size(760, 520),
          brightness: side,
        );
        goldenPrefs.theme = theme;
        goldenPrefs.setIncreaseContrast(true, asks: false);
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(KapyNotesApp),
          matchesGoldenFile(
            'goldens/theme_${theme.name}_${side.name}_increased_contrast.png',
          ),
        );
      });
    }

    testWidgets('the picker on a phone, with At night on', (tester) async {
      await pumpForGolden(
        tester,
        size: const Size(390, 1180),
        brightness: Brightness.dark,
        platform: TargetPlatform.iOS,
      );
      goldenPrefs.nightTheme = const NightTheme(enabled: true);
      await tester.pumpAndSettle();
      for (final key in [
        'page-back',
        'bar-settings',
        'settings-section-appearance',
      ]) {
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
      }
      await Scrollable.ensureVisible(
        tester.element(find.byKey(const ValueKey('mode-setting'))),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(KapyNotesApp),
        matchesGoldenFile('goldens/phone_settings_themes.png'),
      );
    });
  });
}
