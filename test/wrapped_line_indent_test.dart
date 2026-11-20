import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/calc/engine.dart';
import 'package:kapy_notes/calc/highlight.dart';
import 'package:kapy_notes/core/editor_font.dart';
import 'package:kapy_notes/core/platform.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/local_store.dart';
import 'package:kapy_notes/data/shortcut_prefs.dart';
import 'package:kapy_notes/ui/editor/note_editor.dart';
import 'package:kapy_notes/ui/editor/task_details_chrome.dart';
import 'package:material_ui/material_ui.dart';

import 'support/note_driver.dart';
import 'test_fonts.dart';

class _MemoryStore extends LocalStore {
  _MemoryStore() : super(fileName: 'wrapped-line-indent-test.json');

  @override
  Future<void> load() async {}

  @override
  Future<void> flush() async {}

  @override
  void put(String key, Object? value) => data[key] = value;
}

const _long =
    'The menu stays up. After a few seconds it should shrink to a pill and go.';
const _task = '☐ $_long';
const _details = '  $_long $_long';
const _bullet = '- $_long';
const _body = 'Friday\n$_task\n$_details\n$_bullet\nPlain';

final _shot = GlobalKey();

void main() {
  setUpAll(loadTestFonts);

  for (final (name, platform, width) in [
    ('phone', TargetPlatform.iOS, 390.0),
    ('narrow desktop window', TargetPlatform.macOS, 480.0),
  ]) {
    group('on a $name', () {
      setUp(() => AppPlatform.debugTargetPlatformOverride = platform);
      tearDown(() => AppPlatform.debugTargetPlatformOverride = null);

      Future<NoteDriver> pumpNote(WidgetTester tester) async {
        final engine = CalcEngine(ratesPerUsd: const {'EUR': 0.86});
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: KapyTheme.dark(),
            home: RepaintBoundary(
              key: _shot,
              child: Scaffold(
                body: NoteEditor(
                  noteId: 'wrapped-indent',
                  initialBody: _body,
                  initialFormats: const [],
                  resultsVisible: true,
                  writingFont: WritingFont.clean,
                  engine: engine,
                  highlighter: Highlighter(engine.registry),
                  onDocumentChanged: (body, formats, attachments, edit) {},
                  onSettingsPressed: () {},
                  shortcuts: ShortcutPrefs(_MemoryStore()),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final driver = NoteDriver(tester);
        driver.controller.selection = TextSelection.collapsed(
          offset: _body.indexOf(_details) + 5,
        );
        await tester.pumpAndSettle();
        return driver;
      }

      testWidgets(
        'a wrapped details line keeps its later rows under its words, right '
        'of the rule',
        (tester) async {
          final driver = await pumpNote(tester);
          final line = _rowsOf(driver, _details, words: 2);
          expect(line.rows.length, greaterThan(1));
          final rule = tester.getRect(
            find.descendant(
              of: find.byType(TaskDetailsChrome),
              matching: find.byType(DecoratedBox),
            ),
          );
          final ink = await _inkLefts(tester, driver, line.rows, skip: rule);
          for (final row in line.rows.skip(1)) {
            expect(row.left, closeTo(line.words, 0.5));
          }
          for (final left in ink.skip(1)) {
            expect(left, greaterThan(rule.right));
            expect(left, closeTo(ink.first, 3));
          }
          final last = line.rows.last;
          expect(
            rule.bottom,
            greaterThan(
              driver.toGlobal(Offset(0, (last.top + last.bottom) / 2)).dy,
            ),
          );
          await tester.pump(const Duration(seconds: 3));
        },
      );

      testWidgets(
        'a wrapped task keeps its later rows under its words, not the box',
        (tester) async {
          final driver = await pumpNote(tester);
          final line = _rowsOf(driver, _task, words: 2);
          expect(line.rows.length, greaterThan(1));
          final ink = await _inkLefts(tester, driver, line.rows.sublist(1));
          for (final row in line.rows.skip(1)) {
            expect(row.left, closeTo(line.words, 0.5));
          }
          for (final left in ink) {
            expect(left, closeTo(driver.toGlobal(Offset(line.words, 0)).dx, 3));
          }
          await tester.pump(const Duration(seconds: 3));
        },
      );

      testWidgets('a wrapped bullet keeps its later rows under its words', (
        tester,
      ) async {
        final driver = await pumpNote(tester);
        final line = _rowsOf(driver, _bullet, words: 2);
        expect(line.rows.length, greaterThan(1));
        for (final row in line.rows.skip(1)) {
          expect(row.left, closeTo(line.words, 0.5));
        }
        await tester.pump(const Duration(seconds: 3));
      });

      testWidgets(
        'the caret and a tap on a wrapped details row land on its words',
        (tester) async {
          final driver = await pumpNote(tester);
          final line = _rowsOf(driver, _details, words: 2);
          final first = line.rows[1].start;
          final caret = driver.caretRect(TextPosition(offset: first));
          expect(caret.left, closeTo(line.words, 1));
          expect(caret.top, greaterThanOrEqualTo(line.rows[1].top));
          expect(caret.bottom, lessThanOrEqualTo(line.rows[1].bottom));

          final inside = first + 3;
          final glyph = driver
              .boxesFor(
                TextSelection(baseOffset: inside, extentOffset: inside + 1),
              )
              .single;
          expect(
            driver.caretRect(TextPosition(offset: inside)).left,
            closeTo(glyph.left, 1),
          );
          final at = driver.state.positionAt(
            driver.toGlobal(
              Offset(glyph.left + 1, (glyph.top + glyph.bottom) / 2),
            ),
          );
          expect(at.offset, inside);
          await tester.pump(const Duration(seconds: 3));
        },
      );
    });
  }
}

typedef _Row = ({int start, double left, double top, double bottom});

/// The rows [line] wraps onto, each with its first character and the left of
/// its writing, and where its words start on the first, past [words]
/// characters of marker or indent; all in the field's coordinates.
({List<_Row> rows, double words}) _rowsOf(
  NoteDriver driver,
  String line, {
  required int words,
}) {
  final start = _body.indexOf(line);
  final rows = <_Row>[];
  for (var at = start + words; at < start + line.length; at++) {
    if (_body[at] == ' ') continue;
    final box = driver
        .boxesFor(TextSelection(baseOffset: at, extentOffset: at + 1))
        .first;
    if (rows.isEmpty || box.top > rows.last.top + 1) {
      rows.add((start: at, left: box.left, top: box.top, bottom: box.bottom));
    }
  }
  return (rows: rows, words: rows.first.left);
}

/// Where the first painted pixel of each of [rows] is on screen, left of
/// which only the background shows, passing over [skip].
Future<List<int>> _inkLefts(
  WidgetTester tester,
  NoteDriver driver,
  List<_Row> rows, {
  Rect? skip,
}) async {
  final boundary =
      _shot.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = (await tester.runAsync(() => boundary.toImage()))!;
  final bytes = (await tester.runAsync(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  ))!;
  final width = image.width;
  image.dispose();
  int pixel(int x, int y) => bytes.getUint32((y * width + x) * 4);
  final lefts = <int>[];
  for (final row in rows) {
    final top = driver.toGlobal(Offset(0, row.top)).dy.ceil() + 2;
    final bottom = driver.toGlobal(Offset(0, row.bottom)).dy.floor() - 2;
    final background = pixel(width - 2, (top + bottom) ~/ 2);
    var left = -1;
    for (var x = 0; x < width - 2 && left < 0; x++) {
      if (skip != null && x >= skip.left - 1 && x <= skip.right + 1) continue;
      for (var y = top; y <= bottom; y++) {
        if (pixel(x, y) != background) {
          left = x;
          break;
        }
      }
    }
    lefts.add(left);
  }
  return lefts;
}
