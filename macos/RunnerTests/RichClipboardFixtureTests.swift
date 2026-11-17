import Cocoa
import FlutterMacOS
import XCTest

@testable import Kapy_Notes

/// Puts every macOS paste fixture on a private pasteboard, exactly as it was
/// recorded, and reads it back the way the `read` method does.
///
/// A fixture whose snapshot carries something the platform derived (rich
/// text as HTML, resources, VS Code's data from Chromium's custom data, file
/// paths, an image) is compared with the `macos-snapshot.json` beside it.
/// With `PASTE_FIXTURES_UPDATE=1` the snapshots are written to this test's
/// temporary directory instead, which
/// `tool/paste_fixtures/update_macos_snapshots.sh` copies back.
class RichClipboardFixtureTests: XCTestCase {
  private static let derivedKeys = ["rtfHtml", "resources", "vscode", "files", "image"]

  func testEveryMacFixtureReadsAsRecorded() throws {
    let root = try XCTUnwrap(
      Bundle(for: Self.self).url(forResource: "paste", withExtension: nil),
      "The fixtures are bundled with the tests"
    )
    let update = ProcessInfo.processInfo.environment["PASTE_FIXTURES_UPDATE"] == "1"
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("paste-fixture-snapshots")
    if update {
      try? FileManager.default.removeItem(at: output)
    }
    let generalChangeCount = NSPasteboard.general.changeCount

    let fixtures = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }
      .filter { $0.lastPathComponent == "fixture.json" } ?? [])
      .sorted { $0.path < $1.path }
    var checked = 0
    for fixtureUrl in fixtures {
      let fixture = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixtureUrl)) as? [String: Any]
      )
      guard fixture["platform"] as? String == "macos" else { continue }
      let directory = fixtureUrl.deletingLastPathComponent()
      let name = String(directory.path.dropFirst(root.path.count + 1))
      let items = try (fixture["items"] as? [[String: Any]] ?? []).map {
        try ($0["representations"] as? [[String: String]] ?? []).map {
          (type: $0["type"]!, data: try Data(contentsOf: directory.appendingPathComponent($0["file"]!)))
        }
      }

      let snapshot = read(items)
      checked += 1

      let snapshotUrl = directory.appendingPathComponent("macos-snapshot.json")
      if Self.derivedKeys.contains(where: { snapshot[$0] != nil }) {
        let json = try JSONSerialization.data(
          withJSONObject: jsonValue(snapshot),
          options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        if update {
          let target = output.appendingPathComponent(name).appendingPathComponent("macos-snapshot.json")
          try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try (json + Data("\n".utf8)).write(to: target)
          continue
        }
        guard let committed = try? Data(contentsOf: snapshotUrl) else {
          XCTFail("\(name): no macos-snapshot.json; run tool/paste_fixtures/update_macos_snapshots.sh")
          continue
        }
        let expected = try JSONSerialization.jsonObject(with: committed) as? NSDictionary
        let actual = try JSONSerialization.jsonObject(with: json) as? NSDictionary
        XCTAssertEqual(actual, expected, "\(name): the snapshot differs from macos-snapshot.json")
      } else {
        XCTAssertFalse(
          FileManager.default.fileExists(atPath: snapshotUrl.path),
          "\(name): macos-snapshot.json is left over"
        )
        func recorded(_ type: String) -> String? {
          items.lazy.compactMap { $0.first { $0.type == type } }.first
            .map { String(decoding: $0.data, as: UTF8.self) }
        }
        XCTAssertEqual(snapshot["text"] as? String, recorded("public.utf8-plain-text"), "\(name): text")
        XCTAssertEqual(snapshot["html"] as? String, recorded("public.html"), "\(name): html")
        XCTAssertEqual(snapshot["sourceUrl"] as? String, recorded("org.chromium.source-url"), "\(name): sourceUrl")
      }
    }

    XCTAssertGreaterThan(checked, 0)
    XCTAssertEqual(NSPasteboard.general.changeCount, generalChangeCount)
    if update {
      print("Wrote macOS paste snapshots to \(output.path)")
    }
  }

  /// `items` on a private pasteboard, one pasteboard item per recorded item,
  /// read the way the channel's `read` method reads.
  private func read(_ items: [[(type: String, data: Data)]]) -> [String: Any] {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.writeObjects(items.map { representations in
      let item = NSPasteboardItem()
      for representation in representations {
        item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
      }
      return item
    })
    return RichClipboard.read(from: pasteboard)
  }

  /// The channel's value as JSON, with bytes as `{"base64": …}`.
  private func jsonValue(_ value: Any) -> Any {
    switch value {
    case let typed as FlutterStandardTypedData:
      return ["base64": typed.data.base64EncodedString()]
    case let map as [String: Any]:
      return map.mapValues(jsonValue)
    case let list as [Any]:
      return list.map(jsonValue)
    default:
      return value
    }
  }
}
