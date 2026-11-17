#!/usr/bin/env swift
// Synthesizes the Apple-native clipboard fixtures (Apple Notes, Pages, Safari, a copied image) the way
// those apps produce them: NSAttributedString -> RTF / flat RTFD / Cocoa HTML, plus a hand-built WebArchive.
//   swift tool/paste_fixtures/synthesize/apple.swift [outRoot]      (default outRoot: test/fixtures/paste)
// It never touches any pasteboard; it only writes files.
import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test/fixtures/paste")

func png(width: Int, height: Int, seed: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSColor(calibratedWhite: 0.98, alpha: 1).setFill()
  NSRect(x: 0, y: 0, width: width, height: height).fill()
  let heights: [CGFloat] = [0.35, 0.6, 0.45, 0.85, 0.7]
  for (i, h) in heights.enumerated() {
    NSColor(calibratedHue: CGFloat((i + seed) % 5) / 6.0 + 0.5, saturation: 0.6, brightness: 0.85, alpha: 1).setFill()
    let w = CGFloat(width - 40) / CGFloat(heights.count)
    NSRect(x: 20 + CGFloat(i) * w, y: 12, width: w - 8, height: h * CGFloat(height - 30)).fill()
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

struct Rep { let type: String; let file: String; let data: Data }
func write(source: String, kase: String, app: String, how: String, notes: String, reps: [Rep]) throws {
  let dir = root.appendingPathComponent(source).appendingPathComponent(kase)
  try? FileManager.default.removeItem(at: dir)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  for r in reps { try r.data.write(to: dir.appendingPathComponent(r.file)) }
  let fixture: [String: Any] = [
    "source": source, "case": kase, "app": app, "platform": "macos", "capture": "synthesized", "how": how, "notes": notes,
    "items": [["representations": reps.map { ["type": $0.type, "file": $0.file] }]],
  ]
  let json = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .withoutEscapingSlashes])
  try json.write(to: dir.appendingPathComponent("fixture.json"))
  print("wrote \(source)/\(kase):", reps.map { $0.type }.joined(separator: ", "))
}

func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
  var f = NSFont(name: "Helvetica", size: size)!
  let fm = NSFontManager.shared
  if bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
  if italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
  return f
}

// ---- a note/document body: title, styled runs, bullet list (nested), numbered list, checklist, image ----
func document(title: String, includeImage: Bool, checklistMarkers: Bool) -> NSAttributedString {
  let out = NSMutableAttributedString()
  let body = font(14)
  func para(_ list: [NSTextList] = [], indent: CGFloat = 0) -> NSMutableParagraphStyle {
    let p = NSMutableParagraphStyle()
    p.textLists = list
    if !list.isEmpty {
      let depth = CGFloat(list.count)
      p.firstLineHeadIndent = 18 * depth - 18 + indent
      p.headIndent = 18 * depth + 18
      p.tabStops = [NSTextTab(textAlignment: .left, location: 18 * depth), NSTextTab(textAlignment: .left, location: 18 * depth + 18)]
    }
    return p
  }
  func add(_ text: String, _ attrs: [NSAttributedString.Key: Any]) { out.append(NSAttributedString(string: text, attributes: attrs)) }
  let basic: [NSAttributedString.Key: Any] = [.font: body, .paragraphStyle: para()]

  add(title + "\n", [.font: font(24, bold: true), .paragraphStyle: para()])
  add("Plain text, then ", basic)
  add("bold", [.font: font(14, bold: true), .paragraphStyle: para()])
  add(", ", basic)
  add("italic", [.font: font(14, italic: true), .paragraphStyle: para()])
  add(", ", basic)
  add("underlined", basic.merging([.underlineStyle: NSUnderlineStyle.single.rawValue]) { $1 })
  add(", ", basic)
  add("struck through", basic.merging([.strikethroughStyle: NSUnderlineStyle.single.rawValue]) { $1 })
  add(" and a ", basic)
  add("link", basic.merging([.link: URL(string: "https://example.com/roadmap")!, .foregroundColor: NSColor.systemBlue, .underlineStyle: NSUnderlineStyle.single.rawValue]) { $1 })
  add(".\n", basic)

  let disc = NSTextList(markerFormat: .disc, options: 0)
  let circle = NSTextList(markerFormat: .circle, options: 0)
  let decimal = NSTextList(markerFormat: .decimal, options: 0)
  func item(_ text: String, lists: [NSTextList], number: Int) {
    let marker = lists.last!.marker(forItemNumber: number)
    add("\t" + marker + "\t" + text + "\n", [.font: body, .paragraphStyle: para(lists)])
  }
  item("Ship the importer", lists: [disc], number: 1)
  item("Word and Excel", lists: [disc, circle], number: 1)
  item("Apple Notes", lists: [disc, circle], number: 2)
  item("Write the release notes", lists: [disc], number: 2)
  item("Collect fixtures", lists: [decimal], number: 1)
  item("Write the parser", lists: [decimal], number: 2)
  item("Review with design", lists: [decimal], number: 3)

  for (text, done) in [("Buy milk", false), ("Send the invoice", true)] {
    add((checklistMarkers ? (done ? "\u{2611} " : "\u{2610} ") : "") + text + "\n", basic)
  }

  if includeImage {
    let wrapper = FileWrapper(regularFileWithContents: png(width: 240, height: 140, seed: 1))
    wrapper.preferredFilename = "chart.png"
    let attachment = NSTextAttachment()
    attachment.fileWrapper = wrapper
    out.append(NSAttributedString(attachment: attachment))
    add("\n", basic)
  }
  return out
}

