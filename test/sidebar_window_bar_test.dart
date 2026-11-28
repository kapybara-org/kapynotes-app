import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  for (final (platform, keycap, chord) in [
    (TargetPlatform.windows, 'Ctrl+N', 'Ctrl + N'),
    (TargetPlatform.macOS, '⌘N', 'Cmd + N'),
  ]) {
    testWidgets('${platform.name}: the bar is the title, then the sparkle, a '
        '+ and the toggle as icons, with New note, its chord and the count '
        'in tooltips, from 200 to 440 px and at 2x text', (tester) async {
      debugDefaultTargetPlatformOverride = platform;
      AppPlatform.debugTargetPlatformOverride = platform;
      for (final scale in [1.0, 2.0]) {
        for (var width = 200.0; width <= 440; width += 40) {
          await tester.pumpWidget(
            MaterialApp(
              theme: KapyTheme.dark(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Material(
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: width,
                    child: SidebarWindowBar(
                      title: 'My notes',
                      count: 37,
                      onCreate: () {},
                      onHide: () {},
                      onAskKapy: () {},
                      newNoteShortcut: ShortcutBinding(
                        logicalKey: LogicalKeyboardKey.keyN,
                        physicalKey: PhysicalKeyboardKey.keyN,
                        meta: platform == TargetPlatform.macOS,
                        control: platform != TargetPlatform.macOS,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          expect(tester.takeException(), isNull, reason: 'at $width px');
          expect(find.text('37'), findsNothing);
          expect(find.text('New note'), findsNothing);
          expect(find.text(keycap), findsNothing);
          expect(find.byTooltip('37 notes'), findsOneWidget);
          expect(find.byTooltip('New note  $chord'), findsOneWidget);
          final newNote = find.byKey(const ValueKey('sidebar-new-note'));
          final ask = find.byKey(const ValueKey('sidebar-ask-kapy'));
          final hide = find.byKey(const ValueKey('sidebar-hide'));
          expect(tester.getSize(newNote), const Size(32, 32));
          expect(tester.getRect(ask).right, tester.getRect(newNote).left);
          expect(tester.getRect(newNote).right, tester.getRect(hide).left);
          expect(width - tester.getRect(hide).right, 16);
        }
      }
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('pressing + makes a note, and Tasks says its count in the '
      "title's tooltip", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    var made = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.light(),
        home: Material(
          child: SizedBox(
            width: 336,
            child: SidebarWindowBar(
              title: 'Tasks',
              count: 10,
              countLabel: 'open',
              noun: 'task',
              onCreate: () => made++,
              onHide: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.byTooltip('10 tasks open'), findsOneWidget);
    expect(find.text('10 open'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sidebar-new-note')));
    expect(made, 1);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets("an iPad's bar keeps 8 between its buttons", (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 376,
              child: SidebarWindowBar(
                title: 'My notes',
                count: 2,
                onCreate: () {},
                onHide: () {},
                onAskKapy: () {},
              ),
            ),
          ),
        ),
      ),
    );
    final newNote = find.byKey(const ValueKey('sidebar-new-note'));
    expect(
      tester.getRect(newNote).left -
          tester.getRect(find.byKey(const ValueKey('sidebar-ask-kapy'))).right,
      8,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('sidebar-hide'))).left -
          tester.getRect(newNote).right,
      8,
    );
    expect(find.text('New note'), findsNothing);
    expect(find.byTooltip('2 notes'), findsOneWidget);
  });

  testWidgets(
    "the bar names the list in handwriting, in the heading's colour",
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.light(),
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                child: SidebarWindowBar(
                  title: 'My notes',
                  count: 12,
                  onCreate: () {},
                  onHide: () {},
                ),
              ),
            ),
          ),
        ),
      );
      final title = tester.widget<Text>(
        find.byKey(const ValueKey('sidebar-space-title')),
      );
      expect(title.style?.fontFamily, AppFonts.hand);
      expect(title.style?.fontSize, 22);
      expect(title.style?.color, KapyTheme.lightPalette.textHeading);
    },
  );

  testWidgets("the search field's keycap waits for the pointer, and is T3, "
      'which Riverbank dark keeps apart from T2', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    final palette = KapyTheme.darkPalette;
    expect(palette.textTertiary, isNot(palette.textSecondary));
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: SidebarSearchField(
            onSearch: () {},
            shortcut: const ShortcutBinding(
              logicalKey: LogicalKeyboardKey.keyK,
              physicalKey: PhysicalKeyboardKey.keyK,
              meta: true,
            ),
          ),
        ),
      ),
    );
    final shortcut = find.byKey(const ValueKey('sidebar-search-shortcut'));
    expect(shortcut, findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('sidebar-search-box'))),
    );
    await tester.pump();
    expect(tester.widget<Text>(shortcut).style!.color, palette.textTertiary);
    await mouse.moveTo(const Offset(799, 599));
    await tester.pump();
    expect(shortcut, findsNothing);
  });

  // Ctrl+Shift+F, Search's chord off a Mac, is longer than the field in a
  // list dragged to its narrowest has beside the placeholder.
  testWidgets('a chord too long for a list dragged narrow leaves the field '
      'to the placeholder', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => AppPlatform.debugTargetPlatformOverride = null);
    const chord = ShortcutBinding(
      logicalKey: LogicalKeyboardKey.keyF,
      physicalKey: PhysicalKeyboardKey.keyF,
      control: true,
      shift: true,
    );
    final keycap = find.byKey(const ValueKey('sidebar-search-shortcut'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    for (final (width, shown) in [(150.0, false), (344.0, true)]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: SidebarSearchField(onSearch: () {}, shortcut: chord),
              ),
            ),
          ),
        ),
      );
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('sidebar-search-box'))),
      );
      await tester.pump();
      expect(keycap, shown ? findsOneWidget : findsNothing, reason: '$width');
      expect(tester.takeException(), isNull, reason: '$width');
    }
  });

  testWidgets('the Mac search field is 32 high, 10 in, radius 9, with its '
      '14 px icon in T3', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    final palette = KapyTheme.darkPalette;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 344,
              child: SidebarSearchField(onSearch: () {}),
            ),
          ),
        ),
      ),
    );
    final search = find.byKey(const ValueKey('sidebar-search-box'));
    final box = tester.widget<Container>(search);
    expect(tester.getSize(search).height, 30);
    expect(box.padding, const EdgeInsets.symmetric(horizontal: 10));
    expect(
      (box.decoration! as BoxDecoration).borderRadius,
      BorderRadius.circular(AppRadii.control),
    );
    expect((box.decoration! as BoxDecoration).color, palette.controlBackground);
    expect((box.decoration! as BoxDecoration).border, isNull);
    final icon = tester.widget<KapyIcon>(
      find.descendant(of: search, matching: find.byType(KapyIcon)),
    );
    expect(icon.size, 14);
    expect(icon.color, palette.textSecondary);
    expect(
      tester.getTopLeft(find.byType(KapyIcon)).dx -
          tester.getTopLeft(search).dx,
      10,
    );
  });
}
