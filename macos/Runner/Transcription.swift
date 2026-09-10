import AVFoundation
import Foundation
import FlutterMacOS

#if canImport(Speech)
  import Speech
#endif

/// Apple's own speech recognisers, turning a recording into words.
///
/// The appeal over anything we could ship is the same as `Summaries.swift`'s:
/// the model is already on the machine, so there is no download, no account,
/// no minutes, and the recording never leaves the device. There are two of
/// them, and between them they cover every Mac this app runs on:
///
///   * **`SpeechAnalyzer`**, from macOS 26. It reads the `.m4a` directly, and
///     it returns finalised results one sentence at a time, each carrying an
///     `audioTimeRange`, so the transcript view gets real segments without
///     anything having to guess where a sentence ended.
///   * **`SFSpeechRecognizer`**, on-device, from macOS 10.15. Older and a
///     little less accurate, and it answers with words rather than sentences,
///     so Dart groups them. Its one real limit is length: measured here, a
///     56 s recording came back whole and a 169 s one came back as its last
///     48 s. So the recording is fed to it in windows of under a minute, cut
///     at the quietest moment near the end of each, and the windows' words
///     are joined with their times offset — the same shape the downloaded
///     recogniser used on the other platforms.
///
/// Neither is Apple Intelligence and neither needs it switched on: measured
/// on a Mac with the feature off, nine English locales were installed for
/// the first and five for the second. That is why this is a separate channel
/// from `Summaries` rather than a method on it — they have different
/// availability, and conflating them would make a Mac that can transcribe
/// say it cannot.
///
/// Having both is what let the downloaded recogniser leave the Mac and iPhone
/// builds altogether: its runtime was 56 MB that `dyld` mapped at every
/// launch, for a job the OS already does.
///
/// Everything is compiled behind `canImport` and `#available` so that a build
/// on an older SDK, or a run on an older macOS, is a Mac that answers with
/// the recogniser it has rather than one that fails to launch.
enum Transcription {
  private static let channelName = "kapynotes/transcription"

  /// What the transcript records as its author, per engine.
  private static let analyzerEngine = "apple/speech-analyzer"
  private static let recognizerEngine = "apple/speech-recognizer"

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

  /// One of `ready`, `preparing`, `denied`, `unsupported`, for the language
  /// asked about.
  ///
  /// "Preparing" is reserved for the one case that fixes itself — Apple
  /// still fetching a locale it has agreed to fetch. "Denied" is the older
  /// recogniser's permission, refused: the only one of these the user can
  /// change, and the settings row says where.
  private static func availability(_ rawArguments: Any?, _ result: @escaping FlutterResult) {
    let arguments = rawArguments as? [String: Any]
    let language = arguments?["language"] as? String
    let forced = arguments?["engine"] as? String
    #if canImport(Speech)
      Task {
        let answer = await self.state(for: language, forcing: forced)
        await MainActor.run { result(answer) }
      }
    #else
      result("unsupported")
    #endif
  }

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
    let forced = arguments["engine"] as? String

