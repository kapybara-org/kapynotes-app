import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers

/// Publishes alternative representations without bringing another runtime
/// into the app just to own the clipboard, and reads every representation a
/// paste can use in one call.
enum RichClipboard {
  private static let channelName = "kapynotes/rich_clipboard"

  /// Kapy Notes' own fragment, which only Kapy Notes reads.
  static let kapyType = NSPasteboard.PasteboardType("com.kapybara.kapynotes.fragment")
  private static let sourceUrlType = NSPasteboard.PasteboardType("org.chromium.source-url")
  private static let vscodeType = NSPasteboard.PasteboardType("vscode-editor-data")
  private static let webCustomDataType = NSPasteboard.PasteboardType("org.chromium.web-custom-data")
  private static let webArchiveType = NSPasteboard.PasteboardType("com.apple.webarchive")
  private static let jpegType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "write":
        write(call.arguments, result: result)
      case "read":
        let name = (call.arguments as? [String: Any])?["pasteboard"] as? String
        result(read(from: pasteboardNamed(name)))
      case "readHtml":
        result(NSPasteboard.general.string(forType: .html))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  /// The system clipboard, or the private pasteboard called `name`, which is
  /// how tests stay away from the user's own clipboard.
  private static func pasteboardNamed(_ name: String?) -> NSPasteboard {
    guard let name, !name.isEmpty else { return .general }
    return NSPasteboard(name: NSPasteboard.Name(name))
  }

  private static func write(_ rawArguments: Any?, result: FlutterResult) {
    guard let arguments = rawArguments as? [String: Any],
          let text = arguments["text"] as? String,
          let html = arguments["html"] as? String else {
      result(FlutterError(code: "clipboard_arguments", message: "Missing clipboard data", details: nil))
      return
    }
    write(
      text: text,
      html: html,
      kapy: arguments["kapy"] as? String,
      image: (arguments["image"] as? FlutterStandardTypedData)?.data,
      imageMime: arguments["imageMime"] as? String,
      to: pasteboardNamed(arguments["pasteboard"] as? String)
    )
    result(nil)
  }

