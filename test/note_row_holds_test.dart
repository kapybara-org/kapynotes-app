import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/core/theme.dart';
import 'package:kapy_notes/data/note.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/ui/checklist_pie.dart';
import 'package:kapy_notes/ui/notes_list.dart';
import 'package:material_ui/material_ui.dart';

import 'kapy_icon_finder.dart';
import 'test_fonts.dart';

void main() {
  setUpAll(loadTestFonts);

  final now = DateTime(2026, 11, 19, 9, 12);
  final holds = find.byKey(const ValueKey('note-row-holds'));

  Future<void> pumpRow(WidgetTester tester, Note note) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: KapyTheme.dark(),
        home: Scaffold(
          body: ListView(
            children: [
              NoteListRowFace(
                note: note,
                glance: NoteGlance.of(note, null),
                date: '09:12',
                selected: false,
                hovering: false,
                touch: true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Note morningPages() {
    const body =
        'Morning pages\nThree things: the deck, the room, a walk\n'
        '${NoteAttachmentRef.placeholder}\n☐ Book the room';
    return Note(
      id: 'pages',
      body: body,
      attachments: [
        NoteVoiceRef(
          offset: body.indexOf(NoteAttachmentRef.placeholder),
          hash: 'voice-1',
          key: Uint8List(32),
          bytes: 128,
          durationMs: 200000,
        ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  testWidgets("a phone row's third line holds what the note holds, 3 under "
      'the preview: 14 pt icons in T3, each 6 from its Figtree 12/16 words, '
      'items 12 apart', (tester) async {
    await pumpRow(tester, morningPages());
    final palette = KapyTheme.darkPalette;

    final preview = find.text('Three things: the deck, the room, a walk');
    expect(preview, findsOneWidget);
    final previewStyle = tester.widget<RichText>(
      find.descendant(of: preview, matching: find.byType(RichText)),
    );
    expect(previewStyle.text.style?.fontSize, 14);
    expect(previewStyle.text.style?.height, 20 / 14);
    expect(previewStyle.text.style?.color, palette.textSecondary);
    expect(
      find.textContaining('of 1 done'),
      findsNothing,
      reason: 'the checklist moved off the preview',
    );
    expect(tester.getTopLeft(holds).dy - tester.getBottomLeft(preview).dy, 3);
    expect(tester.getSize(holds).height, 16);

    final pie = find.descendant(of: holds, matching: find.byType(ChecklistPie));
    final tasks = find.descendant(of: holds, matching: find.text('0 of 1'));
    final mic = find.descendant(
      of: holds,
      matching: findKapyIcon(KapyIcons.micRounded),
    );
    final length = find.descendant(of: holds, matching: find.text('3:20'));
    expect(tester.getSize(pie), const Size(14, 14));
    expect(tester.getSize(mic), const Size(14, 14));
    expect(tester.widget<KapyIcon>(mic).color, palette.textTertiary);
    expect(tester.getTopLeft(tasks).dx - tester.getTopRight(pie).dx, 6);
    expect(tester.getTopLeft(mic).dx - tester.getTopRight(tasks).dx, 12);
    expect(tester.getTopLeft(length).dx - tester.getTopRight(mic).dx, 6);
    for (final words in [tasks, length]) {
      final style = tester.widget<Text>(words).style!;
      expect(style.fontFamily, AppFonts.ui);
      expect(style.fontSize, 12);
      expect(style.height, 16 / 12);
      expect(style.color, palette.textTertiary);
    }
  });

  testWidgets('a full phone row is 90 tall inside its hairlines: 12, the '
      '24 title, 3, the 20 preview, 3, the 16 holds, 12', (tester) async {
    await pumpRow(tester, morningPages());
    expect(tester.getSize(find.byType(NoteListRowFace)).height, 90);
  });

  testWidgets('a row that holds only words keeps two lines', (tester) async {
    await pumpRow(
      tester,
      Note(
        id: 'plain',
        body: 'Renewal notes\nFor the call with Acme on Friday.',
        createdAt: now,
        updatedAt: now,
      ),
    );
    expect(holds, findsNothing);
    expect(find.text('For the call with Acme on Friday.'), findsOneWidget);
    expect(
      tester.getSize(find.byType(NoteListRowFace)).height,
      12 + 24 + 3 + 20 + 12,
    );
  });
}
