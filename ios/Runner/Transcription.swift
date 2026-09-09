import AVFoundation
import Foundation
import Flutter

#if canImport(Speech)
  import Speech
#endif

/// Apple's own speech recogniser, turning a recording into words.
///
/// The appeal over anything we could ship is the same as `Summaries.swift`'s:
/// the model is already on the machine, so there is no download, no account,
/// no minutes, and the recording never leaves it. Two things make it
/// better than the downloaded recogniser wherever it exists at all:
///
///   * It reads the `.m4a` **directly**. `SpeechAnalyzer` takes an
///     `AVAudioFile`, so the AAC-to-PCM decode that every other platform needs
///     a channel for is the framework's problem here, not ours.
///   * It returns finalised results one sentence at a time, each carrying an
///     `audioTimeRange`, so the transcript view gets real segments without
///     anything having to guess where a sentence ended.
///
/// It is **not** Apple Intelligence and does not need it switched on, which
/// matters far more here than on the Mac: it makes on-device transcription
/// the answer for every recent iPhone rather than only the eligible ones.
/// That is why this is a separate channel from `Summaries` rather than a
/// method on it — they have different availability, and conflating them would
/// make a phone that can transcribe say it cannot.
///
/// Everything is compiled behind `canImport` and `#available` so that a build
/// on an older SDK, or a run on an older iOS, is a phone that answers
/// "unsupported" rather than one that fails to launch.
///
/// The twin of `macos/Runner/Transcription.swift`. The two runners are
/// separate targets with separate Flutter imports, which is how the rest of
/// this app's native code is arranged too.
enum Transcription {
  private static let channelName = "kapynotes/transcription"

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "availability":
        availability(call.arguments, result)
      case "transcribe":
        transcribe(call.arguments, result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  /// One of `ready`, `preparing`, `unsupported`, for the language asked about.
  ///
  /// Three answers rather than four, unlike the summariser: there is no
  /// feature for the user to switch on. Either this OS has the recogniser and
  /// covers the language, or it does not. "Preparing" is reserved for the one
  /// case that fixes itself — Apple still fetching a locale it has agreed to
  /// fetch.
  private static func availability(_ rawArguments: Any?, _ result: @escaping FlutterResult) {
    #if canImport(Speech)
      if #available(iOS 26.0, *) {
        let language = (rawArguments as? [String: Any])?["language"] as? String
        Task {
          let answer = await self.state(for: language)
          await MainActor.run { result(answer) }
        }
        return
      }
    #endif
    result("unsupported")
  }

  #if canImport(Speech)
    @available(iOS 26.0, *)
    private static func state(for language: String?) async -> String {
      guard await bestLocale(for: language) != nil else { return "unsupported" }
      return "ready"
    }

    /// The locale the recogniser should use for [language].
    ///
    /// `VoicePrefs.language` is a bare ISO-639-1 code, or nothing at all, and
    /// `SpeechTranscriber` wants a full locale. Preference order: the exact
    /// identifier if somebody passed one, then this language in the region
    /// the Mac is set to, then this language in any region at all. A German
    /// speaker in Ireland gets `de-DE` rather than nothing.
    ///
    /// Nil language means "whatever this phone is set to", falling back to
    /// English, which is the same rule the server's detection ends up at.
    @available(iOS 26.0, *)
    private static func bestLocale(for language: String?) async -> Locale? {
      let supported = await SpeechTranscriber.supportedLocales
      guard !supported.isEmpty else { return nil }

      let wanted = language?.trimmingCharacters(in: .whitespaces).lowercased()
      let current = Locale.current

      func match(_ code: String) -> Locale? {
        if let exact = supported.first(where: {
          $0.identifier(.bcp47).lowercased() == code
        }) {
          return exact
        }
        let region = current.region?.identifier
        if let regional = supported.first(where: {
          $0.language.languageCode?.identifier.lowercased() == code
            && $0.region?.identifier == region
        }) {
          return regional
        }
        return supported.first {
          $0.language.languageCode?.identifier.lowercased() == code
        }
      }

      if let wanted, !wanted.isEmpty {
        return match(wanted)
      }
      if let code = current.language.languageCode?.identifier.lowercased(),
        let here = match(code)
      {
        return here
      }
      return match("en")
    }

