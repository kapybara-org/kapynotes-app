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

  Future<void> pumpRow(
    WidgetTester tester,
    Note note, {
    Widget? people,
    String? live,
    bool viewOnly = false,
    bool locked = false,
    bool shared = false,
    double width = 393,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 852);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
                people: people,
                live: live,
                viewOnly: viewOnly,
                locked: locked,
                shared: shared,
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

  Note richest() {
    const anchor = NoteAttachmentRef.placeholder;
    final body =
        'Trip binder\nEverything for the week away\n${anchor * 9}\n'
        '${['☑ Done'].followedBy(List.filled(9, '☑ Done')).followedBy(['☐ Open', '☐ Open']).join('\n')}';
    final anchors = [
      for (var i = 0; i < body.length; i++)
        if (body[i] == anchor) i,
    ];
    final key = Uint8List(32);
    return Note(
      id: 'binder',
      body: body,
      attachments: [
        NoteVoiceRef(
          offset: anchors[0],
          hash: 'voice',
          key: key,
          bytes: 1,
          durationMs: 3700000,
        ),
        NoteVideoRef(
          offset: anchors[1],
          hash: 'video',
          key: key,
          mime: 'video/mp4',
          bytes: 1,
          width: 16,
          height: 9,
          durationMs: 95000,
        ),
        for (var i = 0; i < 7; i++)
          NoteImageRef(
            offset: anchors[2 + i],
            hash: 'picture-$i',
            key: key,
            mime: 'image/png',
            width: 4,
            height: 4,
            bytes: 1,
          ),
      ],
      createdAt: now,
      updatedAt: now,
    );
  }

  const peopleKey = ValueKey('people');
  const people = SizedBox(key: peopleKey, width: 38, height: 16);
  final peopleStrip = find.byKey(peopleKey);

  for (final withPeople in [false, true]) {
    testWidgets('the richest row at 1.62× text on a 375 pt phone cuts its '
        'last holds off rather than overflowing'
        '${withPeople ? ', and keeps its people whole at the end' : ''}', (
      tester,
    ) async {
      await pumpRow(
        tester,
        richest(),
        people: withPeople ? people : null,
        locked: true,
        shared: true,
        width: 375,
        scale: 1.62,
      );
      expect(tester.takeException(), isNull);
      expect(
        find.descendant(of: holds, matching: find.text('10 of 12')),
        findsOne,
      );
      expect(
        find.descendant(of: holds, matching: find.text('1:01:40')),
        findsOne,
      );
      if (withPeople) {
        final strip = tester.getRect(peopleStrip);
        expect(strip.size, const Size(38, 16));
        expect(strip.right, 375 - 20);
        expect(find.descendant(of: holds, matching: peopleStrip), findsOne);
      }
    });
  }

  testWidgets('with a holds line, the preview line carries no marks and no '
      'people: the marks and the people are on the holds line', (tester) async {
    await pumpRow(
      tester,
      richest(),
      people: people,
      locked: true,
      shared: true,
    );
    final previewLine = find
        .ancestor(
          of: find.text('Everything for the week away'),
          matching: find.byType(Row),
        )
        .first;
    expect(
      find.descendant(of: previewLine, matching: find.byType(KapyIcon)),
      findsNothing,
    );
    expect(
      find.descendant(of: previewLine, matching: peopleStrip),
      findsNothing,
    );
    expect(find.descendant(of: holds, matching: peopleStrip), findsOne);
    expect(
      find.descendant(of: holds, matching: findKapyIcon(KapyIcons.lockRounded)),
      findsOne,
    );
    expect(findKapyIcon(KapyIcons.groupOutlined), findsNothing);
  });

  testWidgets('a shared note with nobody to show carries no shared mark: '
      'who is typing leads its holds line after a 6 pt sage dot, in T2, and '
      'View only ends it after read-only, as 16RO-0 draws', (tester) async {
    await pumpRow(
      tester,
      morningPages(),
      live: 'Priya is typing…',
      viewOnly: true,
      locked: true,
      shared: true,
    );
    final palette = KapyTheme.darkPalette;
    expect(findKapyIcon(KapyIcons.groupOutlined), findsNothing);

    final live = find.descendant(
      of: holds,
      matching: find.byKey(const ValueKey('note-row-live')),
    );
    final typing = find.descendant(
      of: live,
      matching: find.text('Priya is typing…'),
    );
    final dot = find.descendant(of: live, matching: find.byType(Container));
    expect(tester.getSize(dot), const Size(6, 6));
    expect(
      (tester.widget<Container>(dot).decoration! as BoxDecoration).color,
      palette.accentText,
    );
    expect(tester.getTopLeft(typing).dx - tester.getTopRight(dot).dx, 6);
    final style = tester.widget<Text>(typing).style!;
    expect(style.fontSize, 12);
    expect(style.height, 16 / 12);
    expect(style.color, palette.textSecondary);
    expect(tester.getTopLeft(live).dx, 20);

    final tasks = find.descendant(of: holds, matching: find.text('0 of 1'));
    final pie = find.descendant(of: holds, matching: find.byType(ChecklistPie));
    expect(tester.getTopLeft(pie).dx - tester.getTopRight(live).dx, 12);
    expect(tasks, findsOne);

    final lock = find.descendant(
      of: holds,
      matching: findKapyIcon(KapyIcons.lockRounded),
    );
    final eye = find.descendant(
      of: holds,
      matching: findKapyIcon(KapyIcons.visibilityOutlined),
    );
    final viewOnly = find.descendant(
      of: holds,
      matching: find.text('View only'),
    );
    expect(tester.getTopLeft(eye).dx - tester.getTopRight(lock).dx, 12);
    expect(tester.getTopLeft(viewOnly).dx - tester.getTopRight(eye).dx, 6);
    expect(tester.widget<Text>(viewOnly).style!.color, palette.textTertiary);
    expect(tester.getCenter(eye).dy, tester.getCenter(holds).dy);
  });

  testWidgets('nobody in a note of words alone leaves it two lines', (
    tester,
  ) async {
    await pumpRow(
      tester,
      Note(
        id: 'plain',
        body: 'Renewal notes\nFor the call with Acme on Friday.',
        createdAt: now,
        updatedAt: now,
      ),
      shared: true,
    );
    expect(holds, findsNothing);
    expect(findKapyIcon(KapyIcons.groupOutlined), findsNothing);
  });

  testWidgets('a row of words alone that is shared keeps the people at the '
      'end of its preview line', (tester) async {
    await pumpRow(
      tester,
      Note(
        id: 'plain',
        body: 'Renewal notes\nFor the call with Acme on Friday.',
        createdAt: now,
        updatedAt: now,
      ),
      people: people,
      shared: true,
    );
    expect(holds, findsNothing);
    final previewLine = find
        .ancestor(
          of: find.text('For the call with Acme on Friday.'),
          matching: find.byType(Row),
        )
        .first;
    expect(find.descendant(of: previewLine, matching: peopleStrip), findsOne);
    expect(tester.getRect(peopleStrip).right, 393 - 20);
  });

  Note titleOnly() =>
      Note(id: 'packing', body: 'Packing list', createdAt: now, updatedAt: now);

  testWidgets('a title-only row with a bottom line goes straight from its '
      'title to it, 3 under: 12, the 24 title, 3, the 16 line, 12', (
    tester,
  ) async {
    await pumpRow(
      tester,
      titleOnly(),
      live: 'Priya is typing…',
      viewOnly: true,
      shared: true,
    );
    final title = find.text('Packing list');
    expect(holds, findsOne);
    expect(tester.getTopLeft(holds).dy - tester.getBottomLeft(title).dy, 3);
    expect(
      find.descendant(of: holds, matching: find.text('View only')),
      findsOne,
    );
    expect(
      tester.getSize(find.byType(NoteListRowFace)).height,
      12 + 24 + 3 + 16 + 12,
    );
  });

  testWidgets('a title-only row with its people puts them on the bottom line '
      'under the title', (tester) async {
    await pumpRow(tester, titleOnly(), people: people, shared: true);
    expect(find.descendant(of: holds, matching: peopleStrip), findsOne);
    expect(tester.getRect(peopleStrip).right, 393 - 20);
    expect(
      tester.getSize(find.byType(NoteListRowFace)).height,
      12 + 24 + 3 + 16 + 12,
    );
  });

  testWidgets('a title-only row with no bottom line ends at its title: 12, '
      'the 24 title, 12', (tester) async {
    await pumpRow(tester, titleOnly());
    expect(holds, findsNothing);
    expect(
      find.descendant(
        of: find.byType(NoteListRowFace),
        matching: find.byType(RichText),
      ),
      findsNWidgets(2),
      reason: 'the title and the time, with no empty preview line',
    );
    expect(tester.getSize(find.byType(NoteListRowFace)).height, 12 + 24 + 12);
  });
}
