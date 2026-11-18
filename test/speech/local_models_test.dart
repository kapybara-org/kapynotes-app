import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/speech/local_models.dart';

void main() {
  test('every Hugging Face download is pinned to a revision, so a re-export '
      'upstream cannot break the checksum of a shipped build', () {
    final files = <DownloadableModel>[
      ...localSpeechModels,
      ...localSummaryModels,
    ].expand((model) => model.files).toList();
    expect(files, isNotEmpty);
    for (final file in files) {
      final url = Uri.parse(file.url);
      if (url.host != 'huggingface.co') continue;
      final segments = url.pathSegments;
      expect(segments.indexOf('resolve'), 2, reason: file.url);
      expect(
        segments[3],
        matches(RegExp(r'^[0-9a-f]{40}$')),
        reason: '${file.url} names a branch, not a revision',
      );
    }
  });
}
