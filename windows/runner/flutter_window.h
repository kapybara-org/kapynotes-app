#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "login_item.h"
#include "rich_clipboard.h"
#include "spell_check.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "Open at login". Held here because a channel that outlives nothing stops
  // answering as soon as OnCreate returns.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      login_item_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      rich_clipboard_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      spell_check_channel_;

  // Carries the one message the runner sends without being asked: Windows —
  // or, far more often, the installer's Restart Manager — wants this process
  // gone. See LeaveForShutdown.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      shutdown_channel_;

  // Whether we have already been told to leave, so the three messages Restart
  // Manager sends in sequence start one quit between them rather than three.
  bool leaving_ = false;

  // Starts the orderly quit and sets the deadline by which this process
  // leaves whether Dart answered or not.
  void LeaveForShutdown();
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
