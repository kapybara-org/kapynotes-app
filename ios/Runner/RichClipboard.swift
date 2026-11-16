import Flutter
import UIKit
import UniformTypeIdentifiers

/// The system clipboard representation for a note selection containing
/// images, and every representation a paste can use, read in one call.
enum RichClipboard {
  private static let channelName = "kapynotes/rich_clipboard"

  /// Kapy Notes' own fragment, which only Kapy Notes reads.
  static let kapyType = "com.kapybara.kapynotes.fragment"
  private static let sourceUrlType = "org.chromium.source-url"
  private static let vscodeType = "vscode-editor-data"
  private static let webArchiveTypes = ["com.apple.webarchive", "Apple Web Archive pasteboard type"]

  static func register(with messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "write":
        write(call.arguments, result: result)
      case "read":
        let name = (call.arguments as? [String: Any])?["pasteboard"] as? String
        if let name, !name.isEmpty {
          result(UIPasteboard(name: UIPasteboard.Name(name), create: false).map(read(from:)) ?? [:])
        } else {
          result(read(from: .general))
        }
      case "readHtml":
        result(readHtml())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    return channel
  }

  private static func write(_ rawArguments: Any?, result: FlutterResult) {
    guard let arguments = rawArguments as? [String: Any],
          let text = arguments["text"] as? String,
          let html = arguments["html"] as? String else {
      result(FlutterError(code: "clipboard_arguments", message: "Missing clipboard data", details: nil))
      return
    }
    let name = arguments["pasteboard"] as? String
    let pasteboard = name.flatMap { $0.isEmpty ? nil : UIPasteboard(name: UIPasteboard.Name($0), create: true) }
    write(
      text: text,
      html: html,
      kapy: arguments["kapy"] as? String,
      image: (arguments["image"] as? FlutterStandardTypedData)?.data,
      imageMime: arguments["imageMime"] as? String,
      to: pasteboard ?? .general
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
    to pasteboard: UIPasteboard
  ) {
    var item: [String: Any] = [
      UTType.utf8PlainText.identifier: text,
      UTType.html.identifier: html,
    ]
    if let kapy, !kapy.isEmpty {
      item[kapyType] = Data(kapy.utf8)
    }
    if let image, !image.isEmpty,
       let imageMime,
       let type = UTType(mimeType: imageMime) {
      item[type.identifier] = image
    }
    pasteboard.setItems([item], options: [:])
  }

  private static func readHtml() -> String? {
    let pasteboard = UIPasteboard.general
    if let data = pasteboard.data(forPasteboardType: UTType.html.identifier) {
      return String(data: data, encoding: .utf8)
    }
    return pasteboard.value(forPasteboardType: UTType.html.identifier) as? String
  }

  /// Everything on `pasteboard` that a paste can use, in the shape
  /// `ClipboardSnapshot.fromChannel` reads.
  ///
  /// The contents are fetched once, with `items`, so iOS asks for
  /// permission to paste at most once. Rich text is converted to HTML only
  /// when nothing else offers HTML, because the conversion is slow and HTML
  /// from the source is better.
  static func read(from pasteboard: UIPasteboard) -> [String: Any] {
    guard pasteboard.numberOfItems > 0 else { return ["types": [String]()] }
    let items = pasteboard.items
    var types: [String] = []
    for item in items {
      for type in item.keys.sorted() where !types.contains(type) {
        types.append(type)
      }
    }
    func value(_ type: String) -> Any? {
      items.lazy.compactMap { $0[type] }.first
    }

    var snapshot: [String: Any] = ["types": types]
    snapshot["text"] = string(value(UTType.utf8PlainText.identifier))
      ?? string(value(UTType.plainText.identifier))
    snapshot["vscode"] = string(value(vscodeType))
    snapshot["kapy"] = string(value(kapyType))

    var html = string(value(UTType.html.identifier))
    var sourceUrl = string(value(sourceUrlType))
    var resources: [[String: Any]] = []
    if let data = webArchiveTypes.lazy.compactMap({ data(value($0)) }).first,
       let archive = webArchive(data) {
      html = html ?? archive.html
      sourceUrl = sourceUrl ?? archive.url
      resources += archive.resources
    }
    if html == nil,
       let richText = richText(
         rtfd: data(value(UTType.flatRTFD.identifier)),
         rtf: data(value(UTType.rtf.identifier))
       ),
       let converted = convertToHtml(richText) {
      snapshot["rtfHtml"] = converted.html
      resources += converted.resources
    }
    snapshot["html"] = html
    snapshot["sourceUrl"] = sourceUrl
    if !resources.isEmpty {
      snapshot["resources"] = resources
    }

    let files = items.compactMap { fileUrl($0[UTType.fileURL.identifier])?.path }
    if !files.isEmpty {
      snapshot["files"] = files
    }

    if let png = imageData(value(UTType.png.identifier)) {
      snapshot["image"] = FlutterStandardTypedData(bytes: png)
      snapshot["imageMime"] = "image/png"
    } else if let jpeg = imageData(value(UTType.jpeg.identifier)) {
      snapshot["image"] = FlutterStandardTypedData(bytes: jpeg)
      snapshot["imageMime"] = "image/jpeg"
    } else if let tiff = data(value(UTType.tiff.identifier)), let png = pngData(tiff, type: .tiff) {
      snapshot["image"] = FlutterStandardTypedData(bytes: png)
      snapshot["imageMime"] = "image/png"
    }
    return snapshot
  }

  /// A pasteboard value as text: `items` returns text as a string or as data.
  private static func string(_ value: Any?) -> String? {
    switch value {
    case let text as String:
      return text
    case let data as Data:
      return String(data: data, encoding: .utf8)
    case let url as URL:
      return url.absoluteString
    default:
      return nil
    }
  }

  private static func data(_ value: Any?) -> Data? {
    switch value {
    case let data as Data:
      return data
    case let text as String:
      return Data(text.utf8)
    default:
      return nil
    }
  }

  /// A picture's bytes: `items` returns pictures as data or as a `UIImage`.
  private static func imageData(_ value: Any?) -> Data? {
    switch value {
    case let data as Data:
      return data.isEmpty ? nil : data
    case let image as UIImage:
      return image.pngData()
    default:
      return nil
    }
  }

  private static func fileUrl(_ value: Any?) -> URL? {
    let url: URL?
    switch value {
    case let value as URL:
      url = value
    case let data as Data:
      url = URL(dataRepresentation: data, relativeTo: nil)
    case let text as String:
      url = URL(string: text)
    default:
      url = nil
    }
    return url?.isFileURL == true ? url : nil
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
    if let rtfd,
       let text = try? NSAttributedString(
         data: rtfd,
         options: [.documentType: NSAttributedString.DocumentType.rtfd],
         documentAttributes: nil
       ) {
      return text
    }
    if let rtf,
       let text = try? NSAttributedString(
         data: rtf,
         options: [.documentType: NSAttributedString.DocumentType.rtf],
         documentAttributes: nil
       ) {
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
      return pngData(bytes, type: type).map { ($0, "image/png") }
    }
    return type.preferredMIMEType.map { (bytes, $0) }
  }

  /// A TIFF, or a PDF's first page, as PNG.
  private static func pngData(_ data: Data, type: UTType) -> Data? {
    guard type.conforms(to: .pdf) else { return UIImage(data: data)?.pngData() }
    guard let provider = CGDataProvider(data: data as CFData),
          let page = CGPDFDocument(provider)?.page(at: 1) else {
      return nil
    }
    let bounds = page.getBoxRect(.mediaBox)
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: bounds.size, format: format).pngData { context in
      let cg = context.cgContext
      cg.translateBy(x: 0, y: bounds.height)
      cg.scaleBy(x: 1, y: -1)
      cg.translateBy(x: -bounds.minX, y: -bounds.minY)
      cg.drawPDFPage(page)
    }
  }
}
