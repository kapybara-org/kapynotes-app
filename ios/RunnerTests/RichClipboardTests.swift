import Flutter
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import Runner

/// Reads and writes a private pasteboard, never the user's clipboard.
class RichClipboardTests: XCTestCase {
  private var pasteboard: UIPasteboard!
  private var generalChangeCount = 0

  override func setUp() {
    super.setUp()
    generalChangeCount = UIPasteboard.general.changeCount
    pasteboard = UIPasteboard.withUniqueName()
  }

  override func tearDown() {
    UIPasteboard.remove(withName: pasteboard.name)
    XCTAssertEqual(UIPasteboard.general.changeCount, generalChangeCount)
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

  private func picture(_ color: UIColor) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3), format: format).image {
      color.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
    }
  }

  private func tiff(_ image: UIImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image.cgImage!, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
  }

  private func isPng(_ data: Data?) -> Bool {
    data?.starts(with: [0x89, 0x50, 0x4E, 0x47]) == true
  }

  func testReadsHtmlTextAndTheirCompanions() {
    let vscode = #"{"version":1,"mode":"dart"}"#
    pasteboard.setItems([[
      UTType.html.identifier: "<p>Hello <b>world</b> ✓</p>",
      UTType.utf8PlainText.identifier: "Hello world ✓",
      "org.chromium.source-url": Data("https://example.com/page".utf8),
      "vscode-editor-data": Data(vscode.utf8),
      RichClipboard.kapyType: Data(#"{"kapy":1}"#.utf8),
      UTType.rtf.identifier: Data(#"{\rtf1\ansi Hello}"#.utf8),
    ]])

    let snapshot = read()

    XCTAssertEqual(snapshot["html"] as? String, "<p>Hello <b>world</b> ✓</p>")
    XCTAssertEqual(snapshot["text"] as? String, "Hello world ✓")
    XCTAssertEqual(snapshot["sourceUrl"] as? String, "https://example.com/page")
    XCTAssertEqual(snapshot["vscode"] as? String, vscode)
    XCTAssertEqual(snapshot["kapy"] as? String, #"{"kapy":1}"#)
    XCTAssertNil(snapshot["rtfHtml"], "RTF is not converted when there is HTML")
    let types = snapshot["types"] as? [String] ?? []
    XCTAssertTrue(types.contains(UTType.html.identifier))
    XCTAssertTrue(types.contains(RichClipboard.kapyType))
    XCTAssertNil(snapshot["image"])
    XCTAssertNil(snapshot["files"])
  }

  func testConvertsRtfdWithItsPicturesNamedAsTheHtmlNamesThem() throws {
    let red = picture(.red).pngData()!
    let blue = tiff(picture(.blue))
    let text = NSMutableAttributedString(string: "Shopping ")
    for (bytes, name) in [(red, "photo one.png"), (blue, "Pasted Graphic.tiff")] {
      let wrapper = FileWrapper(regularFileWithContents: bytes)
      wrapper.preferredFilename = name
      let attachment = NSTextAttachment()
      attachment.fileWrapper = wrapper
      text.append(NSAttributedString(attachment: attachment))
    }
    text.append(NSAttributedString(
      string: " list\n",
      attributes: [.font: UIFont.boldSystemFont(ofSize: 14)]
    ))
    let rtfd = try text.data(
      from: NSRange(location: 0, length: text.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
    )
    pasteboard.setItems([[
      UTType.flatRTFD.identifier: rtfd,
      UTType.utf8PlainText.identifier: "Shopping list",
    ]])

    let snapshot = read()

    XCTAssertNil(snapshot["html"])
    let html = snapshot["rtfHtml"] as? String ?? ""
    XCTAssertTrue(html.contains(#"<img src="file:///photo%20one.png""#), html)
    XCTAssertTrue(html.contains(#"<img src="file:///Pasted%20Graphic.tiff""#), html)
    let named = resources(snapshot)
    XCTAssertEqual(Set(named.keys), ["file:///photo%20one.png", "file:///Pasted%20Graphic.tiff"], html)
    XCTAssertEqual(named["file:///photo%20one.png"]?.mime, "image/png")
    XCTAssertEqual(named["file:///photo%20one.png"]?.data, red)
    XCTAssertEqual(named["file:///Pasted%20Graphic.tiff"]?.mime, "image/png")
    XCTAssertTrue(isPng(named["file:///Pasted%20Graphic.tiff"]?.data))
  }

  func testConvertsPlainRtfWhenThereIsNoHtml() {
    pasteboard.setItems([[UTType.rtf.identifier: Data(#"{\rtf1\ansi Plain {\b bold}}"#.utf8)]])

    let snapshot = read()

    let html = snapshot["rtfHtml"] as? String ?? ""
    XCTAssertTrue(html.contains("bold"), html)
    XCTAssertNil(snapshot["resources"])
  }

  func testReadsSafarisWebArchive() throws {
    let photo = picture(.green).pngData()!
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
    pasteboard.setItems([[
      "com.apple.webarchive": data,
      UTType.utf8PlainText.identifier: "From Safari",
    ]])

    let snapshot = read()

    XCTAssertEqual(snapshot["html"] as? String, "<p>From Safari <img src=\"/a/photo.png\"></p>")
    XCTAssertEqual(snapshot["sourceUrl"] as? String, "https://example.com/a/page.html")
    let named = resources(snapshot)
    XCTAssertEqual(named["https://example.com/a/photo.png"]?.mime, "image/png")
    XCTAssertEqual(named["https://example.com/a/photo.png"]?.data, photo)
  }

  func testReadsFileUrls() {
    let file = URL(fileURLWithPath: "/tmp/kapy clipboard.txt")
    pasteboard.setItems([[UTType.fileURL.identifier: file]])

    let snapshot = read()

    XCTAssertEqual(snapshot["files"] as? [String], [file.path])
  }

  func testReadsPngAsItIs() {
    let png = picture(.red).pngData()!
    pasteboard.setItems([[UTType.png.identifier: png]])

    let snapshot = read()

    XCTAssertTrue(isPng(bytes(snapshot["image"])))
    XCTAssertEqual(snapshot["imageMime"] as? String, "image/png")
  }

  func testReadsTiffAsPng() {
    pasteboard.setItems([[UTType.tiff.identifier: tiff(picture(.blue))]])

    let snapshot = read()

    XCTAssertTrue(isPng(bytes(snapshot["image"])))
    XCTAssertEqual(snapshot["imageMime"] as? String, "image/png")
  }

  func testReadsJpeg() {
    pasteboard.setItems([[UTType.jpeg.identifier: picture(.red).jpegData(compressionQuality: 0.9)!]])

    let snapshot = read()

    XCTAssertEqual(bytes(snapshot["image"])?.starts(with: [0xFF, 0xD8]), true)
    XCTAssertEqual(snapshot["imageMime"] as? String, "image/jpeg")
  }

  func testWritesKapysFragmentBesideTheOtherRepresentations() {
    let png = picture(.red).pngData()!
    RichClipboard.write(
      text: "Groceries",
      html: "<p>Groceries</p>",
      kapy: #"{"body":"Groceries"}"#,
      image: png,
      imageMime: "image/png",
      to: pasteboard
    )

    XCTAssertEqual(pasteboard.numberOfItems, 1)
    let snapshot = read()
    XCTAssertEqual(snapshot["text"] as? String, "Groceries")
    XCTAssertEqual(snapshot["html"] as? String, "<p>Groceries</p>")
    XCTAssertEqual(snapshot["kapy"] as? String, #"{"body":"Groceries"}"#)
    XCTAssertTrue(isPng(bytes(snapshot["image"])))
  }

  func testEmptyPasteboardReadsAsNothing() {
    pasteboard.items = []

    let snapshot = read()

    XCTAssertEqual(snapshot["types"] as? [String], [])
    XCTAssertEqual(snapshot.count, 1)
  }
}
