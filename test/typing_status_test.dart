import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/ui/editor/note_footer.dart';

void main() {
  test('typing status stays concise as collaborators join', () {
    expect(typingStatusText(const []), isNull);
    expect(typingStatusText(const ['Alice']), 'Alice is typing...');
    expect(
      typingStatusText(const ['Alice', 'Bob']),
      'Alice and Bob are typing...',
    );
    expect(
      typingStatusText(const ['Alice', 'Bob', 'Carol']),
      'Alice and 2 others are typing...',
    );
  });
}
