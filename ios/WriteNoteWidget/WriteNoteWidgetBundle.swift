import SwiftUI
import WidgetKit

/// The extension's entry point, in a file of its own so that
/// tool/ci/ios_widget_renders.sh can build the widgets' views without it.
@main
struct WriteNoteWidgetBundle: WidgetBundle {
  var body: some Widget {
    WriteNoteWidget()
    QuickActionsWidget()
    if #available(iOS 18.0, *) {
      WriteNoteControl()
      DictateControl()
      CaptureControl()
    }
  }
}
