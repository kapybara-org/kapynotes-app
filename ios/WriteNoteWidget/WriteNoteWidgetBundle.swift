import SwiftUI
import WidgetKit

/// The extension's entry point, in a file of its own so that
/// tool/ci/ios_widget_renders.sh can build the widgets' views without it.
///
/// It ships from iOS 16.1 for the recording's Live Activity alone: the widgets
/// need iOS 17.
@main
struct WriteNoteWidgetBundle: WidgetBundle {
  var body: some Widget {
    if #available(iOS 17.0, *) {
      WriteNoteWidget()
      QuickActionsWidget()
    }
    RecordingLiveActivity()
    if #available(iOS 18.0, *) {
      WriteNoteControl()
      DictateControl()
      CaptureControl()
    }
  }
}
