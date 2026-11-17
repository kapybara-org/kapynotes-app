import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/highlighting_controller.dart';
import 'package:kapy_notes/ui/editor/note_field.dart';
import 'package:material_ui/material_ui.dart';

/// The note's text field.
final Finder noteField = find.byType(NoteField);

/// Reads and drives the note's field the way a test needs to: its text and
/// what it draws, where its caret and selection are, and typing into it the
/// way the platform's input does.
class NoteDriver {
  NoteDriver(this.tester, [Finder? field]) : field = field ?? noteField;

  final WidgetTester tester;
  final Finder field;

  NoteFieldState get state => tester.state<NoteFieldState>(field);
  HighlightingController get controller =>
      tester.widget<NoteField>(field).controller;
  TextEditingValue get value => controller.value;

  /// The whole note as the field draws it, line by line.
  TextSpan get span => controller.buildTextSpan(
    context: tester.element(field),
    style: tester.widget<NoteField>(field).style,
    withComposing: false,
  );

  RenderBox get _box => state.box!;
  Size get size => _box.size;

  /// How wide the writing runs.
  double get columnWidth => state.layout.width!;

  /// A row of the note's base style.
  double get rowHeight => state.layout.rowHeight;

  /// What the selection is highlighted in while it shows.
  Color? get selectionColor => state.layout.marks.selectionColor;

  /// From the field's coordinates to the screen's.
  Offset toGlobal(Offset local) => _box.localToGlobal(local);

  /// The caret at [position], in the field's coordinates.
  Rect caretRect(TextPosition position) => state.caretRectAt(position)!;

  /// The boxes around [selection], row by row, in the field's coordinates.
  List<TextBox> boxesFor(TextSelection selection) => state.boxesFor(selection);
}

extension NoteTyping on WidgetTester {
  /// Focuses the note's field and opens its connection to the platform's
  /// text input, as [WidgetTester.showKeyboard] does for a [TextField].
  Future<void> showNoteKeyboard([Finder? field]) async {
    state<NoteFieldState>(field ?? noteField).requestKeyboard();
    await pump();
  }

  /// Replaces the note's text with [text], with the caret after it, through
  /// the platform's text input, as [WidgetTester.enterText] does for a
  /// [TextField].
  Future<void> enterNote(String text, [Finder? field]) async {
    await showNoteKeyboard(field);
    testTextInput.enterText(text);
    await idle();
  }
}
