import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/blob_store.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/data/note_format.dart';
import 'package:kapy_notes/images/image_clipboard.dart';
import 'package:kapy_notes/paste/clipboard_snapshot.dart';
import 'package:kapy_notes/paste/markdown_text.dart';
import 'package:kapy_notes/paste/paste_writers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const anchor = NoteAttachmentRef.placeholder;

  test('rich clipboard HTML round-trips text, emoji, and ordered images', () {
    final body = 'Hello 🐹 <&>\n$anchor then $anchor!';
    final firstOffset = body.indexOf(anchor);
    final secondOffset = body.lastIndexOf(anchor);
    final firstBytes = Uint8List.fromList([1, 2, 3, 4]);
    final secondBytes = Uint8List.fromList([5, 6, 7]);
    final fragment = NoteClipboardFragment(
      body: body,
      images: [
        ClipboardFragmentImage(
          offset: firstOffset,
          bytes: firstBytes,
          mime: 'image/png',
          width: 800,
          height: 600,
          widthFactor: 0.6,
        ),
        ClipboardFragmentImage(
          offset: secondOffset,
          bytes: secondBytes,
          mime: 'image/jpeg',
          width: 1200,
          height: 900,
          widthFactor: 1,
        ),
      ],
    );

    expect(fragment.plainText, 'Hello 🐹 <&>\n[Image] then [Image]!');
    expect(fragment.html, contains('Hello 🐹 &lt;&amp;&gt;<br>'));
    expect(fragment.html, contains('data:image/png;base64,AQIDBA=='));
    expect(fragment.html, contains('data:image/jpeg;base64,BQYH'));

    final decoded = NoteClipboardFragment.fromHtml(fragment.html)!;
    expect(decoded.body, body);
    expect(decoded.images.map((image) => image.offset), [
      firstOffset,
      secondOffset,
    ]);
    expect(listEquals(decoded.images[0].bytes, firstBytes), isTrue);
    expect(listEquals(decoded.images[1].bytes, secondBytes), isTrue);
    expect(decoded.images[0].widthFactor, 0.6);
  });

  test('foreign or incomplete HTML is not treated as a note fragment', () {
    expect(NoteClipboardFragment.fromHtml('<p>ordinary HTML</p>'), isNull);

    final fragment = NoteClipboardFragment(
      body: anchor,
      images: [
        ClipboardFragmentImage(
          offset: 0,
          bytes: Uint8List.fromList([1, 2, 3]),
          mime: 'image/png',
          width: 10,
          height: 10,
          widthFactor: 1,
        ),
      ],
    );
    expect(
      NoteClipboardFragment.fromHtml(
        fragment.html.replaceFirst(RegExp('<img[^>]+>'), ''),
      ),
      isNull,
    );
  });

  test(
    'system bridge writes all formats and reads the rich marker back',
    () async {
      const channel = MethodChannel('kapynotes/rich_clipboard');
      MethodCall? written;
      final fragment = NoteClipboardFragment(
        body: anchor,
        images: [
          ClipboardFragmentImage(
            offset: 0,
            bytes: Uint8List.fromList([1, 2, 3]),
            mime: 'image/png',
            width: 20,
            height: 10,
            widthFactor: 1,
          ),
        ],
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'write') {
              written = call;
              return null;
            }
            if (call.method == 'readHtml') return fragment.html;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      const clipboard = ImageClipboard();
      await clipboard.writeFragment(fragment);
      final arguments = written!.arguments as Map<Object?, Object?>;
      expect(written!.method, 'write');
      expect(arguments['text'], '[Image]');
      expect(arguments['html'], contains('data:image/png;base64,AQID'));
      expect(
        listEquals(arguments['image'] as Uint8List, fragment.images[0].bytes),
        isTrue,
      );

      final read = await clipboard.readFragment();
      expect(read?.body, anchor);
      expect(
        listEquals(read?.images.single.bytes, fragment.images[0].bytes),
        isTrue,
      );
    },
  );

  group('the Kapy fragment', () {
    final pictureBytes = Uint8List.fromList([1, 2, 3]);
    ClipboardFragmentImage picture(int offset, {double widthFactor = 0.5}) =>
        ClipboardFragmentImage(
          offset: offset,
          bytes: pictureBytes,
          mime: 'image/png',
          width: 40,
          height: 30,
          widthFactor: widthFactor,
        );
    ClipboardFragmentAttachment file(int offset) => ClipboardFragmentAttachment(
      ref: NoteFileRef(
        offset: offset,
        hash: 'stored-hash',
        key: Uint8List.fromList(List.filled(32, 7)),
        mime: 'application/pdf',
        bytes: 4,
        name: 'plan.pdf',
        attachmentId: 'server-id',
      ),
      bytes: Uint8List.fromList([4, 5, 6, 7]),
    );
    ClipboardFragmentAttachment voice(int offset) =>
        ClipboardFragmentAttachment(
          ref: NoteVoiceRef(
            offset: offset,
            hash: 'stored-voice',
            key: Uint8List(32),
            bytes: 2,
            durationMs: 1500,
            transcript: VoiceTranscript(
              lang: 'en',
              engine: 'local',
              at: 1,
              segments: const [TranscriptSegment(s: 0, e: 1500, t: 'hello')],
            ),
          ),
          bytes: Uint8List.fromList([8, 9]),
        );
    ClipboardFragmentAttachment video(int offset) =>
        ClipboardFragmentAttachment(
          ref: NoteVideoRef(
            offset: offset,
            hash: 'stored-video',
            key: Uint8List(32),
            mime: 'video/quicktime',
            bytes: 1,
            width: 1920,
            height: 1080,
            durationMs: 4000,
            widthFactor: 0.75,
          ),
          bytes: Uint8List.fromList([10]),
        );

    test(
      'carries the words, their styles, their kind and every attachment',
      () {
        final body = '# Trip $anchor\n**go** $anchor $anchor $anchor';
        final at = [
          for (var i = 0; i < body.length; i++)
            if (body[i] == anchor) i,
        ];
        final fragment = NoteClipboardFragment(
          body: body,
          markdown: true,
          formats: const [
            NoteFormatRange(start: 0, end: 6, format: NoteFormat.heading),
          ],
          images: [picture(at[0])],
          attachments: [file(at[1]), voice(at[2]), video(at[3])],
        );

        final decoded = NoteClipboardFragment.fromKapy(fragment.kapy)!;
        expect(decoded.body, body);
        expect(decoded.markdown, isTrue);
        expect(decoded.formats, fragment.formats);
        final image = decoded.images.single;
        expect(
          (
            image.offset,
            image.mime,
            image.width,
            image.height,
            image.widthFactor,
          ),
          (at[0], 'image/png', 40, 30, 0.5),
        );
        expect(image.bytes, pictureBytes);

        final [pdf, recording, clip] = decoded.attachments;
        final pdfRef = pdf.ref as NoteFileRef;
        expect(
          (pdfRef.offset, pdfRef.name, pdfRef.mime),
          (at[1], 'plan.pdf', 'application/pdf'),
        );
        expect(pdf.bytes, [4, 5, 6, 7]);
        final voiceRef = recording.ref as NoteVoiceRef;
        expect((voiceRef.offset, voiceRef.durationMs), (at[2], 1500));
        expect(voiceRef.transcript!.segments.single.t, 'hello');
        expect(recording.bytes, [8, 9]);
        final videoRef = clip.ref as NoteVideoRef;
        expect(
          (
            videoRef.offset,
            videoRef.mime,
            videoRef.width,
            videoRef.durationMs,
            videoRef.widthFactor,
          ),
          (at[3], 'video/quicktime', 1920, 4000, 0.75),
        );
        expect(clip.bytes, [10]);
      },
    );

    test('leaves out where the note stores its attachments and their keys', () {
      final fragment = NoteClipboardFragment(
        body: anchor,
        images: const [],
        attachments: [file(0)],
      );
      final written = jsonDecode(fragment.kapy) as Map<String, Object?>;
      final entry = (written['attachments']! as List).single as Map;
      expect(entry.keys, isNot(contains('hash')));
      expect(entry.keys, isNot(contains('key')));
      expect(entry.keys, isNot(contains('attachmentId')));
      expect(fragment.kapy, isNot(contains('server-id')));

      final decoded = NoteClipboardFragment.fromKapy(fragment.kapy)!;
      final ref = decoded.attachments.single.ref;
      expect(ref.hash, BlobStore.hashOf(Uint8List.fromList([4, 5, 6, 7])));
      expect(ref.attachmentId, isNull);
      expect(ref.key, hasLength(32));
    });

    test('reads a fragment that does not say its kind as unknown', () {
      final decoded = NoteClipboardFragment.fromKapy(
        const NoteClipboardFragment(body: 'plain', images: []).kapy,
      )!;
      expect(decoded.body, 'plain');
      expect(decoded.markdown, isNull);
    });

    test('refuses a fragment that is malformed or past the caps', () {
      final valid =
          jsonDecode(
                NoteClipboardFragment(
                  body: 'a $anchor',
                  images: const [],
                  attachments: [file(2)],
                ).kapy,
              )
              as Map<String, Object?>;
      final entry = (valid['attachments']! as List).single as Map;
      String withEntries(List<Object?> entries, {String body = 'a $anchor'}) =>
          jsonEncode({...valid, 'body': body, 'attachments': entries});

      expect(NoteClipboardFragment.fromKapy(jsonEncode(valid)), isNotNull);
      for (final source in [
        null,
        '',
        'not json',
        '[]',
        jsonEncode({...valid, 'v': 3}),
        jsonEncode({...valid, 'body': 3}),
        jsonEncode({...valid, 'markdown': 'yes'}),
        jsonEncode({...valid, 'attachments': 'none'}),
        withEntries([]),
        withEntries([
          {...entry, 'offset': 0},
        ]),
        withEntries([
          {...entry, 'offset': 9},
        ]),
        withEntries([entry, entry], body: 'a $anchor$anchor'),
        withEntries([
          {...entry, 'kind': 'sticker'},
        ]),
        withEntries([
          {...entry, 'kind': null},
        ]),
        withEntries([
          {...entry, 'data': '***'},
        ]),
        withEntries([
          {...entry, 'data': ''},
        ]),
        withEntries([
          {
            'kind': 'image',
            'offset': 2,
            'mime': 'text/html',
            'width': 1,
            'height': 1,
            'widthFactor': 1,
            'data': 'AQID',
          },
        ]),
        withEntries([
          for (var i = 0; i <= maxClipboardFragmentImages; i++)
            {...entry, 'offset': i},
        ], body: anchor * (maxClipboardFragmentImages + 1)),
        withEntries([
          {...entry, 'data': 'A' * ((maxClipboardFragmentBytes ~/ 3 + 1) * 4)},
        ]),
      ]) {
        expect(
          NoteClipboardFragment.fromKapy(source),
          isNull,
          reason: source == null || source.length < 300
              ? source
              : source.substring(0, 300),
        );
      }
    });

    test(
      'writes markdown as the plain text, with a label for each picture',
      () {
        final body = '**Hi** $anchor and $anchor';
        final images = [picture(7)];
        final attachments = [voice(13)];
        expect(
          NoteClipboardFragment(
            body: body,
            images: images,
            attachments: attachments,
            markdown: true,
          ).plainText,
          '**Hi** ![image] and [Voice note]',
        );
        expect(
          NoteClipboardFragment(
            body: body,
            images: images,
            attachments: attachments,
            markdown: false,
          ).plainText,
          '**Hi** [Image] and [Voice note]',
        );
      },
    );

    test('writes the note as HTML, each picture at the width it shows', () {
      final body = '# Trip\n$anchor\n- [ ] pack $anchor';
      final html = NoteClipboardFragment(
        body: body,
        markdown: true,
        images: [picture(7)],
        attachments: [file(body.lastIndexOf(anchor))],
      ).html;
      expect(html, startsWith('<!--kapynotes:'));
      expect(html, contains('<h1>Trip</h1>'));
      expect(
        html,
        contains(
          '<img data-kapynotes-image="0" src="data:image/png;base64,AQID" '
          'alt="image" width="360" height="270">',
        ),
      );
      expect(html, contains('☐ pack [Attachment]'));
    });

    test('writes a note without markdown as HTML with its own styles', () {
      expect(
        const NoteClipboardFragment(
          body: 'Plan\nsee *this*',
          images: [],
          markdown: false,
          formats: [
            NoteFormatRange(start: 0, end: 4, format: NoteFormat.heading),
            NoteFormatRange(start: 5, end: 8, format: NoteFormat.bold),
          ],
        ).html,
        '<h1>Plan</h1><p><b>see</b> *this*</p>',
      );
    });

    test('still carries its pictures to an older build in the HTML', () {
      final body = '$anchor then $anchor';
      final fragment = NoteClipboardFragment(
        body: body,
        markdown: true,
        images: [picture(7)],
        attachments: [file(0)],
      );
      final older = NoteClipboardFragment.fromHtml(fragment.html)!;
      expect(older.body, '[Attachment] then $anchor');
      expect(older.images.single.offset, '[Attachment] then '.length);
      expect(older.images.single.bytes, pictureBytes);
      expect(older.images.single.widthFactor, 0.5);
    });

    test('a paste prefers the fragment in its own type to the HTML', () async {
      final copied = NoteClipboardFragment(
        body: 'one $anchor',
        images: [picture(4)],
        markdown: true,
      );
      final older = NoteClipboardFragment(
        body: 'two $anchor',
        images: [picture(4)],
      );
      final preferred = await NoteClipboardFragment.fromSnapshot(
        ClipboardSnapshot(kapy: copied.kapy, html: older.html),
      );
      expect(preferred!.body, 'one $anchor');
      expect(preferred.markdown, isTrue);
      final fallback = await NoteClipboardFragment.fromSnapshot(
        ClipboardSnapshot(kapy: 'not a fragment', html: older.html),
      );
      expect(fallback!.body, 'two $anchor');
      expect(
        await NoteClipboardFragment.fromSnapshot(
          const ClipboardSnapshot(html: '<p>ordinary</p>'),
        ),
        isNull,
      );
    });

    test('writes and reads a large selection on another isolate', () async {
      const channel = MethodChannel('kapynotes/rich_clipboard');
      Map<Object?, Object?>? written;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'write') {
              written = call.arguments as Map<Object?, Object?>;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final body = '- item\n' * 6000;
      final fragment = NoteClipboardFragment(
        body: body,
        images: const [],
        markdown: true,
      );
      expect(fragment.size, greaterThanOrEqualTo(backgroundClipboardBytes));

      await const ImageClipboard().writeFragment(fragment);
      expect(written!['text'], body);
      expect(written!['html'], startsWith('<ul><li>item</li><li>item</li>'));
      final kapy = written!['kapy']! as String;
      expect(kapy.length, greaterThanOrEqualTo(backgroundClipboardBytes));
      final read = await NoteClipboardFragment.fromSnapshot(
        ClipboardSnapshot(kapy: kapy),
      );
      expect(read!.body, body);
    });

    test('markdown pasted into a note copies back out as it was', () {
      const markdown =
          '# Notes\n\n- [ ] milk\n- [x] eggs\n\n| a | b |\n| --- | --: |\n'
          '| 1 | 2 |\n\n```js\nlet x = 1;\n```\n\n'
          r'See [the docs](https://example.com) and $x^2$.';
      final note = writeMarkdownPaste(readMarkdownPaste(markdown)).text;
      expect(
        NoteClipboardFragment(
          body: note,
          images: const [],
          markdown: true,
        ).plainText,
        markdown,
      );
    });
  });
}