    /// Makes sure the locale's assets are on the machine.
    ///
    /// Apple manages these like any other system asset, and they are tens of
    /// megabytes rather than the several hundred a downloaded recogniser
    /// costs — so this is awaited rather than turned into a thing the user
    /// has to agree to. Somebody who has chosen to transcribe on this device
    /// has chosen this.
    ///
    /// Reserving keeps the OS from reclaiming the locale later. There is a
    /// cap on reservations, so failing to get one is not an error worth
    /// stopping for: it costs a re-download some day, not this transcript.
    @available(iOS 26.0, *)
    private static func install(_ locale: Locale, _ transcriber: SpeechTranscriber) async throws {
      if let request = try await AssetInventory.assetInstallationRequest(
        supporting: [transcriber])
      {
        try await request.downloadAndInstall()
      }
      _ = try? await AssetInventory.reserve(locale: locale)
    }
  #endif

  private static func transcribe(_ rawArguments: Any?, _ result: @escaping FlutterResult) {
    guard
      let arguments = rawArguments as? [String: Any],
      let path = arguments["path"] as? String,
      !path.isEmpty
    else {
      result(
        FlutterError(code: "arguments", message: "A recording is required.", details: nil))
      return
    }
    let language = arguments["language"] as? String

    #if canImport(Speech)
      if #available(iOS 26.0, *) {
        Task {
          do {
            let answer = try await run(path: path, language: language)
            await MainActor.run { result(answer) }
          } catch {
            await MainActor.run {
              result(
                FlutterError(
                  code: "failed", message: error.localizedDescription, details: nil))
            }
          }
        }
        return
      }
    #endif

    result(
      FlutterError(
        code: "unavailable",
        message: "On-device transcription is not available on this device.",
        details: nil))
  }

  #if canImport(Speech)
    /// The whole job: pick a locale, make sure it is installed, read the file.
    ///
    /// The results are collected in a task started *before* the analysis,
    /// because `transcriber.results` is a live stream: subscribing after the
    /// analyser has finished would wait for results that have already been
    /// delivered to nobody.
    @available(iOS 26.0, *)
    private static func run(path: String, language: String?) async throws -> [String: Any] {
      guard let locale = await bestLocale(for: language) else {
        throw Failure.unsupported
      }
      let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: [.audioTimeRange]
      )
      try await install(locale, transcriber)

      let analyzer = SpeechAnalyzer(modules: [transcriber])
      let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))

      let collector = Task { () -> [[String: Any]] in
        var segments: [[String: Any]] = []
        for try await result in transcriber.results where result.isFinal {
          let text = String(result.text.characters).trimmingCharacters(
            in: .whitespacesAndNewlines)
          if text.isEmpty { continue }
          var start = -1.0
          var end = -1.0
          for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            if start < 0 { start = range.start.seconds }
            end = range.end.seconds
          }
          // A result with no time range still has words in it. Losing the
          // sentence would be worse than losing where it was said, so it is
          // pinned to the end of the last one.
          let previousEnd = (segments.last?["e"] as? Int) ?? 0
          let startMs = start < 0 ? previousEnd : Int(start * 1000)
          let endMs = end < 0 ? startMs : Int(end * 1000)
          segments.append(["s": startMs, "e": max(endMs, startMs), "t": text])
        }
        return segments
      }

      _ = try await analyzer.analyzeSequence(from: file)
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      let segments = try await collector.value

      return [
        "lang": locale.language.languageCode?.identifier ?? "en",
        "segments": segments,
      ]
    }

    private enum Failure: LocalizedError {
      case unsupported

      var errorDescription: String? {
        switch self {
        case .unsupported:
          return "This device cannot transcribe that language on its own."
        }
      }
    }
  #endif
}
