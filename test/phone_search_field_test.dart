import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/ui/sidebar.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final scale in [1.0, 2.0, 3.1]) {
    testWidgets('a phone search well holds its placeholder whole at '
        '$scale× text', (tester) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          theme: KapyTheme.light(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SidebarSearchField(
                phone: true,
                placeholder: 'Search notes and tasks',
                onSearch: () {},
                trailing: const SizedBox.square(dimension: 44),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final well = tester.getRect(
        find.byKey(const ValueKey('sidebar-search-box')),
      );
      final placeholder = find.text('Search notes and tasks');
      final words = tester.getRect(placeholder);
      final paragraph = tester.renderObject<RenderParagraph>(placeholder);
      expect(well.height, scale == 1 ? 44 : greaterThanOrEqualTo(44));
      // The line is given its whole height, so no letter is cut at the
      // bottom, and it sits inside the well.
      expect(
        paragraph.size.height,
        greaterThanOrEqualTo(
          paragraph.getMaxIntrinsicHeight(paragraph.size.width) - 0.5,
        ),
      );
      expect(words.top, greaterThanOrEqualTo(well.top));
      expect(words.bottom, lessThanOrEqualTo(well.bottom));
      expect(tester.takeException(), isNull);
    });
  }
}
