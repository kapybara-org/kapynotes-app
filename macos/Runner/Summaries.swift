import Foundation
import FlutterMacOS

#if canImport(FoundationModels)
  import FoundationModels
#endif

/// Apple's on-device language model, writing the summary of a voice note.
///
/// The appeal over anything we could ship is that the weights are already on
/// the machine: no download, no account, no minutes, and the transcript never
/// leaves the device. The cost is that it is conditional — the Mac has to be
/// eligible, Apple Intelligence has to be on, and the model has to have
/// finished arriving — so `availability` is a real question with four
/// answers and the Dart side asks it every time rather than remembering.
///
/// Everything here is compiled behind `canImport` and `#available` so that a
/// build on an older SDK, or a run on an older macOS, is a Mac that answers
/// "unsupported" rather than one that fails to launch.
enum Summaries {
  private static let channelName = "kapynotes/summaries"

  /// Roughly what the base model will take before it starts refusing, in
  /// characters. The Dart side clamps first; this is the backstop for a
  /// caller that did not.
  private static let maximumTranscript = 12_000

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "availability":
        result(availability())
      case "summarize":
        run(call.arguments, result, asSummary: true)
      case "rewrite":
        run(call.arguments, result, asSummary: false)
      case "physicalMemory":
        // Whether a downloaded model is worth offering at all. Cheap, exact,
        // and the alternative is letting the OS answer by killing us.
        result(Int(ProcessInfo.processInfo.physicalMemory))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  /// One of `ready`, `disabled`, `preparing`, `unsupported`.
  ///
  /// Four answers rather than two because they ask for different things.
  /// "Disabled" is somebody to turn Apple Intelligence on, and is by far the
  /// most common reason a capable machine says no. "Preparing" is the only
  /// one that becomes "ready" on its own, so it is the only one where the
  /// right advice is to wait. "Unsupported" is the end of the road.
  private static func availability() -> String {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        switch SystemLanguageModel.default.availability {
        case .available:
          return "ready"
        case .unavailable(let reason):
          switch reason {
          case .appleIntelligenceNotEnabled:
            return "disabled"
          case .modelNotReady:
            return "preparing"
          default:
            return "unsupported"
          }
        @unknown default:
          return "unsupported"
        }
      }
    #endif
    return "unsupported"
  }

  /// Both jobs, which differ only in the shape of the answer.
  ///
  /// One entry point because everything around the model call — the argument
  /// checking, the length clamp, the availability dance, the hop back to the
  /// main actor — is identical, and two copies of it would be two things to
  /// keep in step.
  private static func run(
    _ rawArguments: Any?, _ result: @escaping FlutterResult, asSummary: Bool
  ) {
    guard
      let arguments = rawArguments as? [String: Any],
      let rawText = arguments["text"] as? String,
      !rawText.isEmpty
    else {
      result(
        FlutterError(
          code: "arguments", message: "A transcript is required.", details: nil))
      return
    }
    let text = String(rawText.prefix(maximumTranscript))
    let language = arguments["language"] as? String
    let instruction = (arguments["instruction"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // A rewrite is defined by its instruction; without one there is nothing
    // to ask for, and answering anyway would be inventing the request.
    if !asSummary, instruction?.isEmpty ?? true {
      result(
        FlutterError(
          code: "arguments", message: "An instruction is required.", details: nil))
      return
    }

    #if canImport(FoundationModels)
      if #available(macOS 26.0, *) {
        Task {
          do {
            let answer: Any =
              asSummary
              ? try await write(
                transcript: text, language: language, instruction: instruction)
              : try await rewrite(transcript: text, instruction: instruction ?? "")
            await MainActor.run { result(answer) }
          } catch {
            await MainActor.run {
              result(
                FlutterError(
                  code: "failed",
                  message: error.localizedDescription,
                  details: nil))
            }
          }
        }
        return
      }
    #endif

    result(
      FlutterError(
        code: "unavailable",
        message: "Apple Intelligence is not available on this device.",
        details: nil))
  }

  #if canImport(FoundationModels)
    /// The shape the model is asked to fill in.
    ///
    /// Guided generation rather than "please answer as JSON": the framework
    /// constrains decoding to this type, so there is no preamble to strip, no
    /// fence to unwrap, and no retry when it writes prose instead.
    @available(macOS 26.0, *)
    @Generable
    struct NoteSummary {
      @Guide(description: "A title of at most six words, in the language of the transcript")
      var title: String

      @Guide(description: "Between two and five short points, each one sentence, in the language of the transcript")
      var points: [String]
    }

    /// What the model is told no matter what the user asked for.
    ///
    /// A user's instruction is added after this, never in place of it: they
    /// are choosing what kind of summary they get, not whether the model may
    /// make things up about their own notes.
    private static let groundRules = """
      You work on a transcript of somebody talking into a notes app. \
      Keep the speaker's own words and names. Use only what the transcript \
      says: do not add advice, praise, or any fact that is not in it. Do not \
      explain what you are doing and do not address the reader.
      """

    @available(macOS 26.0, *)
    private static func write(
      transcript: String, language: String?, instruction: String?
    ) async throws -> [String: Any] {
      let asked =
        (instruction?.isEmpty ?? true)
        ? "Summarise it: a short title and a few one-sentence points."
        : instruction!
      let session = LanguageModelSession(
        instructions: """
          \(groundRules)

          \(asked)

          Write in the same language as the transcript.
          """
      )
      let response = try await session.respond(
        to: "Here is the transcript.\n\n\(transcript)",
        generating: NoteSummary.self
      )
      let summary = response.content
      return [
        "title": summary.title,
        "points": summary.points,
      ]
    }

    /// A piece of writing rather than a summary — a post, usually.
    ///
    /// No guided generation on purpose: the answer is the deliverable and is
    /// meant to be copied out whole, so constraining it to a struct would
    /// only give the model a shape to fight.
    @available(macOS 26.0, *)
    private static func rewrite(transcript: String, instruction: String) async throws
      -> String
    {
      let session = LanguageModelSession(
        instructions: """
          \(groundRules)

          \(instruction)

          Reply with the finished text only: no preamble, no explanation, no \
          surrounding quotation marks.
          """
      )
      let response = try await session.respond(
        to: "Here is the transcript.\n\n\(transcript)"
      )
      return response.content
    }
  #endif
}
