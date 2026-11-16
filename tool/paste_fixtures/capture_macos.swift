#!/usr/bin/env swift
// Records every representation of every item on a macOS pasteboard as a clipboard fixture.
//
//   swift tool/paste_fixtures/capture_macos.swift <source> <case> [--pasteboard <name>] [--out <dir>] [--force]
//
// Run it from the repository root right after copying in the source app (the clipboard is
// read the moment the script starts, so copy first, then run it in Terminal).
//
// Output: <out>/<source>/<case>/fixture.json plus one file per representation
// (default <out> is test/fixtures/paste). Item 0 files are named "<type>.<ext>", later
// items "item<N>.<type>.<ext>".
//
// Using the source/case of an existing SYNTHESIZED fixture replaces it with the real capture.
// An existing real fixture is never overwritten unless --force is given.
//
// This script only READS. It never calls clearContents, setData, setString, setPropertyList,
// writeObjects or declareTypes on any pasteboard. By default it reads NSPasteboard.general.
// --pasteboard <name> reads the named pasteboard instead (used for testing against a
// private pasteboard that the test creates itself).

import AppKit
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

var positional: [String] = []
var pasteboardName: String?
var outRoot = "test/fixtures/paste"
var force = false
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
  let a = args.removeFirst()
  switch a {
  case "--pasteboard":
    guard !args.isEmpty else { fail("--pasteboard needs a name") }
    pasteboardName = args.removeFirst()
  case "--force":
    force = true
  case "--out":
    guard !args.isEmpty else { fail("--out needs a directory") }
    outRoot = args.removeFirst()
  default:
    positional.append(a)
  }
}
guard positional.count == 2 else {
  fail("usage: swift tool/paste_fixtures/capture_macos.swift <source> <case> [--pasteboard <name>] [--out <dir>]")
}
let source = positional[0]
let caseName = positional[1]
let slug = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9-]*$")
for part in [source, caseName] {
  if slug.firstMatch(in: part, range: NSRange(part.startIndex..., in: part)) == nil {
    fail("'\(part)' must be kebab-case ([a-z0-9-])")
  }
}

let pasteboard: NSPasteboard
if let name = pasteboardName {
  pasteboard = NSPasteboard(name: NSPasteboard.Name(name))
} else {
  pasteboard = NSPasteboard.general
}

let extensions: [String: String] = [
  "public.html": "html",
  "public.utf8-plain-text": "txt",
  "public.utf16-plain-text": "txt",
  "public.utf16-external-plain-text": "txt",
  "public.plain-text": "txt",
  "NSStringPboardType": "txt",
  "public.rtf": "rtf",
  "NeXT Rich Text Format v1.0 pasteboard type": "rtf",
  "com.apple.flat-rtfd": "rtfd",
  "com.apple.webarchive": "webarchive",
  "Apple Web Archive pasteboard type": "webarchive",
  "public.png": "png",
  "public.tiff": "tiff",
  "NeXT TIFF v4.0 pasteboard type": "tiff",
  "public.jpeg": "jpg",
  "public.file-url": "txt",
  "public.url": "txt",
  "public.url-name": "txt",
  "org.chromium.source-url": "txt",
  "vscode-editor-data": "json",
  "NSFilenamesPboardType": "plist",
  "com.apple.property-list": "plist",
]

func safeName(_ type: String) -> String {
  String(type.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
}

let items = pasteboard.pasteboardItems ?? []
if items.isEmpty { fail("the pasteboard has no items") }

let dir = URL(fileURLWithPath: outRoot).appendingPathComponent(source).appendingPathComponent(caseName)
let existing = dir.appendingPathComponent("fixture.json")
if let data = try? Data(contentsOf: existing), let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
  if (old["capture"] as? String) != "synthesized" && !force { fail("\(existing.path) is a real capture; pass --force to replace it") }
  try FileManager.default.removeItem(at: dir)
}
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

var jsonItems: [[String: Any]] = []
for (index, item) in items.enumerated() {
  var reps: [[String: String]] = []
  for type in item.types {
    var data = item.data(forType: type)
    if data == nil, let plist = item.propertyList(forType: type) {
      data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    }
    guard let bytes = data else {
      FileHandle.standardError.write(Data("skipped \(type.rawValue): no data\n".utf8))
      continue
    }
    let ext = extensions[type.rawValue] ?? "bin"
    let file = (index == 0 ? "" : "item\(index).") + safeName(type.rawValue) + "." + ext
    try bytes.write(to: dir.appendingPathComponent(file))
    reps.append(["type": type.rawValue, "file": file])
  }
  jsonItems.append(["representations": reps])
}

let fixture: [String: Any] = [
  "source": source,
  "case": caseName,
  "app": "TODO: app and version the text was copied from",
  "platform": "macos",
  "capture": "real",
  "how": "TODO: what was selected/copied, in one or two sentences",
  "notes": "TODO: anything tricky in this payload",
  "items": jsonItems,
]
let json = try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try json.write(to: dir.appendingPathComponent("fixture.json"))
let total = jsonItems.reduce(0) { $0 + ($1["representations"] as! [[String: String]]).count }
print("wrote \(total) representations from \(items.count) item(s) to \(dir.path)")
print("Edit fixture.json: fill in app, how and notes.")