let full = NSRange(location: 0, length: 0)
func rtf(_ s: NSAttributedString) -> Data { try! s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) }
func rtfd(_ s: NSAttributedString) -> Data { s.rtfd(from: NSRange(location: 0, length: s.length), documentAttributes: [:])! }
func html(_ s: NSAttributedString) -> Data { try! s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue]) }
func text(_ s: String) -> Data { Data(s.utf8) }

// ---- Apple Notes ----
let notesDoc = document(title: "Quarterly planning", includeImage: true, checklistMarkers: false)
try write(
  source: "apple-notes", kase: "rich-note-title-lists-checklist-image", app: "Notes 4.x for macOS (synthesized)",
  how: "Synthesized with NSAttributedString: a note with a Title line, bold/italic/underline/strikethrough runs, a link, a nested bullet list, a numbered list, a two-item checklist and an inline PNG attachment, selected and copied in Notes.",
  notes: "SYNTHESIZED (capture it for real with tool/paste_fixtures/capture_macos.swift). Notes puts RTF, flat RTFD (the PNG is embedded as an attachment with \\NeXTGraphic / chart.png), plain text and Cocoa HTML on the pasteboard; RTF/RTFD/HTML here are generated by NSAttributedString, which is how Cocoa apps produce them. The list markers are real \\listtext paragraphs (\\t•\\t) with {\\*\\listtable} definitions. UNSURE: Notes keeps checklist state only in private pasteboard types (not reproduced); I assume the RTF/plain text keep just the item text without a checkbox glyph, so the checklist here is two plain paragraphs. The Notes Title style is modelled as a 24pt bold first paragraph. Helvetica is used instead of Notes' own system font names.",
  reps: [
    Rep(type: "public.rtf", file: "public.rtf.rtf", data: rtf(notesDoc)),
    Rep(type: "com.apple.flat-rtfd", file: "com.apple.flat-rtfd.rtfd", data: rtfd(notesDoc)),
    Rep(type: "public.utf8-plain-text", file: "public.utf8-plain-text.txt", data: text(notesDoc.string.replacingOccurrences(of: "\u{FFFC}", with: "\u{FFFC}"))),
    Rep(type: "public.html", file: "public.html.html", data: html(notesDoc)),
  ])

// ---- Pages ----
let pagesDoc = document(title: "Project brief", includeImage: true, checklistMarkers: true)
try write(
  source: "pages", kase: "document-selection-lists-image", app: "Pages 14.x for macOS (synthesized)",
  how: "Synthesized with NSAttributedString: a heading-styled paragraph, styled runs, a nested bullet list, a numbered list and a picture selected in a Pages document and copied.",
  notes: "SYNTHESIZED. Pages writes RTF, flat RTFD (picture as attachment) and plain text, plus private com.apple.iWork.* types with the native object data that only iWork apps read (not reproduced; unsure of the names). The checklist paragraphs use ballot-box glyphs because that is how Pages' RTF exports its checklist-style bullets as far as I know (unsure). Plain text keeps U+FFFC (object replacement character) where the picture sits.",
  reps: [
    Rep(type: "public.rtf", file: "public.rtf.rtf", data: rtf(pagesDoc)),
    Rep(type: "com.apple.flat-rtfd", file: "com.apple.flat-rtfd.rtfd", data: rtfd(pagesDoc)),
    Rep(type: "public.utf8-plain-text", file: "public.utf8-plain-text.txt", data: text(pagesDoc.string)),
  ])

