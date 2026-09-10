import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show PointerDeviceKind;

import 'package:image/image.dart' as img;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:kapy_notes/app.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/notes_store.dart';
import 'package:kapy_notes/data/onboarding.dart';
import 'package:kapy_notes/data/rates.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/update_checker.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/images/note_image_provider.dart';
import 'package:kapy_notes/ui/app_logo.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'app_test.dart' show MemoryStore;
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
final _goldenRatesFetchedAt = DateTime(2026, 9, 2, 12);

/// Renders the whole app at a fixed size for visual review.
///
/// Goldens depend on macOS system fonts (see [loadTestFonts]); regenerate
/// them on macOS with `flutter test --update-goldens`.
late LayoutPrefs goldenPrefs;

Future<void> pumpForGolden(
  WidgetTester tester, {
  required Size size,
  required Brightness brightness,
  bool withNote = true,
  bool blankNote = false,
  bool withImages = false,
  bool withUpdates = false,
  bool firstRun = false,
  bool sidebarVisible = true,
  bool withPinnedNote = false,

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
  if (withUpdates) {
    // A checked, current app: the state the pane is in almost all the time,
    // and the only one whose copy does not move with the calendar.
    store.data['updates.v1'] = {
      'available': null,
      'checkedAt': DateTime.now().toIso8601String(),
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
    );
  }

  final notes = NotesStore(
    store,
    now: () => _goldenNow,
    blobs: withImages ? _imageStore : null,
  );
  final prefs = LayoutPrefs(store);
  goldenPrefs = prefs;
  final rates = RatesRepository(store);
  final shortcuts = ShortcutPrefs(store)..load();

  await notes.load();
  prefs.load();
  // These images document the app in use, where the notes list has been
  // opened at least once. A new install starts with it closed, which is what
  // the first-launch images ask for.
  if (prefs.sidebarVisible != sidebarVisible) prefs.toggleSidebar();
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

  await tester.pumpWidget(
    KapyNotesApp(
      store: store,
      notes: notes,
      rates: rates,
      prefs: prefs,
      shortcuts: shortcuts,
      updates: updates,
    ),
  );
  if (withImages) {
    await _warmVisibleNoteImages(tester);
    // Existing Image states still point at the fake-zone streams evicted
    // above. Re-resolve them against the now-warm target-sized cache entries.
    unawaited(tester.binding.reassembleApplication());
    await tester.pump();
  }
  await tester.runAsync(
    () => precacheImage(
      const AssetImage(AppLogo.assetPath),
      tester.element(find.byType(KapyNotesApp)),
    ),
  );
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

/// Opens settings through the affordance the current layout owns. Phones keep
/// settings in the notes drawer so the editor footer can stay focused on input.
Future<void> tapSettings(WidgetTester tester) async {
  final sidebar = find.byKey(const ValueKey('sidebar-settings'));
  if (find.byTooltip('Show notes').evaluate().isNotEmpty) {
    await tester.tap(find.byTooltip('Show notes'));
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

  testWidgets('desktop dark pinned on top', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    // The pin is the only toolbar control with an on state, and the filled
    // icon behind a selected surface is the whole signal that the window is
    // now floating.
    goldenPrefs.toggleAlwaysOnTop();
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_pinned.png'),
    );
  });

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

  testWidgets('desktop dark compact hover surfaces', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('formatting-toggle'))),
    );
    await tester.pumpAndSettle();
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('format-style'))),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_hover_surfaces.png'),
    );
  });

  testWidgets('desktop dark results divider hover', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('results-divider-hover'))),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_results_divider_hover.png'),
    );
  });

  testWidgets('desktop dark compact results divider hover', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(600, 630),
      brightness: Brightness.dark,
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('results-divider-hover'))),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile(
        'goldens/desktop_dark_compact_results_divider_hover.png',
      ),
    );
  });

  testWidgets('desktop dark results restore hover', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    goldenPrefs.resultsVisible = false;
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('results-restore-hover'))),
    );
    await tester.pumpAndSettle();

    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_results_restore_hover.png'),
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
    await mouse.moveTo(tester.getCenter(find.byTooltip('Hide notes')));
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

  testWidgets('first launch, phone light', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.light,
      platform: TargetPlatform.iOS,
      withNote: false,
      firstRun: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/welcome_phone_light.png'),
    );
  });

  testWidgets('first launch, phone dark', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
      withNote: false,
      firstRun: true,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/welcome_phone_dark.png'),
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

  testWidgets('desktop dark selection formatting toolbar', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    final editor = find.descendant(
      of: find.byType(NoteEditor),
      matching: find.byType(TextField),
    );
    final field = tester.widget<TextField>(editor);
    final editable = tester
        .state<EditableTextState>(
          find.descendant(
            of: find.byType(NoteEditor),
            matching: find.byType(EditableText),
          ),
        )
        .renderEditable;
    final targetStart = _body.indexOf('Hotel');
    final wordBox = editable
        .getBoxesForSelection(
          TextSelection(
            baseOffset: targetStart,
            extentOffset: targetStart + 'Hotel'.length,
          ),
        )
        .first;
    final start = editable.localToGlobal(
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
    expect(field.controller!.selection.isCollapsed, isFalse);
    expect(
      find.byKey(const ValueKey('selection-formatting-toolbar')),
      findsOneWidget,
    );
    final toolbar = tester.getRect(
      find.byKey(const ValueKey('selection-formatting-toolbar')),
    );
    expect(toolbar.left, greaterThanOrEqualTo(0));
    expect(toolbar.top, greaterThanOrEqualTo(0));
    expect(toolbar.right, lessThanOrEqualTo(760));
    expect(toolbar.bottom, lessThanOrEqualTo(520));
    expect(toolbar.width, inInclusiveRange(230, 245));
    final selectionFade = tester.widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('selection-formatting-toolbar')),
            matching: find.byType(FadeTransition),
          )
          .first,
    );
    expect(selectionFade.opacity.value, closeTo(1, 0.01));
    final hoverMouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(hoverMouse.removePointer);
    await hoverMouse.addPointer(location: Offset.zero);
    await hoverMouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('selection-style'))),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const ValueKey('selection-formatting-toolbar')),
      matchesGoldenFile('goldens/selection_formatting_toolbar.png'),
    );
  });

  testWidgets('desktop dark, sidebar collapsed', (tester) async {
    // The toolbar owns the window's left edge here, where macOS draws the
    // traffic lights over it.
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

  // The bottom of the merged Appearance pane, where number format and the
  // rate credit ended up when Numbers stopped being a category of its own.
  testWidgets('desktop dark settings, appearance scrolled', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-appearance')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('rate-attribution')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings_appearance_end.png'),
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

  testWidgets('desktop dark settings, updates', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.dark,
      withUpdates: true,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-updates')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_dark_settings_updates.png'),
    );
  });

  testWidgets('desktop light settings, appearance', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(760, 520),
      brightness: Brightness.light,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-appearance')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/desktop_light_settings_appearance.png'),
    );
  });

  testWidgets('phone editor', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_editor.png'),
    );
  });

  testWidgets('phone settings', (tester) async {
    // A touch screen gets the sheet: a list of categories, one pushed at a
    // time. Declared, because these run on a desktop host.
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_settings.png'),
    );
  });

  testWidgets('phone settings, a category opened', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await tapSettings(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('settings-section-general')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_settings_general.png'),
    );
  });

  testWidgets('phone notes drawer', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(390, 760),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await tester.tap(find.byTooltip('Show notes'));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_drawer.png'),
    );
  });

  // The largest phone the app ships to, and the one where desktop-scale chrome
  // was most obviously wrong: a 40pt footer of 17px glyphs reads as a toolbar
  // belonging to some other, smaller application. Held at the full 932pt so
  // the bars are judged against the screen they actually sit on.
  testWidgets('phone editor at iPhone Pro Max size', (tester) async {
    await pumpForGolden(
      tester,
      size: const Size(430, 932),
      brightness: Brightness.dark,
      platform: TargetPlatform.iOS,
    );
    await expectLater(
      find.byType(KapyNotesApp),
      matchesGoldenFile('goldens/phone_editor_large.png'),
    );
  });
}
