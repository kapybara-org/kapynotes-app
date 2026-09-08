import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/data/note_attachment.dart';
import 'package:kapy_notes/images/image_clipboard.dart';

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
}
