#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Restart Manager gives an application that answers its shutdown messages 30
// seconds before it terminates it, so this deadline is only ever reached by a
// Dart side that is wedged. Leaving under our own power is worth waiting for:
// a terminated process leaves its tray icon on screen until the next
// mouse-over sweeps it up, and whatever it had not written yet is gone.
constexpr UINT_PTR kLeaveTimerId = 1;
constexpr UINT kLeaveDeadlineMs = 10000;

// One message, one direction. The Dart end is lib/core/system_shutdown.dart.
constexpr char kShutdownChannel[] = "kapynotes/system_shutdown";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  login_item_channel_ =
      RegisterLoginItemChannel(flutter_controller_->engine()->messenger());
  rich_clipboard_channel_ = RegisterRichClipboardChannel(
      flutter_controller_->engine()->messenger(), GetHandle());
  spell_check_channel_ =
      RegisterSpellCheckChannel(flutter_controller_->engine()->messenger());
  shutdown_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kShutdownChannel,
          &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Before the engine it borrows its messenger from.
  login_item_channel_ = nullptr;
  rich_clipboard_channel_ = nullptr;
  spell_check_channel_ = nullptr;
  shutdown_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

// Begins leaving, from whichever of Restart Manager's messages arrives first.
//
// The quit itself belongs to Dart: it is the one that knows there are notes to
// write, a recording to stop and a tray icon to take down, and it ends by
// destroying this window. All this does is start it and refuse to wait
// forever.
void FlutterWindow::LeaveForShutdown() {
  if (leaving_) {
    return;
  }
  leaving_ = true;

  // No engine to ask means nothing to flush and nobody to wait for.
  if (!shutdown_channel_) {
    Destroy();
    return;
  }

  ::SetTimer(GetHandle(), kLeaveTimerId, kLeaveDeadlineMs, nullptr);
  shutdown_channel_->InvokeMethod("shutdown", nullptr);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Answered before Flutter and its plugins are offered the message, because
  // one of those plugins is the reason this exists: with "keep running in the
  // background" on, window_manager answers a close with -1 and the app hides
  // to the tray instead of ending. An installer that asks the window to close
  // and gets a hide is left overwriting files this process still holds open,
  // which is the update that fails.
  switch (message) {
    case WM_QUERYENDSESSION:
      // How the installer's Restart Manager asks, and how a logoff or a
      // restart asks too. Yes — a refusal cancels the shutdown, and an
      // installer told no has nothing left to try.
      //
      // Only yes, though. Windows asks every application before it tells any
      // of them to go, and one of the others answering no calls the whole
      // thing off; quitting here would leave the app gone from a shutdown
      // that never happened.
      return TRUE;

    case WM_ENDSESSION:
      // And this is the one that means it. wparam is false for the shutdown
      // that was called off, which is nothing to do.
      if (wparam) {
        LeaveForShutdown();
        return 0;
      }
      break;

    case WM_CLOSE:
      // Restart Manager's last resort for an application still running after
      // WM_ENDSESSION. It is answered here rather than passed on, because
      // passing it on is what went wrong: window_manager turns it into a hide
      // and the process stays. Nothing else to do — the quit is already
      // running, and it ends by destroying this window itself. Cutting it
      // short here would be taking the notes off it mid-write.
      if (leaving_) {
        return 0;
      }
      break;

    case WM_TIMER:
      if (wparam == kLeaveTimerId) {
        ::KillTimer(hwnd, kLeaveTimerId);
        Destroy();
        return 0;
      }
      break;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
