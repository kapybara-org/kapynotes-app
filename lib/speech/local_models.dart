/// The models that can be downloaded to run here rather than on the server:
/// one that turns speech into words, one that turns words into a summary.
///
/// This file is data and nothing else: no I/O, no plugins, no Flutter. What a
/// model *is* — its bytes, its checksums, how good it is and how fast — is a
/// fact about the world that a downloader, a settings card and, later, the
/// recogniser all need, and none of them should own it.
///
/// Every number here was read off the publisher's own model card or a
/// published benchmark, and each carries the source it came from so the
/// settings card can say where it got it. Nothing is our own measurement,
/// because there is nothing of ours to measure yet — see [LocalSpeechModel].
library;

/// One file a model is made of.
///
/// [sha256] is the whole reason a model may be fetched from someone else's
/// CDN: the bytes are checked against a hash compiled into the app, so the
/// host is never trusted, only the content.
class LocalModelFile {
  const LocalModelFile({
    required this.name,
    required this.url,
    required this.bytes,
    required this.sha256,
  });

  /// What it is called on disk, inside the model's own directory.
  final String name;
  final String url;

  /// The exact length, known ahead of time so progress is real from the first
  /// byte and a truncated download is caught without hashing.
  final int bytes;

  /// Lowercase hex, sha256 of the complete file.
  final String sha256;
}

/// One figure on a model's card, and what it means.
class ModelStat {
  const ModelStat(this.value, this.label);

  final String value;
  final String label;
}

/// Terms somebody has to agree to before a model may be downloaded.
///
/// Only some models carry these. Gemma does: its licence lets us redistribute
/// the weights on the condition that the terms travel with them, so the app
/// is the thing that has to show them.
class ModelTerms {
  const ModelTerms({
    required this.version,
    required this.summary,
    required this.links,
  });

  /// Raised when the wording changes, which asks again. An old agreement was
  /// to a different set of words.
  final int version;

  /// What agreeing means, in plain sentences.
  final String summary;

  /// The documents themselves, which have to be reachable, not merely named.
  final List<({String label, String url})> links;
}

/// Anything the app can download, keep, verify and delete.
///
/// The store below knows only this much — an id, some files and their
/// checksums — which is why one downloader serves a speech recogniser and a
/// language model without knowing what either of them is for. Everything the
/// settings card draws is here too, so adding a model is one entry in one
/// file rather than an entry plus a widget that knows about it.
abstract class DownloadableModel {
  /// Stable, and used as the directory name on disk.
  String get id;
  String get name;
  String get vendor;

  /// The header's second line: what this is, in a few words.
  String get subtitle;

  /// One sentence for someone deciding whether to spend the download on it.
  String get summary;

  /// The four figures people choose on.
  List<ModelStat> get stats;

  /// The small print under the card: where the numbers came from.
  String get detail;

  /// What the model is made of, ending in the separator before its licence,
  /// which the card appends as a link.
  String get credit;

  /// SPDX identifier or licence name. Shown, and linked.
  String get license;
  String get licenseUrl;

  /// Null when downloading it obliges the user to nothing.
  ModelTerms? get terms;

  List<LocalModelFile> get files;

  /// The whole download, which is what the user is actually agreeing to.
  int get bytes;
}

/// A speech model that runs on this device.
class LocalSpeechModel implements DownloadableModel {
  const LocalSpeechModel({
    required this.id,
    required this.name,
    required this.vendor,
    required this.parameters,
    required this.architecture,
    required this.license,
    required this.licenseUrl,
    required this.summary,
    required this.languages,
    required this.englishWordErrorRate,
    required this.multilingualWordErrorRate,
    required this.accuracySource,
    required this.speedFactor,
    required this.speedSource,
    required this.files,
  });

  /// Stable, and used as the directory name on disk. Includes the precision,
  /// because a float and an int8 export of the same model are different
  /// downloads with different hashes and different accuracy.
  @override
  final String id;
  @override
  final String name;
  @override
  final String vendor;

  /// Written the way the publisher writes it, e.g. `600M`.
  final String parameters;
  final String architecture;