// ---- Safari: selection with an image, as a WebArchive ----
let imgBytes = png(width: 240, height: 140, seed: 3)
let pageURL = "https://example.com/articles/fixtures"
let imgURL = "https://example.com/articles/img/chart.png"
let selectionHtml = "<meta charset=\"utf-8\"><h2 style=\"font-family: Georgia, serif; font-size: 22px; font-weight: 700;\">Why fixtures matter</h2><p style=\"font-family: Georgia, serif; font-size: 16px;\">A paste pipeline is only as good as the payloads you test it against. <a href=\"https://example.com/articles/other\">See also</a>.</p><figure style=\"margin: 0px;\"><img src=\"\(imgURL)\" alt=\"Bar chart of coverage\" width=\"240\" height=\"140\"><figcaption style=\"font-size: 13px;\">Coverage by source app.</figcaption></figure>"
let archive: [String: Any] = [
  "WebMainResource": [
    "WebResourceData": Data(("<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\"></head><body>" + selectionHtml + "</body></html>").utf8),
    "WebResourceFrameName": "",
    "WebResourceMIMEType": "text/html",
    "WebResourceTextEncodingName": "UTF-8",
    "WebResourceURL": pageURL,
  ] as [String: Any],
  "WebSubresources": [
    [
      "WebResourceData": imgBytes,
      "WebResourceMIMEType": "image/png",
      "WebResourceResponse": try! NSKeyedArchiver.archivedData(withRootObject: HTTPURLResponse(url: URL(string: imgURL)!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png", "Content-Length": "\(imgBytes.count)"])!, requiringSecureCoding: false),
      "WebResourceURL": imgURL,
    ] as [String: Any],
  ],
]
let archiveData = try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
let safariAttr = NSMutableAttributedString()
safariAttr.append(NSAttributedString(string: "Why fixtures matter\n", attributes: [.font: NSFont(name: "Georgia-Bold", size: 22)!]))
safariAttr.append(NSAttributedString(string: "A paste pipeline is only as good as the payloads you test it against. ", attributes: [.font: NSFont(name: "Georgia", size: 16)!]))
safariAttr.append(NSAttributedString(string: "See also", attributes: [.font: NSFont(name: "Georgia", size: 16)!, .link: URL(string: "https://example.com/articles/other")!]))
safariAttr.append(NSAttributedString(string: ".\n", attributes: [.font: NSFont(name: "Georgia", size: 16)!]))
let safariWrapper = FileWrapper(regularFileWithContents: imgBytes)
safariWrapper.preferredFilename = "chart.png"
let safariAttachment = NSTextAttachment()
safariAttachment.fileWrapper = safariWrapper
safariAttr.append(NSAttributedString(attachment: safariAttachment))
safariAttr.append(NSAttributedString(string: "\nCoverage by source app.", attributes: [.font: NSFont(name: "Georgia", size: 13)!]))
try write(
  source: "safari", kase: "selection-with-image-webarchive", app: "Safari 18.x for macOS (synthesized)",
  how: "Synthesized: selecting a heading, a paragraph with a link and an image with caption on a web page in Safari and copying.",
  notes: "SYNTHESIZED. com.apple.webarchive is a binary property list built with PropertyListSerialization: WebMainResource (WebResourceData = the selection as an HTML document, WebResourceMIMEType, WebResourceTextEncodingName, WebResourceURL = the page URL, WebResourceFrameName) and WebSubresources (one dict per image with WebResourceData = the PNG bytes, WebResourceMIMEType, WebResourceURL, WebResourceResponse = NSKeyedArchiver data of an NSHTTPURLResponse). Safari also writes RTF, flat RTFD (with the image attachment), HTML and plain text; the exact set is from memory (UNSURE whether current Safari still writes public.html), and WebKit may add com.apple.WebKit.custom-pasteboard-data (not reproduced). The image URL in the HTML is absolute here; in the live page it may be relative, but WebKit resolves URLs when serializing a selection.",
  reps: [
    Rep(type: "com.apple.webarchive", file: "com.apple.webarchive.webarchive", data: archiveData),
    Rep(type: "public.rtf", file: "public.rtf.rtf", data: rtf(safariAttr)),
    Rep(type: "com.apple.flat-rtfd", file: "com.apple.flat-rtfd.rtfd", data: rtfd(safariAttr)),
    Rep(type: "public.html", file: "public.html.html", data: Data(selectionHtml.utf8)),
    Rep(type: "public.utf8-plain-text", file: "public.utf8-plain-text.txt", data: text("Why fixtures matter\nA paste pipeline is only as good as the payloads you test it against. See also.\n\u{FFFC}\nCoverage by source app.")),
  ])

// ---- A single copied image (Preview / Cmd+C on an image) ----
let imgData = png(width: 320, height: 200, seed: 0)
let tiff = NSBitmapImageRep(data: imgData)!.tiffRepresentation!
try write(
  source: "image", kase: "single-image-png-tiff", app: "Preview 11.x for macOS (synthesized)",
  how: "Synthesized: a 320x200 image copied from Preview (Edit > Copy).",
  notes: "SYNTHESIZED. macOS image copies carry the image as public.png and public.tiff (same pixels); some apps add com.apple.pict or only TIFF. There is no text representation, which is the point of the fixture: a clipboard with images and no text/html. Pixel content is a generated bar chart.",
  reps: [
    Rep(type: "public.png", file: "public.png.png", data: imgData),
    Rep(type: "public.tiff", file: "public.tiff.tiff", data: tiff),
  ])