  /// Replaces what `pasteboard` holds with one item in every representation
  /// given.
  static func write(
    text: String,
    html: String,
    kapy: String?,
    image: Data?,
    imageMime: String?,
    to pasteboard: NSPasteboard
  ) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    pasteboard.setString(html, forType: .html)
    if let kapy, !kapy.isEmpty {
      pasteboard.setString(kapy, forType: kapyType)
    }
    if let image, !image.isEmpty,
       let imageMime,
       let type = UTType(mimeType: imageMime) {
      pasteboard.setData(image, forType: NSPasteboard.PasteboardType(type.identifier))
    }
  }

  /// Everything on `pasteboard` that a paste can use, in the shape
  /// `ClipboardSnapshot.fromChannel` reads.
  ///
  /// Rich text is converted to HTML only when nothing else offers HTML,
  /// because the conversion is slow and HTML from the source is better.
  static func read(from pasteboard: NSPasteboard) -> [String: Any] {
    let types = pasteboard.types ?? []
    var snapshot: [String: Any] = ["types": types.map(\.rawValue)]
    snapshot["text"] = pasteboard.string(forType: .string)
    snapshot["vscode"] = pasteboard.string(forType: vscodeType)
      ?? pasteboard.data(forType: webCustomDataType).flatMap { webCustomData($0)["vscode-editor-data"] }
    snapshot["kapy"] = pasteboard.string(forType: kapyType)

    var html = pasteboard.string(forType: .html)
    var sourceUrl = pasteboard.string(forType: sourceUrlType)
    var resources: [[String: Any]] = []
    if let data = pasteboard.data(forType: webArchiveType),
       let archive = webArchive(data) {
      html = html ?? archive.html
      sourceUrl = sourceUrl ?? archive.url
      resources += archive.resources
    }
    if html == nil,
       let richText = richText(rtfd: pasteboard.data(forType: .rtfd), rtf: pasteboard.data(forType: .rtf)),
       let converted = convertToHtml(richText) {
      snapshot["rtfHtml"] = converted.html
      resources += converted.resources
    }
    snapshot["html"] = html
    snapshot["sourceUrl"] = sourceUrl
    if !resources.isEmpty {
      snapshot["resources"] = resources
    }

    if types.contains(.fileURL),
       let urls = pasteboard.readObjects(
         forClasses: [NSURL.self],
         options: [.urlReadingFileURLsOnly: true]
       ) as? [URL],
       !urls.isEmpty {
      snapshot["files"] = urls.map(\.path)
    }

    if let png = pasteboard.data(forType: .png), !png.isEmpty {
      snapshot["image"] = FlutterStandardTypedData(bytes: png)
      snapshot["imageMime"] = "image/png"
    } else if let jpeg = pasteboard.data(forType: jpegType), !jpeg.isEmpty {
      snapshot["image"] = FlutterStandardTypedData(bytes: jpeg)
      snapshot["imageMime"] = "image/jpeg"
    } else if let tiff = pasteboard.data(forType: .tiff), let png = pngData(tiff) {
      snapshot["image"] = FlutterStandardTypedData(bytes: png)
      snapshot["imageMime"] = "image/png"
    }
    return snapshot
  }

  /// The types a page set on a copy with `DataTransfer.setData` that are not
  /// standard, which Chromium (and so VS Code, an Electron app) pickles into
  /// one entry: the payload's size, the number of pairs, then each type and
  /// value as a UTF-16 string, each string's length in code units first and
  /// its end padded to four bytes.
  static func webCustomData(_ data: Data) -> [String: String] {
    let bytes = [UInt8](data)
    var offset = 0
    func uint32() -> Int? {
      guard offset + 4 <= bytes.count else { return nil }
      defer { offset += 4 }
      return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }
    func string() -> String? {
      guard let length = uint32(), length <= (bytes.count - offset) / 2 else { return nil }
      let units = (0..<length).map {
        UInt16(bytes[offset + 2 * $0]) | UInt16(bytes[offset + 2 * $0 + 1]) << 8
      }
      offset += (2 * length + 3) & ~3
      return String(decoding: units, as: UTF16.self)
    }

    guard uint32() != nil, let count = uint32() else { return [:] }
    var values: [String: String] = [:]
    for _ in 0..<count {
      guard let type = string(), let value = string() else { break }
      values[type] = value
    }
    return values
  }

  /// Safari's copy: the page's markup, the page's address, and the bytes of
  /// everything the markup loaded, by the URL it loaded them from.
  private static func webArchive(
    _ data: Data
  ) -> (html: String?, url: String?, resources: [[String: Any]])? {
    guard let archive = try? PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any] else {
      return nil
    }
    let main = archive["WebMainResource"] as? [String: Any]
    let html = (main?["WebResourceData"] as? Data).flatMap {
      decodeText($0, encodingName: main?["WebResourceTextEncodingName"] as? String)
    }
    let resources = (archive["WebSubresources"] as? [[String: Any]] ?? []).compactMap {
      resource -> [String: Any]? in
      guard let url = resource["WebResourceURL"] as? String,
            let bytes = resource["WebResourceData"] as? Data,
            !bytes.isEmpty else {
        return nil
      }
      return [
        "name": url,
        "mime": resource["WebResourceMIMEType"] as? String ?? "application/octet-stream",
        "data": FlutterStandardTypedData(bytes: bytes),
      ]
    }
    return (html, main?["WebResourceURL"] as? String, resources)
  }

  private static func decodeText(_ data: Data, encodingName: String?) -> String? {
    if let encodingName {
      let encoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
      if encoding != kCFStringEncodingInvalidId,
         let text = String(
           data: data,
           encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
         ) {
        return text
      }
    }
    return String(data: data, encoding: .utf8)
  }

  /// RTFD when the source offered it, for its pictures, else plain RTF.
  private static func richText(rtfd: Data?, rtf: Data?) -> NSAttributedString? {
    if let rtfd, let text = NSAttributedString(rtfd: rtfd, documentAttributes: nil) {
      return text
    }
    if let rtf, let text = NSAttributedString(rtf: rtf, documentAttributes: nil) {
      return text
    }
    return nil
  }

  /// `text` as HTML, with each attachment's bytes named by the `src` its
  /// `<img>` has in that HTML.
  ///
  /// The HTML writer names an attachment by a `file:///` URL of its file name,
  /// so attachments are matched to images by that name, then in order.
  static func convertToHtml(
    _ text: NSAttributedString
  ) -> (html: String, resources: [[String: Any]])? {
    let range = NSRange(location: 0, length: text.length)
    guard let data = try? text.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
          ),
          let html = String(data: data, encoding: .utf8) else {
      return nil
    }

    var attachments: [(name: String?, bytes: Data, type: UTType?)] = []
    text.enumerateAttribute(.attachment, in: range) { value, _, _ in
      guard let attachment = value as? NSTextAttachment else { return }
      let wrapper = attachment.fileWrapper
      guard let bytes = wrapper?.regularFileContents ?? attachment.contents else { return }
      let name = wrapper?.preferredFilename ?? wrapper?.filename
      let type = attachment.fileType.flatMap { UTType($0) }
        ?? name.flatMap { UTType(filenameExtension: ($0 as NSString).pathExtension) }
      attachments.append((name, bytes, type))
    }

    var unused = Array(attachments.indices)
    var named = Set<String>()
    var resources: [[String: Any]] = []
    for source in imageSources(in: html) where named.insert(source).inserted {
      let name = source.hasPrefix("file:///")
        ? String(source.dropFirst("file:///".count)).removingPercentEncoding
        : nil
      guard let index = unused.first(where: { attachments[$0].name == name }) ?? unused.first else {
        break
      }
      unused.removeAll { $0 == index }
      let attachment = attachments[index]
      if let resource = imageResource(attachment.bytes, type: attachment.type) {
        resources.append([
          "name": source,
          "mime": resource.mime,
          "data": FlutterStandardTypedData(bytes: resource.bytes),
        ])
      }
    }
    return (html, resources)
  }

  /// Every `<img src>` in `html`, as the attribute's value.
  private static func imageSources(in html: String) -> [String] {
    guard let pattern = try? NSRegularExpression(
      pattern: "<img\\b[^>]*?\\ssrc=\"([^\"]*)\"",
      options: [.caseInsensitive]
    ) else {
      return []
    }
    return pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
      Range($0.range(at: 1), in: html).map {
        String(html[$0])
          .replacingOccurrences(of: "&quot;", with: "\"")
          .replacingOccurrences(of: "&#39;", with: "'")
          .replacingOccurrences(of: "&lt;", with: "<")
          .replacingOccurrences(of: "&gt;", with: ">")
          .replacingOccurrences(of: "&amp;", with: "&")
      }
    }
  }

  /// A picture as bytes a web view or Flutter can show: TIFF and PDF become
  /// PNG, other pictures stay as they are, and anything else is left out.
  private static func imageResource(_ bytes: Data, type: UTType?) -> (bytes: Data, mime: String)? {
    guard let type, type.conforms(to: .image) || type.conforms(to: .pdf) else { return nil }
    if type.conforms(to: .tiff) || type.conforms(to: .pdf) {
      return pngData(bytes).map { ($0, "image/png") }
    }
    return type.preferredMIMEType.map { (bytes, $0) }
  }

  private static func pngData(_ data: Data) -> Data? {
    let bitmap = NSBitmapImageRep(data: data)
      ?? NSImage(data: data)?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    return bitmap?.representation(using: .png, properties: [:])
  }
}