  /// SPDX identifier. CC-BY models must be credited somewhere the user can
  /// see; this app has no acknowledgements screen, so the model card is it.
  @override
  final String license;
  @override
  final String licenseUrl;

  /// One sentence for someone deciding whether to spend the download on it.
  @override
  final String summary;

  /// Every language it can transcribe, in English, publisher's order.
  final List<String> languages;

  /// Word error rate as a percentage — lower is better. English is measured
  /// on a different benchmark from the multilingual figure, so the two are
  /// not comparable with each other, only with other models on the same one.
  final double englishWordErrorRate;
  final double multilingualWordErrorRate;
  final String accuracySource;

  /// How many times faster than real time, i.e. a 10-minute recording in
  /// [speedFactor] tenths of a minute. Deliberately not the publisher's
  /// datacentre-GPU number, which tells a laptop user nothing.
  final int speedFactor;
  final String speedSource;

  @override
  final List<LocalModelFile> files;

  /// Whether it can do more than one language at all. The card says "25
  /// languages" rather than "multilingual" where there is room, but the
  /// yes/no is what a search or a filter would want.
  bool get isMultilingual => languages.length > 1;

  @override
  int get bytes => files.fold(0, (total, file) => total + file.bytes);

  /// Nothing to agree to: every recogniser we offer is permissively licensed.
  @override
  ModelTerms? get terms => null;

  @override
  String get subtitle => '$vendor · runs here, with no account and no minutes';

  @override
  List<ModelStat> get stats => [
    ModelStat(fileSize(bytes), 'to download'),
    ModelStat('${languages.length} languages', 'multilingual'),
    ModelStat(
      '${percent(englishWordErrorRate)} errors',
      'transcribing English',
    ),
    ModelStat('$speedFactor× real time', 'on a laptop CPU'),
  ];

  @override
  String get credit => '$parameters parameters · $architecture · $vendor · ';

  @override
  String get detail =>
      'Accuracy is $accuracySource: ${percent(englishWordErrorRate)} word '
      'errors in English and ${percent(multilingualWordErrorRate)} across all '
      '${languages.length} languages. Speed is for $speedSource; a phone is '
      'slower.';
}

/// A download's size, decimal, the way every other download is advertised.
///
/// Gigabytes past a thousand megabytes: "2.6 GB" is a number people can hold,
/// and "2588 MB" is one they have to convert before they can decide.
String fileSize(int bytes) {
  if (bytes >= 1000000000) {
    return '${(bytes / 1000000000).toStringAsFixed(1)} GB';
  }
  return '${(bytes / 1000000).round()} MB';
}

/// One decimal place, which is the precision these benchmarks are quoted to.
String percent(double value) => '${value.toStringAsFixed(1)}%';

/// Every model on offer, best first.
///
/// One entry for now. The list exists rather than a constant because the
/// second model is a different trade — smaller and English-only, or larger
/// and more accurate — and the settings card is already written to show a
/// list so that adding one is an entry here and nothing else.
const List<LocalSpeechModel> localSpeechModels = <LocalSpeechModel>[
  parakeetTdt06bV3Int8,
];

