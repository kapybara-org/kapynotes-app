import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
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
        'then its word, before the list title truncates',
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
            expect(labelFrom, lessThan(keycapFrom));
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

  testWidgets('a hairline runs along the bar\'s bottom, as under the band', (
    tester,
  ) async {
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
    final bar = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(SidebarWindowBar),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (bar.foregroundDecoration as BoxDecoration?)?.border,
      Border(bottom: BorderSide(color: KapyTheme.lightPalette.railBorder)),
    );
  });

  testWidgets("the search field's keycap is T3, which Riverbank dark keeps "
      'apart from T2', (tester) async {
    AppPlatform.debugTargetPlatformOverride = TargetPlatform.macOS;
    const palette = KapyTheme.darkPalette;
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
    final keycap = tester.widget<Text>(
      find.byKey(const ValueKey('sidebar-search-shortcut')),
    );
    expect(keycap.style!.color, palette.textTertiary);
  });
}
