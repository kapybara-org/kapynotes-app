import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';

/// Finds the Hugeicons glyph carrying [icon].
Finder findKapyIcon(KapyIconData icon) => find.byWidgetPredicate(
  (widget) => widget is KapyIcon && identical(widget.icon, icon),
  description: 'KapyIcon(${icon.codePoint.toRadixString(16)})',
);
