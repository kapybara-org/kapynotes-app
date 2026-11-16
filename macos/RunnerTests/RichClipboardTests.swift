import Cocoa
import FlutterMacOS
import UniformTypeIdentifiers
import XCTest

@testable import Kapy_Notes

/// Reads and writes a private pasteboard, never the user's clipboard.
class RichClipboardTests: XCTestCase {
  private var pasteboard: NSPasteboard!
  private var generalChangeCount = 0

  override func setUp() {
    super.setUp()
    generalChangeCount = NSPasteboard.general.changeCount
    pasteboard = NSPasteboard.withUniqueName()
  }

  override func tearDown() {
    pasteboard.releaseGlobally()
    XCTAssertEqual(NSPasteboard.general.changeCount, generalChangeCount)
    super.tearDown()
  }

  private func read() -> [String: Any] {
    RichClipboard.read(from: pasteboard)
  }

  private func bytes(_ value: Any?) -> Data? {
    (value as? FlutterStandardTypedData)?.data
  }

  private func resources(_ snapshot: [String: Any]) -> [String: (mime: String, data: Data)] {
    var named: [String: (mime: String, data: Data)] = [:]
    for resource in snapshot["resources"] as? [[String: Any]] ?? [] {
      named[resource["name"] as! String] = (resource["mime"] as! String, bytes(resource["data"])!)
    }
    return named
  }