    #if canImport(Speech)
      Task {
        do {
          let answer = try await run(path: path, language: language, forcing: forced)
          await MainActor.run { result(answer) }
        } catch let failure as Failure {
          await MainActor.run {
            result(FlutterError(code: failure.code, message: failure.errorDescription, details: nil))
          }
        } catch {
          await MainActor.run {
            result(
              FlutterError(code: "failed", message: error.localizedDescription, details: nil))
          }
        }
      }
    #else
      result(
        FlutterError(
          code: "unavailable",
          message: "On-device transcription is not available on this device.",
          details: nil))
    #endif
  }

  #if canImport(Speech)
    /// The newer recogniser where it exists and covers the language; the
    /// older one otherwise. `forcing` is a test's way of asking for the
    /// older one on a machine that has both — Dart only sends it from a
    /// build made with `--dart-define=KAPY_APPLE_SPEECH=legacy`.
    private static func state(for language: String?, forcing: String?) async -> String {
      if #available(macOS 26.0, *), forcing != "legacy" {
        if await analyzerLocale(for: language) != nil { return "ready" }
      }
      return Legacy.state(for: language)
    }

    private static func run(path: String, language: String?, forcing: String?) async throws
      -> [String: Any]
    {
      if #available(macOS 26.0, *), forcing != "legacy",
        let locale = await analyzerLocale(for: language)
      {
        return try await analyze(path: path, locale: locale)
      }
      return try await Legacy.run(path: path, language: language)
    }

    /// The locale a recogniser should use for [language], out of the ones it
    /// supports.
    ///
    /// `VoicePrefs.language` is a bare ISO-639-1 code, or nothing at all, and
    /// the recognisers want a full locale. Preference order: the exact
    /// identifier if somebody passed one, then this language in the region
    /// the Mac is set to, then this language in any region at all. A German
    /// speaker in Ireland gets `de-DE` rather than nothing.
    ///
    /// Nil language means "whatever this machine is set to", falling back to
    /// English, which is the same rule the server's detection ends up at.
    fileprivate static func bestLocale(for language: String?, among supported: [Locale])
      -> Locale?
    {
      guard !supported.isEmpty else { return nil }
      let wanted = language?.trimmingCharacters(in: .whitespaces).lowercased()
      let current = Locale.current

      func tag(_ locale: Locale) -> String {
        locale.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
      }
      func languageOf(_ locale: Locale) -> String? { locale.languageCode?.lowercased() }

      func match(_ code: String) -> Locale? {
        if let exact = supported.first(where: { tag($0) == code }) {
          return exact
        }
        let region = current.regionCode
        if let regional = supported.first(where: {
          languageOf($0) == code && $0.regionCode == region
        }) {
          return regional
        }
        return supported.first { languageOf($0) == code }
      }

      if let wanted, !wanted.isEmpty {
        return match(wanted)
      }
      if let here = current.languageCode?.lowercased(), let found = match(here) {
        return found
      }
      return match("en")
    }

    // MARK: - SpeechAnalyzer, macOS 26

    @available(macOS 26.0, *)
    private static func analyzerLocale(for language: String?) async -> Locale? {
      bestLocale(for: language, among: await SpeechTranscriber.supportedLocales)
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
    @available(macOS 26.0, *)
    private static func install(_ locale: Locale, _ transcriber: SpeechTranscriber) async throws {
      if let request = try await AssetInventory.assetInstallationRequest(
        supporting: [transcriber])
      {
        try await request.downloadAndInstall()
      }
      _ = try? await AssetInventory.reserve(locale: locale)
    }

    /// The whole job: make sure the locale is installed, read the file.
    ///
    /// The results are collected in a task started *before* the analysis,
    /// because `transcriber.results` is a live stream: subscribing after the
    /// analyser has finished would wait for results that have already been
    /// delivered to nobody.
    @available(macOS 26.0, *)
    private static func analyze(path: String, locale: Locale) async throws -> [String: Any] {
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
        "lang": locale.languageCode ?? "en",
        "engine": analyzerEngine,
        "segments": segments,
      ]
    }

    // MARK: - SFSpeechRecognizer, on-device, everything older

    private enum Legacy {
      /// A window the recogniser is known to return whole, with room to
      /// spare under the minute it was measured to lose the start of.
      static let windowSeconds = 50.0
      /// How far back from the window's nominal end to look for a pause.
      static let searchSeconds = 10.0

      /// The locales this machine can recognise without a network.
      ///
      /// `supportedLocales()` lists what the framework knows; whether the
      /// *on-device* model for one is installed is a per-recogniser answer,
      /// and it is that answer the user's language is matched against.
      static func locales() -> [Locale] {
        SFSpeechRecognizer.supportedLocales().filter {
          SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true
        }
      }

      static func state(for language: String?) -> String {
        guard bestLocale(for: language, among: locales()) != nil else { return "unsupported" }
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
          return "denied"
        default:
          return "ready"
        }
      }

      /// The one permission either recogniser needs. Asked at the first
      /// transcript, not at launch, and not by `availability`: a user who
      /// never chose this device should never see the dialog.
      static func authorize() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
          SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status == .authorized)
          }
        }
      }

      static func run(path: String, language: String?) async throws -> [String: Any] {
        guard
          let locale = bestLocale(for: language, among: locales()),
          let recognizer = SFSpeechRecognizer(locale: locale),
          recognizer.supportsOnDeviceRecognition
        else {
          throw Failure.unsupported
        }
        guard await authorize() else { throw Failure.denied }

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let rate = file.processingFormat.sampleRate
        guard
          let mono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        else {
          throw Failure.unsupported
        }
        let frames = AVAudioFramePosition(file.length)
        let windowFrames = AVAudioFrameCount(windowSeconds * rate)

        var words: [[String: Any]] = []
        var start: AVAudioFramePosition = 0
        while start < frames {
          let remaining = AVAudioFrameCount(min(Int64(windowFrames), frames - start))
          guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: remaining)
          else { throw Failure.unsupported }
          file.framePosition = start
          try file.read(into: raw, frameCount: remaining)
          guard raw.frameLength > 0 else { break }

          let samples = monoSamples(of: raw)
          let cut = start + Int64(samples.count) < frames ? cutPoint(in: samples, rate: rate) : samples.count
          guard let window = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(cut))
          else { throw Failure.unsupported }
          window.frameLength = AVAudioFrameCount(cut)
          samples.withUnsafeBufferPointer { source in
            window.floatChannelData![0].update(from: source.baseAddress!, count: cut)
          }

          let offset = Double(start) / rate
          let result = try await recognize(window, with: recognizer)
          for segment in result.bestTranscription.segments {
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            let s = Int((offset + segment.timestamp) * 1000)
            let e = Int((offset + segment.timestamp + segment.duration) * 1000)
            words.append(["t": text, "s": s, "e": max(e, s)])
          }
          start += Int64(cut)
        }

        return [
          "lang": locale.languageCode ?? "en",
          "engine": recognizerEngine,
          "words": words,
        ]
      }

      /// Every channel averaged into one. Speech is mono in practice and the
      /// recogniser wants one channel; averaging loses nothing a stereo
      /// recording of one voice had.
      static func monoSamples(of buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let data = buffer.floatChannelData, count > 0, channels > 0 else { return [] }
        if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: count)) }
        var out = [Float](repeating: 0, count: count)
        for c in 0..<channels {
          for i in 0..<count { out[i] += data[c][i] }
        }
        let scale = 1 / Float(channels)
        for i in 0..<count { out[i] *= scale }
        return out
      }

      /// Where to end this window: the quietest 20 ms in its last
      /// [searchSeconds], which in speech is a pause. Cutting there means no
      /// window starts or ends mid-word.
      static func cutPoint(in samples: [Float], rate: Double) -> Int {
        let searchFrom = max(0, samples.count - Int(searchSeconds * rate))
        let step = max(1, Int(rate * 0.02))
        var quietestAt = samples.count
        var quietest = Float.greatestFiniteMagnitude
        var at = searchFrom
        while at + step <= samples.count {
          var energy: Float = 0
          for i in at..<(at + step) { energy += samples[i] * samples[i] }
          if energy < quietest {
            quietest = energy
            quietestAt = at + step / 2
          }
          at += step
        }
        return max(1, min(quietestAt, samples.count))
      }

      /// One window through the recogniser, on this device only, to its
      /// final result.
      static func recognize(_ buffer: AVAudioPCMBuffer, with recognizer: SFSpeechRecognizer)
        async throws -> SFSpeechRecognitionResult
      {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(macOS 13.0, *) { request.addsPunctuation = true }
        request.append(buffer)
        request.endAudio()
        return try await withCheckedThrowingContinuation { continuation in
          var done = false
          recognizer.recognitionTask(with: request) { result, error in
            if done { return }
            if let error {
              done = true
              continuation.resume(throwing: error)
              return
            }
            if let result, result.isFinal {
              done = true
              continuation.resume(returning: result)
            }
          }
        }
      }
    }

    private enum Failure: LocalizedError {
      case unsupported
      case denied

      var code: String {
        switch self {
        case .unsupported: return "unavailable"
        case .denied: return "denied"
        }
      }

      var errorDescription: String? {
        switch self {
        case .unsupported:
          return "This device cannot transcribe that language on its own."
        case .denied:
          return "Kapy Notes was not allowed to use speech recognition. You can change that in System Settings › Privacy & Security."
        }
      }
    }
  #endif
}
