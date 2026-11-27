import 'package:flutter_test/flutter_test.dart';
import 'package:kapy_notes/speech/local_models.dart';

void main() {
  final files = <DownloadableModel>[
    ...localSpeechModels,
    ...localSummaryModels,
    noiseRemovalModel,
  ].expand((model) => model.files).toList();

  test('every Hugging Face download is pinned to a revision, so a re-export '
      'upstream cannot break the checksum of a shipped build', () {
    expect(files, isNotEmpty);
    for (final file in files) {
      for (final link in file.urls) {
        final url = Uri.parse(link);
        if (url.host != 'huggingface.co') continue;
        final segments = url.pathSegments;
        expect(segments.indexOf('resolve'), 2, reason: link);
        expect(
          segments[3],
          matches(RegExp(r'^[0-9a-f]{40}$')),
          reason: '$link names a branch, not a revision',
        );
      }
    }
  });

  test('every file comes from our copy first and from the Hugging Face '
      'revision it was copied from second, at the same path', () {
    expect(files, isNotEmpty);
    for (final file in files) {
      expect(file.urls, hasLength(2), reason: file.name);
      final copy = Uri.parse(file.urls.first);
      final original = Uri.parse(file.urls.last);
      expect(original.host, 'huggingface.co', reason: file.urls.last);
      expect(copy.isScheme('https'), isTrue, reason: file.urls.first);
      expect(copy.host, 'dl.kapynotes.com', reason: file.urls.first);
      // models/<owner>/<repo>/<revision>/<file>: the original's path without
      // its `resolve`, which is how the bucket was laid out.
      expect(copy.pathSegments, [
        'models',
        ...original.pathSegments.take(2),
        ...original.pathSegments.skip(3),
      ], reason: file.urls.first);
      expect(copy.pathSegments.last, file.name);
    }
  });
}
