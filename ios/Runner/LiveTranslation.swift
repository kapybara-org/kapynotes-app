import AVFoundation
import Flutter
import Foundation
import SwiftUI
import UIKit

#if canImport(Speech)
  import Speech
#endif
#if canImport(Translation)
  import Translation
#endif

/// Live translation while a recording runs: the words as they are heard, and
/// each finished phrase in another language, all on this iPhone. The
/// `kapynotes/live_translation` channels, for lib/speech/live_translation.dart.
///
/// Both engines are Apple's own and both arrived in iOS 26 in the form this
/// needs: `SpeechAnalyzer` with `SpeechTranscriber`, which reports a phrase
/// while it is still being said (volatile results) and again once it settles,
/// and `TranslationSession(installedSource:target:)`, the first translator
/// that runs without a SwiftUI view in the window. Below iOS 26 every method
/// answers "unsupported", and Settings hides the row.
///
/// It hears through its own `AVAudioEngine` input tap, beside the record
/// plugin's `AVAudioRecorder`, which keeps writing the file exactly as it
/// does today. The plugin puts the session in `.playAndRecord` and makes it
/// active before Dart starts this, and the tap works inside that, so nothing
/// here sets a category or deactivates the session: doing either would cut
/// the recording.
///
/// Nothing is created until a method asks for it. Registering costs two
/// channel handlers; the engine, the analyser, the translator and the tap
/// exist only between `start` and `stop`, so with live translation off a
/// recording runs exactly as it always has.
///
/// Heard and translated text goes to Dart and nowhere else: it is never
/// logged, here or by anything this calls.
enum LiveTranslation {
  private static let channelName = "kapynotes/live_translation"
  private static let eventsName = "kapynotes/live_translation/phrases"

  /// Held for the app's lifetime: the event channel's handler goes through
  /// it, and phrases go to whoever is listening.
  fileprivate static let events = Events()

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    FlutterEventChannel(name: eventsName, binaryMessenger: messenger).setStreamHandler(events)
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      if call.method == "openSettings" {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        return result(nil)
      }
      #if canImport(Speech) && canImport(Translation)
        if #available(iOS 26.0, *) {
          Task { @MainActor in await Live.handle(call, result) }
          return
        }
      #endif
      result(unsupported(call.method))
    }
    return channel
  }

  /// What every method answers on a phone that cannot do this at all.
  private static func unsupported(_ method: String) -> Any? {
    switch method {
    case "availability", "prepare":
      return "unsupported"
    case "languages":
      return ["spoken": [String](), "targets": [String](), "names": [String: Any]()]
    case "pairStatus":
      return ["status": "unsupported"]
    case "remove", "pause", "resume", "stop":
      return nil
    case "start":
      return FlutterError(
        code: "unavailable", message: "Live translation needs iOS 26 or later.", details: nil)
    case "translate":
      return FlutterError(
        code: "unsupported", message: "This iPhone cannot translate on its own.", details: nil)
    default:
      return FlutterMethodNotImplemented
    }
  }
}

/// The phrases stream. Dart listens before it calls `start` and stops after
/// `stop` answers, and messages on one messenger arrive in order, so every
/// event a session sends lands while somebody is listening.
private final class Events: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func send(_ event: [String: Any]) {
    sink?(event)
  }
}

