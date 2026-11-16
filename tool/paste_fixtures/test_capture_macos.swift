#!/usr/bin/env swift
// Self-test for capture_macos.swift. Creates a PRIVATE named pasteboard (never the general one),
// fills it with two items, then lets capture_macos.swift read it back.
//   swift tool/paste_fixtures/test_capture_macos.swift
import AppKit
import Foundation

let name = "com.kapybara.kapynotes.paste-fixtures-selftest-" + UUID().uuidString
let pb = NSPasteboard(name: NSPasteboard.Name(name))
precondition(pb != NSPasteboard.general, "must not use the general pasteboard")
pb.clearContents()
let a = NSPasteboardItem()
a.setString("<b>hi</b>", forType: .html)
a.setString("hi", forType: .string)
a.setData(Data([0x89, 0x50, 0x4e, 0x47, 0, 1, 2, 255]), forType: .png)
a.setString("https://example.com/", forType: NSPasteboard.PasteboardType("org.chromium.source-url"))
let b = NSPasteboardItem()
b.setString("file:///tmp/x.txt", forType: .fileURL)
pb.writeObjects([a, b])
print(name)
let out = FileManager.default.temporaryDirectory.appendingPathComponent("paste-fixture-selftest-" + UUID().uuidString).path
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
p.arguments = ["tool/paste_fixtures/capture_macos.swift", "selftest", "private-pasteboard", "--pasteboard", name, "--out", out]
try p.run()
p.waitUntilExit()
print("capture exit:", p.terminationStatus, "out:", out)
pb.releaseGlobally()
