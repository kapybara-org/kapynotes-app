import AppKit
import FlutterMacOS

/// Exposes macOS' own spelling dictionaries to the Flutter editor.
///
/// The response deliberately matches Flutter's suggestion-span shape, so the
/// editor can merge subtle underlines into its rich text and put corrections
/// in the same adaptive menu as the standard editing actions.
enum SpellCheck {
  private static let channelName = "kapynotes/spell_check"
  private static let maximumResults = 100

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "check" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(check(call.arguments))
    }
    return channel
  }

  private static func check(_ rawArguments: Any?) -> [[String: Any]] {
    guard
      let arguments = rawArguments as? [String: Any],
      let text = arguments["text"] as? String,
      let requestedLanguage = arguments["language"] as? String,
      !text.isEmpty
    else {
      return []
    }

    let checker = NSSpellChecker.shared
    let language = bestLanguage(for: requestedLanguage, checker: checker)
    let utf16Length = (text as NSString).length
    var offset = 0
    var response: [[String: Any]] = []

    while offset < utf16Length && response.count < maximumResults {
      let range = checker.checkSpelling(
        of: text,
        startingAt: offset,
        language: language,
        wrap: false,
        inSpellDocumentWithTag: 0,
        wordCount: nil
      )
      if range.location == NSNotFound || range.length == 0 {
        break
      }
      let end = NSMaxRange(range)
      guard range.location >= offset, end <= utf16Length else {
        break
      }
      let suggestions = checker.guesses(
        forWordRange: range,
        in: text,
        language: language,
        inSpellDocumentWithTag: 0
      ) ?? []
      response.append([
        "startIndex": range.location,
        "endIndex": end,
        "suggestions": Array(suggestions.prefix(5)),
      ])
      offset = end
    }
    return response
  }

  /// NSSpellChecker language identifiers vary between dictionaries. Match the
  /// requested locale after normalising separators, then prefer another
  /// installed dictionary for the same language. Passing nil lets macOS use
  /// the user's current spelling language when neither exists.
  private static func bestLanguage(
    for requested: String,
    checker: NSSpellChecker
  ) -> String? {
    func normalised(_ value: String) -> String {
      value.replacingOccurrences(of: "_", with: "-").lowercased()
    }
    let wanted = normalised(requested)
    if let exact = checker.availableLanguages.first(where: {
      normalised($0) == wanted
    }) {
      return exact
    }
    let base = wanted.split(separator: "-").first.map(String.init) ?? wanted
    return checker.availableLanguages.first(where: {
      let candidate = normalised($0)
      return candidate == base || candidate.hasPrefix("\(base)-")
    })
  }
}
