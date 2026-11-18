import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/keycap.dart';
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
    testWidgets(
      '${platform.name}: the list title never truncates from 200 to 440 px, '
      'and New note gives up its keycap and word only once each',
      (tester) async {
        AppPlatform.debugTargetPlatformOverride = platform;
        var keycapFrom = 0.0;
        var labelFrom = 0.0;
        for (var width = 200.0; width <= 440; width++) {
          await tester.pumpWidget(
            MaterialApp(
              theme: KapyTheme.light(),
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
          final title = tester.renderObject<RenderParagraph>(
            find.descendant(
              of: find.byKey(const ValueKey('sidebar-space-title')),
              matching: find.byType(RichText),
            ),
          );
          expect(title.didExceedMaxLines, isFalse, reason: 'at $width px');
          final keycap = find.text(chord).evaluate().isNotEmpty;
          final label = find.text('New note').evaluate().isNotEmpty;
          if (keycap && keycapFrom == 0) keycapFrom = width;
          if (label && labelFrom == 0) labelFrom = width;
          expect(keycap, keycapFrom > 0, reason: 'keycap at $width px');
          expect(label, labelFrom > 0, reason: 'label at $width px');
        }
        expect(find.byType(Keycap), findsOneWidget);
        expect(labelFrom, lessThan(keycapFrom));

        final button = find.byKey(const ValueKey('sidebar-new-note'));
        expect(
          tester.getSize(button).width,
          closeTo(
            TonalButton.widthOf(
              tester.element(button),
              'New note',
              shortcut: chord,
            ),
            0.01,
          ),
        );
      },
    );
  }
}
