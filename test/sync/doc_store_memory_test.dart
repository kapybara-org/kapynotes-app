import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/sync/doc_store.dart';

import '../crdt/helpers.dart';

void main() {
  test(
    'loaded documents stay compact and only recent documents materialize',
    () async {
      final storage = MemoryDocStorage();
      final writer = DocStore(storage, replica: 'writer');
      await writer.load();
      for (var i = 0; i < 6; i++) {
        final record = writer.create('note-$i', 'space');
        type(record.doc, 'body $i ' * 100);
      }
      await writer.flush();
      writer.dispose();

      final reader = DocStore(storage, replica: 'reader', maxHotRecords: 2);
      await reader.load();

      expect(reader.materializedCount, 0);
      for (var i = 0; i < 6; i++) {
        expect(reader.get('note-$i')!.doc.view.body, 'body $i ' * 100);
        expect(reader.materializedCount, lessThanOrEqualTo(2));
      }
      reader.dispose();
    },
  );

  test('an op the device could not open is remembered across launches, and a '
      'half-written mark is dropped', () async {
    final storage = MemoryDocStorage();
    final writer = DocStore(storage, replica: 'writer');
    await writer.load();
    writer.create('kept', 'space')
      ..unreadSpaceId = 'space'
      ..unreadSeq = 7;
    writer.create('clean', 'space');
    await writer.flush();
    writer.dispose();

    final reader = DocStore(storage, replica: 'reader');
    await reader.load();
    expect(reader.get('kept')!.unreadSpaceId, 'space');
    expect(reader.get('kept')!.unreadSeq, 7);
    expect(reader.get('clean')!.unreadSeq, isNull);
    reader.dispose();

    final half = Map<String, Object?>.of(reader.get('kept')!.toJson())
      ..remove('unreadSpaceId');
    final record = DocRecord.fromJson('half', half, replica: 'reader')!;
    expect(record.unreadSeq, isNull);
    expect(record.unreadSpaceId, isNull);
  });
}