#if canImport(Speech) && canImport(Translation)
  /// The methods, on iOS 26 and later. Everything runs on the main actor, the
  /// thread Flutter calls and must be answered on, except the tap's own
  /// conversion, which runs on the audio thread and touches none of this.
  @available(iOS 26.0, *)
  @MainActor
  private enum Live {
    /// The one session there can be: one recording, one microphone.
    static var session: Session?
    /// A `start` still checking what it needs, so a second one waits its
    /// turn as "busy" rather than opening a second tap.
    static var starting = false

    static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) async {
      let arguments = call.arguments as? [String: Any] ?? [:]
      let from = arguments["from"] as? String
      let to = arguments["to"] as? String
      switch call.method {
      case "availability":
        result(SpeechTranscriber.isAvailable ? "ready" : "unsupported")
      case "languages":
        result(await languages())
      case "pairStatus":
        result(await pairStatus(from, to))
      case "prepare":
        result(await prepare(from, to))
      case "remove":
        // Apple's languages are the system's, kept and removed in its own
        // settings.
        result(nil)
      case "start":
        result(await start(from, to))
      case "pause":
        session?.pause()
        result(nil)
      case "resume":
        session?.resume()
        result(nil)
      case "stop":
        if let ending = session {
          await ending.stop()
          if session === ending { session = nil }
        }
        result(nil)
      case "translate":
        result(await translate(from, to, arguments["texts"] as? [String]))
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    // MARK: - Languages

    /// What a pair of ISO-639-1 codes comes to here: the locale the
    /// transcriber hears in, and the two languages the translator knows them
    /// by.
    struct Pair {
      let locale: Locale
      let source: Locale.Language
      let target: Locale.Language
    }

    struct Languages {
      let source: Locale.Language
      let target: Locale.Language
    }

    /// The transcriber exactly as a session runs it. Its assets depend on its
    /// options, so checking and installing use this one too.
    static func transcriber(for locale: Locale) -> SpeechTranscriber {
      SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults],
        attributeOptions: [])
    }

    static func pair(_ from: String?, _ to: String?) async -> Pair? {
      guard
        SpeechTranscriber.isAvailable,
        let languages = await translation(from, to),
        let from,
        let locale = await speechLocale(for: from)
      else { return nil }
      return Pair(locale: locale, source: languages.source, target: languages.target)
    }

    /// The translator's own languages for the two codes. The framework
    /// matches other values to these, but asking with its own is what its
    /// documentation recommends, and it never translates a language into
    /// itself.
    static func translation(_ from: String?, _ to: String?) async -> Languages? {
      guard
        let from = from?.lowercased(), let to = to?.lowercased(), !from.isEmpty, from != to
      else { return nil }
      let supported = await LanguageAvailability().supportedLanguages
      guard
        let source = best(from, among: supported),
        let target = best(to, among: supported)
      else { return nil }
      return Languages(source: source, target: target)
    }

    /// This language in the region the phone is set to, else in any region:
    /// Portuguese in Brazil is `pt-BR`, in India it is whichever the
    /// framework lists first.
    static func best(_ code: String, among languages: [Locale.Language]) -> Locale.Language? {
      let matching = languages.filter { $0.languageCode?.identifier.lowercased() == code }
      return matching.first { $0.region == Locale.current.region } ?? matching.first
    }

    /// The transcriber's locale for a code, by the same rule as
    /// Transcription.swift's: the phone's region first, then any region.
    /// `supportedLocale(equivalentTo:)` does the second half itself,
    /// preferring a locale that is already installed.
    static func speechLocale(for code: String) async -> Locale? {
      let code = code.lowercased()
      let wanted = Locale(
        identifier: Locale.current.region.map { "\(code)_\($0.identifier)" } ?? code)
      guard
        let found = await SpeechTranscriber.supportedLocale(equivalentTo: wanted),
        found.language.languageCode?.identifier.lowercased() == code
      else { return nil }
      return found
    }

    static func languages() async -> [String: Any] {
      let spoken =
        SpeechTranscriber.isAvailable
        ? codes(await SpeechTranscriber.supportedLocales.map(\.language)) : []
      let targets = codes(await LanguageAvailability().supportedLanguages)
      var names: [String: Any] = [:]
      let english = Locale(identifier: "en")
      for code in Set(spoken).union(targets) {
        let own = Locale(identifier: code)
        names[code] = [
          "english": capitalized(english.localizedString(forLanguageCode: code), in: english),
          "own": capitalized(own.localizedString(forLanguageCode: code), in: own),
        ]
      }
      return ["spoken": spoken, "targets": targets, "names": names]
    }

    /// Two-letter codes only, which is what Dart's language list speaks:
    /// Cantonese's `yue` has no ISO-639-1 code to match against.
    static func codes(_ languages: [Locale.Language]) -> [String] {
      Set(
        languages.compactMap { $0.languageCode?.identifier.lowercased() }
          .filter { $0.count == 2 }
      ).sorted()
    }

    /// "español" reads as a name in a list once it is "Español". Upper-cased
    /// in the language's own rules, so Turkish keeps its dotted I.
    static func capitalized(_ name: String?, in locale: Locale) -> String {
      guard let name, let first = name.first else { return name ?? "" }
      return String(first).uppercased(with: locale) + name.dropFirst()
    }

    // MARK: - Status and preparing

    static func pairStatus(_ from: String?, _ to: String?) async -> [String: Any] {
      guard let pair = await pair(from, to) else { return ["status": "unsupported"] }
      let translation = await LanguageAvailability().status(from: pair.source, to: pair.target)
      if translation == .unsupported { return ["status": "unsupported"] }
      let speech = await AssetInventory.status(forModules: [transcriber(for: pair.locale)])
      if speech == .unsupported { return ["status": "unsupported"] }
      let installed = speech == .installed && translation == .installed
      return ["status": installed ? "installed" : "downloadable"]
    }

    /// Microphone first, because it is the one thing here a person can
    /// refuse for good. `SpeechAnalyzer` asks for nothing else: unlike
    /// `SFSpeechRecognizer` it never needs the Speech Recognition
    /// permission, which is why Transcription.swift's iOS 26 path never asks
    /// for it either.
    ///
    /// Then the transcriber's assets, which the system fetches without
    /// asking, as Transcription.swift explains, and then the translation
    /// languages through the system's own download prompt. That prompt only
    /// comes from `translationTask`, so a 1-point view carries it for as
    /// long as it is up.
    static func prepare(_ from: String?, _ to: String?) async -> String {
      guard let pair = await pair(from, to) else { return "unsupported" }
      let availability = LanguageAvailability()
      guard await availability.status(from: pair.source, to: pair.target) != .unsupported else {
        return "unsupported"
      }
      guard await microphoneAllowed(asking: true) else { return "denied" }

      let transcriber = transcriber(for: pair.locale)
      do {
        if let request = try await AssetInventory.assetInstallationRequest(
          supporting: [transcriber])
        {
          try await request.downloadAndInstall()
        }
      } catch {
        return "declined"
      }
      guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
        return "declined"
      }
      // A reservation keeps the system from reclaiming the locale. There is
      // a cap on them, and missing one costs a download some day, not this.
      _ = try? await AssetInventory.reserve(locale: pair.locale)

      if await availability.status(from: pair.source, to: pair.target) != .installed {
        guard await TranslationPrompt.show(source: pair.source, target: pair.target) else {
          return "declined"
        }
        // The prompt returns once the person agrees, and the download may
        // still be running, so this waits for it, up to five minutes.
        var waited = 0
        while await availability.status(from: pair.source, to: pair.target) == .supported,
          waited < 300
        {
          try? await Task.sleep(for: .seconds(1))
          waited += 1
        }
      }
      return await availability.status(from: pair.source, to: pair.target) == .installed
        ? "ready" : "declined"
    }

    /// Whether the app may use the microphone, asking only when `asking`
    /// and only if nobody has answered yet.
    static func microphoneAllowed(asking: Bool) async -> Bool {
      switch AVAudioApplication.shared.recordPermission {
      case .granted:
        return true
      case .undetermined:
        return asking ? await AVAudioApplication.requestRecordPermission() : false
      default:
        return false
      }
    }

    // MARK: - A session

    static func start(_ from: String?, _ to: String?) async -> Any? {
      guard session == nil, !starting else {
        return FlutterError(code: "busy", message: "Live translation is already on.", details: nil)
      }
      starting = true
      defer { starting = false }

      guard await microphoneAllowed(asking: false) else {
        return FlutterError(
          code: "denied", message: "Kapy Notes may not use the microphone.", details: nil)
      }
      let unavailable = FlutterError(
        code: "unavailable",
        message: "This iPhone cannot translate these languages live right now.",
        details: nil)
      guard let pair = await pair(from, to) else { return unavailable }
      let transcriber = transcriber(for: pair.locale)
      guard
        await AssetInventory.status(forModules: [transcriber]) == .installed,
        await LanguageAvailability().status(from: pair.source, to: pair.target) == .installed,
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
      else { return unavailable }

      let started = Session(
        transcriber: transcriber,
        translator: TranslationSession(installedSource: pair.source, target: pair.target),
        format: format)
      do {
        try await started.begin()
      } catch {
        return unavailable
      }
      session = started
      return nil
    }

    /// A list of texts, translated one by one with the same translator a
    /// session uses: for the saved transcript after a recording, and for
    /// Translate to. No microphone and no session; the pair must already be
    /// on the phone.
    static func translate(_ from: String?, _ to: String?, _ texts: [String]?) async -> Any? {
      guard
        let texts,
        let languages = await translation(from, to),
        await LanguageAvailability().status(from: languages.source, to: languages.target)
          == .installed
      else {
        return FlutterError(
          code: "unsupported", message: "These languages are not on this iPhone.", details: nil)
      }
      let translator = TranslationSession(installedSource: languages.source, target: languages.target)
      var translated: [String] = []
      for text in texts {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          translated.append(text)
          continue
        }
        do {
          translated.append(try await translator.translate(text).targetText)
        } catch {
          return FlutterError(
            code: "failed", message: "This iPhone could not translate the text.", details: nil)
        }
      }
      return translated
    }
  }

  /// One recording's worth of hearing and translating.
  ///
  /// A phrase is what `SpeechTranscriber` finalises: its volatile results
  /// share the phrase's id until a final result closes it, and the next
  /// volatile result opens a new one. Each finished phrase is translated in
  /// turn, one after another, so translations arrive in the order the
  /// phrases were said.
  @available(iOS 26.0, *)
  @MainActor
  private final class Session {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let translator: TranslationSession
    /// What the analyser wants, from `bestAvailableAudioFormat`. The
    /// microphone's own format is converted to it in the tap.
    private let format: AVAudioFormat
    private let audio: AsyncStream<AnalyzerInput>
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let engine = AVAudioEngine()

    private var listening: Task<Void, Never>?
    /// The last translation asked for; each waits for the one before it.
    private var translating: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    private var tapping = false
    private var paused = false
    /// `stop` has begun: what the results stream does from here is the
    /// end of the session, not a failure.
    private var stopping = false
    /// An error went to Dart, after which this session says nothing more.
    private var failed = false

    private var nextId = 0
    /// The phrase still being heard, and its latest words.
    private var open: (id: Int, heard: String)?

    init(transcriber: SpeechTranscriber, translator: TranslationSession, format: AVAudioFormat) {
      self.transcriber = transcriber
      self.translator = translator
      self.format = format
      analyzer = SpeechAnalyzer(modules: [transcriber])
      let (audio, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
      self.audio = audio
      self.input = input
    }

    /// Results are listened for before any audio flows: `transcriber.results`
    /// is a live stream, and a result delivered before anybody listens is
    /// lost.
    func begin() async throws {
      listening = Task { await listen() }
      do {
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: audio)
        try startTap()
      } catch {
        stopping = true
        stopTap()
        input.finish()
        await analyzer.cancelAndFinishNow()
        throw error
      }
      observe()
    }

    func pause() {
      guard !failed, !stopping else { return }
      paused = true
      stopTap()
    }

    /// Also how hearing comes back after an interruption: the recorder
    /// stands still through one, and Dart resumes both together.
    func resume() {
      guard !failed, !stopping, !tapping else { return }
      paused = false
      do {
        try startTap()
      } catch {
        fail("interrupted")
      }
    }

    /// Ends hearing, lets the analyser finish what it has, then waits for
    /// every phrase's translation, so Dart has them all before `stop`
    /// answers.
    func stop() async {
      guard !failed else { return }
      stopping = true
      stopTap()
      forgetObservers()
      input.finish()
      do {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
      } catch {
        await analyzer.cancelAndFinishNow()
      }
      await listening?.value
      // Words the person saw that the analyser never settled are kept as
      // they were last heard, rather than vanishing at the end.
      if let open {
        close(open.id, heard: open.heard)
      }
      await translating?.value
      LiveTranslation.events.send(["done": true])
    }

    // MARK: Results

    private func listen() async {
      do {
        for try await result in transcriber.results {
          let heard = String(result.text.characters).trimmingCharacters(
            in: .whitespacesAndNewlines)
          if result.isFinal {
            // An empty final keeps the phrase open: the next words replace
            // what it showed, under the same id.
            guard !heard.isEmpty else { continue }
            close(open?.id ?? newId(), heard: heard)
          } else if !heard.isEmpty {
            let id = open?.id ?? newId()
            open = (id, heard)
            send(["id": id, "heard": heard, "final": false])
          }
        }
      } catch {
        if !stopping { fail("failed") }
      }
    }

    private func newId() -> Int {
      defer { nextId += 1 }
      return nextId
    }

    private func close(_ id: Int, heard: String) {
      open = nil
      send(["id": id, "heard": heard, "final": true])
      let previous = translating
      translating = Task {
        await previous?.value
        // A phrase the translator can't take is left untranslated rather
        // than ending the session: the next one usually goes through.
        guard let response = try? await translator.translate(heard) else { return }
        send(["id": id, "translation": response.targetText])
      }
    }

    private func send(_ event: [String: Any]) {
      guard !failed else { return }
      LiveTranslation.events.send(event)
    }

    /// Tells Dart once, then ends everything. The recording carries on.
    private func fail(_ reason: String) {
      guard !failed else { return }
      send(["error": reason])
      failed = true
      stopping = true
      stopTap()
      forgetObservers()
      input.finish()
      listening?.cancel()
      translating?.cancel()
      let analyzer = analyzer
      Task { await analyzer.cancelAndFinishNow() }
      if Live.session === self { Live.session = nil }
    }

    // MARK: The tap

    /// Opens the tap in whatever format the microphone has now. Asked again
    /// after a route change, because a new microphone can bring a new rate.
    private func startTap() throws {
      let node = engine.inputNode
      let microphone = node.outputFormat(forBus: 0)
      // No input in the session's current state, such as before the
      // recorder has made it active: a tap in a 0 Hz format would crash.
      guard microphone.sampleRate > 0, microphone.channelCount > 0,
        let converter = AVAudioConverter(from: microphone, to: format)
      else { throw TapFailure.noInput }
      // No priming, so each buffer's samples come out in step with the ones
      // before and the analyser's clock doesn't drift.
      converter.primeMethod = .none
      Session.install(on: node, from: microphone, through: converter, into: input)
      engine.prepare()
      do {
        try engine.start()
      } catch {
        node.removeTap(onBus: 0)
        throw error
      }
      tapping = true
    }

    private func stopTap() {
      guard tapping else { return }
      tapping = false
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }

    /// Outside the main actor on purpose: the block runs on the audio
    /// thread, and a block made inside an actor-isolated method would be
    /// isolated to that actor and trap there.
    nonisolated private static func install(
      on node: AVAudioInputNode, from microphone: AVAudioFormat,
      through converter: AVAudioConverter, into input: AsyncStream<AnalyzerInput>.Continuation
    ) {
      let format = converter.outputFormat
      node.installTap(onBus: 0, bufferSize: 4096, format: microphone) { buffer, _ in
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0,
          let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)
        else { return }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
          defer { consumed = true }
          inputStatus.pointee = consumed ? .noDataNow : .haveData
          return consumed ? nil : buffer
        }
        guard status != .error, converted.frameLength > 0 else { return }
        input.yield(AnalyzerInput(buffer: converted))
      }
    }

    // MARK: Interruptions

    /// A call or Siri takes the microphone and stops the engine: the tap
    /// closes and waits for `resume`. A new microphone, or a new rate, stops
    /// it too, without anybody pausing, and the tap reopens on its own. If it
    /// can't, an interruption is usually under way, and it waits for
    /// `resume` like one; `resume` failing is what ends the session.
    private func observe() {
      let center = NotificationCenter.default
      observers.append(
        center.addObserver(
          forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
          let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
          guard raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began else {
            return
          }
          Task { @MainActor in self?.stopTap() }
        })
      observers.append(
        center.addObserver(
          forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
          Task { @MainActor in self?.reopen() }
        })
    }

    private func reopen() {
      guard tapping, !paused, !stopping, !failed else { return }
      stopTap()
      try? startTap()
    }

    private func forgetObservers() {
      for observer in observers {
        NotificationCenter.default.removeObserver(observer)
      }
      observers = []
    }

    private enum TapFailure: Error {
      case noInput
    }
  }

  /// The system's download prompt for a pair of translation languages. Only
  /// `translationTask` can show it, and only from a view in a window, so
  /// this is a clear 1-point view added over whatever is on screen for as
  /// long as the prompt is up, then taken away.
  @available(iOS 26.0, *)
  private struct TranslationPrompt: View {
    let configuration: TranslationSession.Configuration
    let finished: @MainActor (Bool) -> Void

    var body: some View {
      Color.clear
        .frame(width: 1, height: 1)
        .translationTask(configuration) { session in
          do {
            try await session.prepareTranslation()
            await finished(true)
          } catch {
            await finished(false)
          }
        }
    }

    /// True once the person agreed to the download, false if they didn't or
    /// there is no window to ask in.
    @MainActor
    static func show(source: Locale.Language, target: Locale.Language) async -> Bool {
      guard let parent = topViewController() else { return false }
      return await withCheckedContinuation { continuation in
        var shown: UIHostingController<TranslationPrompt>?
        let prompt = TranslationPrompt(
          configuration: TranslationSession.Configuration(source: source, target: target)
        ) { accepted in
          guard let host = shown else { return }
          shown = nil
          host.willMove(toParent: nil)
          host.view.removeFromSuperview()
          host.removeFromParent()
          continuation.resume(returning: accepted)
        }
        let host = UIHostingController(rootView: prompt)
        host.view.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        shown = host
        parent.addChild(host)
        parent.view.addSubview(host.view)
        host.didMove(toParent: parent)
      }
    }

    /// Whatever is on screen, as FileExport.swift finds it, so the prompt
    /// opens over the settings sheet it was asked from.
    @MainActor
    private static func topViewController() -> UIViewController? {
      let scene =
        UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
        ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
      while let presented = top?.presentedViewController {
        top = presented
      }
      return top
    }
  }
#endif