/// NVIDIA's Parakeet TDT 0.6B v3, quantised to int8 and exported to ONNX by
/// the sherpa-onnx project — the export the recogniser will load.
///
/// Served from Hugging Face, which is where the sherpa-onnx maintainer
/// publishes it. Our own mirror would cost 670 MB of storage and buy nothing
/// while [LocalModelFile.sha256] is checked on arrival: a CDN that served the
/// wrong bytes would fail verification exactly as a hostile one would.
const LocalSpeechModel parakeetTdt06bV3Int8 = LocalSpeechModel(
  id: 'parakeet-tdt-0.6b-v3-int8',
  name: 'Parakeet TDT 0.6B v3',
  vendor: 'NVIDIA',
  parameters: '600M',
  architecture: 'FastConformer-TDT',
  license: 'CC-BY-4.0',
  licenseUrl: 'https://creativecommons.org/licenses/by/4.0/',
  summary:
      'Transcribes 25 European languages on the device, with no account, no '
      'minutes, and no recording leaving it.',
  languages: <String>[
    'Bulgarian',
    'Croatian',
    'Czech',
    'Danish',
    'Dutch',
    'English',
    'Estonian',
    'Finnish',
    'French',
    'German',
    'Greek',
    'Hungarian',
    'Italian',
    'Latvian',
    'Lithuanian',
    'Maltese',
    'Polish',
    'Portuguese',
    'Romanian',
    'Slovak',
    'Slovenian',
    'Spanish',
    'Swedish',
    'Russian',
    'Ukrainian',
  ],
  // 6.34% averaged over the eight datasets of the Open ASR Leaderboard;
  // 11.97% averaged over FLEURS, which is 100-odd languages of read speech
  // and a much harder test than the English one.
  englishWordErrorRate: 6.34,
  multilingualWordErrorRate: 11.97,
  accuracySource: 'NVIDIA, on Open ASR Leaderboard and FLEURS',
  // The publisher advertises RTFx 3332 on an A100, which is true and useless
  // here. The published CPU figures — RTF 0.0476 on Apple silicon, 0.0382 on
  // an 8-vCPU EPYC — read as about 20x, and **this app does not reach them**.
  // Running this exact pack through this app's own recogniser on an M-series
  // Mac, on 56 s of speech: 5.1x at two threads, 9.3x at four, 11.8x at
  // eight. Four threads is what ships, so nine is what the card promises.
  //
  // Nine is the inference rate. End to end — decode, model load, two windows
  // of a 169 s recording — a debug build measured 7.3x, and the gap is the
  // one-off ~2.5 s of loading a 652 MB encoder, which matters less the longer
  // the recording is and the longer somebody is really waiting. A phone is
  // slower again, which the sentence below says.
  //
  // Corrected from 20 on 2026-09-09, when the engine that reads this model
  // existed for the first time and the number could be measured rather than
  // quoted.
  speedFactor: 9,
  speedSource: 'this app, on an M-series Mac',
  files: <LocalModelFile>[
    LocalModelFile(
      name: 'encoder.int8.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/encoder.int8.onnx',
      bytes: 652184281,
      sha256:
          'acfc2b4456377e15d04f0243af540b7fe7c992f8d898d751cf134c3a55fd2247',
    ),
    LocalModelFile(
      name: 'decoder.int8.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/decoder.int8.onnx',
      bytes: 11845275,
      sha256:
          '179e50c43d1a9de79c8a24149a2f9bac6eb5981823f2a2ed88d655b24248db4e',
    ),
    LocalModelFile(
      name: 'joiner.int8.onnx',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/joiner.int8.onnx',
      bytes: 6355277,
      sha256:
          '3164c13fc2821009440d20fcb5fdc78bff28b4db2f8d0f0b329101719c0948b3',
    ),
    LocalModelFile(
      name: 'tokens.txt',
      url:
          'https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/tokens.txt',
      bytes: 93939,
      sha256:
          'd58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d',
    ),
  ],
);

