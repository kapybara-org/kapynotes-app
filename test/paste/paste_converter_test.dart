import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/paste/clipboard_snapshot.dart';
import 'package:kapy_notes/paste/paste_converter.dart';

void main() {
  test('code a code editor copied is code, in its language', () {
    const snapshot = ClipboardSnapshot(
      text: '\n\nfinal x = 1;\n  y();\n',
      html: '<div style="color:#ccc">final x</div>',
      vscode: '{"mode":"dart"}',
    );
    final conversion = convertPaste(snapshot);
    expect(conversion.kind, PasteKind.code);
    expect(conversion.output.text, '```dart\nfinal x = 1;\n  y();\n```');
  });

  test('monospace HTML with nothing else to say is code', () {
    final conversion = convertPaste(
      const ClipboardSnapshot(
        text: 'final x = 1;',
        html:
            '<div style="font-family:Menlo, monospace;color:#333">'
            '<span style="color:#a00">final</span> x = 1;</div>',
      ),
    );
    expect(conversion.kind, PasteKind.code);
    expect(conversion.output.text, '```\nfinal x = 1;\n```');
  });

  test('HTML that carries structure wins over its words', () {
    const snapshot = ClipboardSnapshot(
      text: 'Title\nItem',
      html: '<h1>Title</h1><ul><li>Item</li></ul>',
    );
    final conversion = convertPaste(snapshot);
    expect(conversion.kind, PasteKind.html);
    expect(conversion.output.text, '# Title\n\n- Item');
  });

  test(
    'lists side by side in HTML paste tight, unless a line kept them apart',
    () {
      expect(
        convertPaste(
          const ClipboardSnapshot(
            text: 'one\ntwo',
            html: '<ul><li>one</li></ul><ol><li>two</li></ol>',
          ),
        ).output.text,
        '- one\n1. two',
      );
      expect(
        convertPaste(
          const ClipboardSnapshot(
            text: 'one\n\ntwo',
            html: '<ul><li>one</li></ul><div><br></div><ol><li>two</li></ol>',
          ),
        ).output.text,
        '- one\n\n1. two',
      );
    },
  );

  test('HTML that only wraps the words loses to them', () {
    final conversion = convertPaste(
      const ClipboardSnapshot(
        text: 'Plain words',
        html:
            '<meta charset="utf-8">'
            '<span style="color:black">Plain words</span>',
      ),
    );
    expect(conversion.kind, PasteKind.text);
    expect(conversion.output.text, 'Plain words');
  });

  test("an AI's copy-button markdown beats the HTML drawn from it", () {
    const text =
        '# Plan\n\n- **one**\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |';
    final conversion = convertPaste(
      const ClipboardSnapshot(
        text: text,
        html:
            '<h1>Plan</h1><ul><li><strong>one</strong></li><li>two</li></ul>'
            '<table><tr><th>a</th><th>b</th></tr>'
            '<tr><td>1</td><td>2</td></tr></table>',
      ),
    );
    expect(conversion.kind, PasteKind.markdown);
    expect(conversion.output.text, text);
  });

  test("a selection's words lose to its HTML, which says more", () {
    final conversion = convertPaste(
      const ClipboardSnapshot(
        text: 'Plan\none\ntwo',
        html: '<h1>Plan</h1><ul><li><strong>one</strong></li><li>two</li></ul>',
      ),
    );
    expect(conversion.kind, PasteKind.html);
    expect(conversion.output.text, '# Plan\n\n- **one**\n- two');
  });

  test('HTML with pictures keeps them, even beside markdown', () {
    final conversion = convertPaste(
      const ClipboardSnapshot(
        text: '# Plan\n\n- **one**\n- two\n\n| a | b |\n|---|---|\n| 1 | 2 |',
        html:
            '<h1>Plan</h1><p><img src="https://e.com/p.png" alt="p"></p>'
            '<ul><li><strong>one</strong></li><li>two</li></ul>',
      ),
    );
    expect(conversion.kind, PasteKind.html);
    expect(conversion.output.images, hasLength(1));
  });

  test('rich text is read when there is no HTML', () {
    final conversion = convertPaste(
      const ClipboardSnapshot(
        text: 'Big\nsmall',
        rtfHtml: '<h1>Big</h1><p>small</p>',
      ),
    );
    expect(conversion.kind, PasteKind.rtf);
    expect(conversion.output.text, '# Big\n\nsmall');
  });

  test('an empty clipboard pastes nothing', () {
    expect(convertPaste(const ClipboardSnapshot()).kind, PasteKind.nothing);
    expect(
      convertPaste(const ClipboardSnapshot(text: '  \n')).kind,
      PasteKind.nothing,
    );
  });

  test('a big paste is read off the UI isolate, to the same result', () async {
    final items = [
      for (var i = 0; i < 1000; i++) '<li>item <b>$i</b> of a long list</li>',
    ];
    final snapshot = ClipboardSnapshot(
      text: 'item',
      html: '<ul>${items.join()}</ul>',
    );
    expect(snapshot.html!.length, greaterThan(16 * 1024));
    final background = await convertPasteInBackground(snapshot);
    final direct = convertPaste(snapshot);
    expect(background.kind, PasteKind.html);
    expect(background.output.text, direct.output.text);
  });
}