  private func picture(_ color: NSColor) -> (png: Data, tiff: Data) {
    let image = NSImage(size: NSSize(width: 4, height: 3))
    image.lockFocus()
    color.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 3).fill()
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    return (NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!, tiff)
  }

  private func isPng(_ data: Data?) -> Bool {
    data?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true
  }

  func testReadsHtmlTextAndTheirCompanions() {
    let vscode = #"{"version":1,"mode":"dart"}"#
    pasteboard.declareTypes(
      [
        .html, .string,
        NSPasteboard.PasteboardType("org.chromium.source-url"),
        NSPasteboard.PasteboardType("vscode-editor-data"),
        RichClipboard.kapyType,
      ],
      owner: nil
    )
    pasteboard.setString("<p>Hello <b>world</b> ✓</p>", forType: .html)
    pasteboard.setString("Hello world ✓", forType: .string)
    pasteboard.setString("https://example.com/page", forType: NSPasteboard.PasteboardType("org.chromium.source-url"))
    pasteboard.setString(vscode, forType: NSPasteboard.PasteboardType("vscode-editor-data"))
    pasteboard.setString(#"{"kapy":1}"#, forType: RichClipboard.kapyType)
    pasteboard.setData(Data(#"{\rtf1\ansi Hello}"#.utf8), forType: .rtf)

    let snapshot = read()

    XCTAssertEqual(snapshot["html"] as? String, "<p>Hello <b>world</b> ✓</p>")
    XCTAssertEqual(snapshot["text"] as? String, "Hello world ✓")
    XCTAssertEqual(snapshot["sourceUrl"] as? String, "https://example.com/page")
    XCTAssertEqual(snapshot["vscode"] as? String, vscode)
    XCTAssertEqual(snapshot["kapy"] as? String, #"{"kapy":1}"#)
    XCTAssertNil(snapshot["rtfHtml"], "RTF is not converted when there is HTML")
    let types = snapshot["types"] as? [String] ?? []
    XCTAssertTrue(types.contains("public.html"))
    XCTAssertTrue(types.contains("com.kapybara.kapynotes.fragment"))
    XCTAssertNil(snapshot["image"])
    XCTAssertNil(snapshot["files"])
  }

  func testReadsVsCodesDataFromChromiumsCustomData() {
    let vscode = #"{"version":1,"mode":"python"}"#
    var pickle = Data()
    func append(_ value: UInt32) {
      withUnsafeBytes(of: value.littleEndian) { pickle.append(contentsOf: $0) }
    }
    func append(_ string: String) {
      let units = Array(string.utf16)
      append(UInt32(units.count))
      for unit in units {
        withUnsafeBytes(of: unit.littleEndian) { pickle.append(contentsOf: $0) }
      }
      if units.count % 2 == 1 {
        pickle.append(contentsOf: [0, 0])
      }
    }
    append(UInt32(0))
    append(UInt32(2))
    append("text/x-other")
    append("é")
    append("vscode-editor-data")
    append(vscode)
    pickle.replaceSubrange(0..<4, with: withUnsafeBytes(of: UInt32(pickle.count - 4).littleEndian) { Data($0) })
    let type = NSPasteboard.PasteboardType("org.chromium.web-custom-data")
    pasteboard.declareTypes([type, .string], owner: nil)
    pasteboard.setData(pickle, forType: type)
    pasteboard.setString("print(1)", forType: .string)

    XCTAssertEqual(RichClipboard.webCustomData(pickle), ["text/x-other": "é", "vscode-editor-data": vscode])
    XCTAssertEqual(read()["vscode"] as? String, vscode)
    XCTAssertEqual(RichClipboard.webCustomData(pickle.prefix(20)), [:])
  }

  func testConvertsRtfdWithItsPicturesNamedAsTheHtmlNamesThem() {
    let red = picture(.red)
    let blue = picture(.blue)
    let text = NSMutableAttributedString(string: "Shopping ")
    for (bytes, name) in [(red.png, "photo one.png"), (blue.tiff, "Pasted Graphic.tiff")] {
      let wrapper = FileWrapper(regularFileWithContents: bytes)
      wrapper.preferredFilename = name
      text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
    }
    text.append(NSAttributedString(
      string: " list\n",
      attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
    ))
    let rtfd = text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:])!
    pasteboard.declareTypes([.rtfd, .string], owner: nil)
    pasteboard.setData(rtfd, forType: .rtfd)
    pasteboard.setString("Shopping list", forType: .string)

    let snapshot = read()

    XCTAssertNil(snapshot["html"])
    let html = snapshot["rtfHtml"] as? String ?? ""
    print("RTFD as HTML:\n\(html)")
    XCTAssertTrue(html.contains(#"<img src="file:///photo%20one.png""#), html)
    XCTAssertTrue(html.contains(#"<img src="file:///Pasted%20Graphic.tiff""#), html)
    XCTAssertTrue(html.contains("<b> list</b>"), html)
    let named = resources(snapshot)
    XCTAssertEqual(Set(named.keys), ["file:///photo%20one.png", "file:///Pasted%20Graphic.tiff"])
    XCTAssertEqual(named["file:///photo%20one.png"]?.mime, "image/png")
    XCTAssertEqual(named["file:///photo%20one.png"]?.data, red.png)
    XCTAssertEqual(named["file:///Pasted%20Graphic.tiff"]?.mime, "image/png")
    XCTAssertTrue(isPng(named["file:///Pasted%20Graphic.tiff"]?.data))
  }

  func testReadsRtfdPicturesThatACocoaAppsHtmlShows() {
    let red = picture(.red).png
    let wrapper = FileWrapper(regularFileWithContents: red)
    wrapper.preferredFilename = "chart.png"
    let text = NSMutableAttributedString(string: "Chart ")
    text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
    let rtfd = text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:])!

    for (html, expected) in [
      (#"<p>Chart <img src="file:///chart.png" alt="chart.png"></p>"#, ["file:///chart.png"]),
      (#"<p>Chart <img src="https://example.com/chart.png"></p>"#, []),
    ] {
      pasteboard.declareTypes([.html, .rtfd], owner: nil)
      pasteboard.setString(html, forType: .html)
      pasteboard.setData(rtfd, forType: .rtfd)

      let snapshot = read()

      XCTAssertEqual(snapshot["html"] as? String, html)
      XCTAssertNil(snapshot["rtfHtml"])
      let named = resources(snapshot)
      XCTAssertEqual(Array(named.keys), expected, html)
      if !expected.isEmpty {
        XCTAssertEqual(named["file:///chart.png"]?.mime, "image/png")
        XCTAssertEqual(named["file:///chart.png"]?.data, red)
      }
    }
  }

  func testConvertsPlainRtfWhenThereIsNoHtml() {
    pasteboard.declareTypes([.rtf], owner: nil)
    pasteboard.setData(Data(#"{\rtf1\ansi Plain {\b bold}}"#.utf8), forType: .rtf)

    let snapshot = read()

    XCTAssertTrue((snapshot["rtfHtml"] as? String ?? "").contains("<b>bold</b>"))
    XCTAssertNil(snapshot["resources"])
  }

  func testReadsSafarisWebArchive() throws {
    let photo = picture(.green).png
    let archive: [String: Any] = [
      "WebMainResource": [
        "WebResourceData": Data("<p>From Safari <img src=\"/a/photo.png\"></p>".utf8),
        "WebResourceURL": "https://example.com/a/page.html",
        "WebResourceMIMEType": "text/html",
        "WebResourceTextEncodingName": "UTF-8",
        "WebResourceFrameName": "",
      ],
      "WebSubresources": [
        [
          "WebResourceData": photo,
          "WebResourceURL": "https://example.com/a/photo.png",
          "WebResourceMIMEType": "image/png",
        ],
      ],
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
    pasteboard.declareTypes([NSPasteboard.PasteboardType("com.apple.webarchive"), .string], owner: nil)
    pasteboard.setData(data, forType: NSPasteboard.PasteboardType("com.apple.webarchive"))
    pasteboard.setString("From Safari", forType: .string)

    let snapshot = read()

    XCTAssertEqual(snapshot["html"] as? String, "<p>From Safari <img src=\"/a/photo.png\"></p>")
    XCTAssertEqual(snapshot["sourceUrl"] as? String, "https://example.com/a/page.html")
    XCTAssertNil(snapshot["rtfHtml"])
    let named = resources(snapshot)
    XCTAssertEqual(named["https://example.com/a/photo.png"]?.mime, "image/png")
    XCTAssertEqual(named["https://example.com/a/photo.png"]?.data, photo)
  }

  func testReadsFileUrls() throws {
    let file = FileManager.default.temporaryDirectory
      .appendingPathComponent("kapy clipboard \(UUID().uuidString).txt")
    try Data("notes".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    pasteboard.clearContents()
    pasteboard.writeObjects([file as NSURL])

    let snapshot = read()

    XCTAssertEqual(snapshot["files"] as? [String], [file.path])
    XCTAssertTrue((snapshot["types"] as? [String] ?? []).contains("public.file-url"))
  }

  func testReadsPngAsItIs() {
    let png = picture(.red).png
    pasteboard.declareTypes([.png], owner: nil)
    pasteboard.setData(png, forType: .png)

    let snapshot = read()

    XCTAssertEqual(bytes(snapshot["image"]), png)
    XCTAssertEqual(snapshot["imageMime"] as? String, "image/png")
  }

  func testReadsTiffAsPng() {
    pasteboard.declareTypes([.tiff], owner: nil)
    pasteboard.setData(picture(.blue).tiff, forType: .tiff)

    let snapshot = read()

    XCTAssertTrue(isPng(bytes(snapshot["image"])))
    XCTAssertEqual(snapshot["imageMime"] as? String, "image/png")
  }

  func testReadsJpegAsItIs() {
    let jpeg = NSBitmapImageRep(data: picture(.red).tiff)!
      .representation(using: .jpeg, properties: [:])!
    let type = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    pasteboard.declareTypes([type], owner: nil)
    pasteboard.setData(jpeg, forType: type)

    let snapshot = read()

    XCTAssertEqual(bytes(snapshot["image"]), jpeg)
    XCTAssertEqual(snapshot["imageMime"] as? String, "image/jpeg")
  }

  func testWritesKapysFragmentBesideTheOtherRepresentations() {
    let png = picture(.red).png
    RichClipboard.write(
      text: "Groceries",
      html: "<p>Groceries</p>",
      kapy: #"{"body":"Groceries"}"#,
      image: png,
      imageMime: "image/png",
      to: pasteboard
    )

    XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
    let snapshot = read()
    XCTAssertEqual(snapshot["text"] as? String, "Groceries")
    XCTAssertEqual(snapshot["html"] as? String, "<p>Groceries</p>")
    XCTAssertEqual(snapshot["kapy"] as? String, #"{"body":"Groceries"}"#)
    XCTAssertEqual(bytes(snapshot["image"]), png)
  }

  func testWritesWithoutKapysFragment() {
    RichClipboard.write(
      text: "Plain",
      html: "<p>Plain</p>",
      kapy: nil,
      image: nil,
      imageMime: nil,
      to: pasteboard
    )

    let snapshot = read()
    XCTAssertEqual(snapshot["text"] as? String, "Plain")
    XCTAssertNil(snapshot["kapy"])
    XCTAssertFalse((snapshot["types"] as? [String] ?? []).contains("com.kapybara.kapynotes.fragment"))
  }

  func testEmptyPasteboardReadsAsNothing() {
    pasteboard.clearContents()

    let snapshot = read()

    XCTAssertEqual(snapshot["types"] as? [String], [])
    XCTAssertEqual(snapshot.count, 1)
  }
}
