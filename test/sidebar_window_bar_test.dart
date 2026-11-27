import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/layout_prefs.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:kapy_notes/ui/tonal_button.dart';
import 'package:material_ui/material_ui.dart';

import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);
  tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

  for (final (platform, chord) in [
    (TargetPlatform.windows, 'Ctrl+N'),
    (TargetPlatform.macOS, '⌘N'),
  ]) {
    // Ask Kapy's sparkle and the gap after it take 40 more, so its sweep
    // starts 40 wider.
    for (final (scale, ask) in [
      (1.0, false),
      (1.3, false),
      (2.0, false),
      (1.0, true),
      (1.3, true),
      (2.0, true),
    ]) {
      testWidgets(
        '${platform.name} at ${scale}x text${ask ? ', with Ask Kapy' : ''}: '
        'from ${ask ? 252 : 212} to 440 px New note gives up its keycap, '
        'then its word and the count below the list\'s own width, and '
        'before the list title truncates',
        (tester) async {
          AppPlatform.debugTargetPlatformOverride = platform;
          var keycapFrom = 0.0;
          var labelFrom = 0.0;
          var keycap = false;
          var label = false;
          for (var width = ask ? 252.0 : 212.0; width <= 440; width++) {
            await tester.pumpWidget(
              MaterialApp(
                theme: KapyTheme.light(),
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
                        count: 12,
                        onCreate: () {},
                        onHide: () {},
                        onAskKapy: ask ? () {} : null,
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
            final truncated = tester
                .renderObject<RenderParagraph>(
                  find.descendant(
                    of: find.byKey(const ValueKey('sidebar-space-title')),
                    matching: find.byType(RichText),
                  ),
                )
                .didExceedMaxLines;
            keycap = find.text(chord).evaluate().isNotEmpty;
            label = find.text('New note').evaluate().isNotEmpty;
            if (keycap && keycapFrom == 0) keycapFrom = width;
            if (label && labelFrom == 0) labelFrom = width;
            expect(keycap, keycapFrom > 0, reason: 'keycap at $width px');
            expect(label, labelFrom > 0, reason: 'label at $width px');
            expect(
              find.byKey(const ValueKey('sidebar-space-count')).evaluate(),
              label ? hasLength(1) : isEmpty,
              reason: 'count at $width px',
            );
            expect(
              label && width < SidebarWindowBar.fullWidth,
              isFalse,
              reason: 'the word stayed below the fold at $width px',
            );
            expect(
              keycap && !label,
              isFalse,
              reason: 'a keycap without its word at $width px',
            );
            expect(
              truncated && label,
              isFalse,
              reason: 'the word stayed while the title truncated at $width px',
            );
            if (scale == 1) {
              expect(truncated, isFalse, reason: 'at $width px');
            }
          }
          if (scale == 1) {
            expect(keycap, isTrue);
            expect(labelFrom, SidebarWindowBar.fullWidth);
            expect(keycapFrom, greaterThanOrEqualTo(labelFrom));
          }

          if (!label) return;
          final button = find.byKey(const ValueKey('sidebar-new-note'));
          expect(
            tester.getSize(button).width,
            closeTo(
              TonalButton.widthOf(
                tester.element(button),
                'New note',
                shortcut: keycap ? chord : null,
                tall: true,
              ),
              0.01,
            ),
          );
        },
      );
    }
  }

  for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
    testWidgets('${platform.name}: at the default list width the bar reads '
        '"My notes 37" with New note, and 1 pt narrower the count and the '
        'word fold', (tester) async {
      AppPlatform.debugTargetPlatformOverride = platform;
      expect(SidebarWindowBar.fullWidth, LayoutPrefs.defaultSidebarWidth);
      Future<void> bar(double width) => tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.dark(),
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
      final count = find.byKey(const ValueKey('sidebar-space-count'));
      final newNote = find.byKey(const ValueKey('sidebar-new-note'));
      final ask = find.byKey(const ValueKey('sidebar-ask-kapy'));
      final hide = find.byKey(const ValueKey('sidebar-hide'));

      await bar(SidebarWindowBar.fullWidth);
      expect(find.text('37'), findsOneWidget);
      expect(count, findsOneWidget);
      expect(
        find.descendant(of: newNote, matching: find.text('New note')),
        findsOneWidget,
      );
      expect(
        tester.widget<TonalButton>(newNote).shortcut,
        isNull,
        reason: 'the handwritten title and Geist leave the chord no room',
      );
      expect(tester.getRect(ask).right, tester.getRect(newNote).left);
      expect(tester.getRect(newNote).right, tester.getRect(hide).left);
      expect(SidebarWindowBar.fullWidth - tester.getRect(hide).right, 16);

      await bar(SidebarWindowBar.fullWidth - 1);
      expect(count, findsNothing);
      expect(find.text('New note'), findsNothing);
      expect(newNote, findsOneWidget);
      expect(ask, findsOneWidget);
    });
  }

  testWidgets("an iPad's bar keeps 8 between its buttons", (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: SidebarWindowBar.fullWidth + 40,
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
    expect(find.text('New note'), findsOneWidget);
    expect(find.byKey(const ValueKey('sidebar-space-count')), findsOneWidget);
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
      expect(title.style?.fontSize, 19);
      expect(title.style?.color, KapyTheme.lightPalette.textHeading);
    },
  );

  testWidgets("the search field's keycap is T3, which Riverbank dark keeps "
      'apart from T2', (tester) async {
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
    expect(shortcut, findsNothing, reason: 'the keycap waits for the pointer');
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(
      location: tester.getCenter(
        find.byKey(const ValueKey('sidebar-search-box')),
      ),
    );
    await tester.pump();
    final keycap = tester.widget<Text>(shortcut);
    expect(keycap.style!.color, palette.textTertiary);
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