/// A language model that writes the summary, for devices with no platform
/// model of their own.
///
/// Everything about it is a compromise against the server's 70B: it is a
/// billion parameters quantised to four bits, it reads a few thousand tokens
/// at a time, and it will sometimes miss the point of a long recording. What
/// it buys is that it works with no account, no minutes, no network, and
/// without the transcript leaving the machine — on Windows and Linux and on
/// every Mac and phone that Apple Intelligence does not cover.
class LocalSummaryModel implements DownloadableModel {
  const LocalSummaryModel({
    required this.id,
    required this.name,
    required this.vendor,
    required this.parameters,
    required this.quantisation,
    required this.contextTokens,
    required this.license,
    required this.licenseUrl,
    required this.summary,
    required this.detail,
    required this.terms,
    required this.files,
    required this.minimumMemoryBytes,
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final String vendor;

  final String parameters;
  final String quantisation;

  /// How much transcript this build can hold at once, in tokens. Not the
  /// architecture's limit — the limit of the bundle we actually ship, which
  /// is the number that decides whether a long recording has to be cut.
  final int contextTokens;

  @override
  final String license;
  @override
  final String licenseUrl;
  @override
  final String summary;
  @override
  final String detail;
  @override
  final ModelTerms? terms;
  @override
  final List<LocalModelFile> files;

  /// What the device needs to load it without being killed.
  ///
  /// Offering a 584 MB download to a phone that cannot run it is worse than
  /// not offering it: it costs somebody their data and their disk to learn
  /// that. Checked before the Download button is enabled.
  final int minimumMemoryBytes;

  @override
  int get bytes => files.fold(0, (total, file) => total + file.bytes);

  @override
  String get subtitle => '$vendor · writes summaries with no account';

  @override
  String get credit => '$parameters parameters · $quantisation · $vendor · ';

  @override
  List<ModelStat> get stats => [
    ModelStat(fileSize(bytes), 'to download'),
    ModelStat('$parameters parameters', '$quantisation, by $vendor'),
    ModelStat('${_thousands(contextTokens)} tokens', 'of transcript at a time'),
    ModelStat('Offline', 'nothing is uploaded'),
  ];

  static String _thousands(int value) {
    final digits = value.toString();
    final buffer = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(',');
      buffer.write(digits[i]);
    }
    return buffer.toString();
  }
}

/// Every summary model on offer.
const List<LocalSummaryModel> localSummaryModels = <LocalSummaryModel>[
  gemma4E2bIt,
];

/// Google's Gemma 4 E2B, instruction-tuned, in the LiteRT-LM bundle that runs
/// on all five platforms.
///
/// Served from Hugging Face rather than our own mirror, for the same reason
/// Parakeet is: the checksum below is compiled into the app, so the host is
/// never trusted, only the content. A mirror was planned while the smaller
/// Gemma 3 was the candidate and its weights were behind a licence gate;
/// these are not, so mirroring would have bought storage and a second thing
/// to keep in sync and nothing else.
///
/// Chosen over the smaller Gemma 3 1B after measuring both trades. It is a
/// four-times larger download and a better summariser by a wide margin, and —
/// the part that decides it — its *runtime* cost is lower, not higher: the
/// embedding parameters are memory-mapped rather than resident, so peak RAM is
/// around 600–800 MB on a phone against the gigabyte-plus a naive 1B int4
/// would hold. It is also Apache-2.0 and ungated, where Gemma 3 1B is behind
/// a licence gate that would have made us a redistributor with terms to pass
/// on. The one thing it costs is 2.6 GB of somebody's disk and data.
const LocalSummaryModel gemma4E2bIt = LocalSummaryModel(
  id: 'gemma-4-e2b-it-litertlm',
  name: 'Gemma 4 E2B',
  vendor: 'Google',
  parameters: '2B effective',
  quantisation: 'mixed 2/4/8-bit',
  // The bundle supports 32K. This is what we ask for, and it is the number
  // that decides both how much transcript fits and how big the KV cache is:
  // a summariser has no use for the rest and every token of it costs memory.
  contextTokens: 4096,
  license: 'Apache-2.0',
  licenseUrl: 'https://ai.google.dev/gemma/docs/gemma_4_license',
  summary:
      'Writes the summary on this device, so a recording can be turned into '
      'notes with no account and no network at all.',
  detail:
      'Quantisation-aware trained at a mixture of 2, 4 and 8 bits. Its '
      'embeddings are read from disk rather than held in memory, which is why '
      'a 2.6 GB model needs well under a gigabyte to run. Loaded only while a '
      'summary is being written, then unloaded again.',
  // Apache-2.0 asks nothing of a user, so there is nothing to agree to. The
  // mechanism stays for a model that does.
  terms: null,
  // Peak measured by the publisher at 607 MB on an iPhone 17 Pro and 1.5 GB
  // on a Raspberry Pi 5. Three gigabytes of device memory leaves room for
  // that and for the rest of the app.
  minimumMemoryBytes: 3 * 1000 * 1000 * 1000,
  files: [
    LocalModelFile(
      name: 'gemma-4-E2B-it.litertlm',
      url:
          'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
      bytes: 2588147712,
      sha256:
          '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
    ),
  ],
);
