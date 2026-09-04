#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "win32_window.h"

namespace {

// Per-user, because the installer is: two people signed in at once each get
// their own notes file and so may each run their own copy.
constexpr wchar_t kInstanceMutexName[] = L"Local\\KapyNotes.SingleInstance";

// Wakes the copy that is already running and reports whether there was one.
//
// One process owns the notes file. That was always true, but a window that
// closes to the tray makes a second launch easy to reach and hard to notice —
// the app looks shut, so the desktop icon gets another click — and two copies
// writing the same JSON means whichever exits last wins.
bool HandOverToRunningInstance() {
  // Held for the life of the process and released by Windows at exit, which
  // is why it is never closed on the paths that go on to run the app.
  HANDLE lock = ::CreateMutexW(nullptr, TRUE, kInstanceMutexName);
  if (lock == nullptr || ::GetLastError() != ERROR_ALREADY_EXISTS) {
    return false;
  }

  HWND running = ::FindWindowW(Win32Window::WindowClassName(), nullptr);
  if (running == nullptr) {
    // Taken, but with no window to hand over to: the previous copy is on its
    // way out — the installer closes it before putting it back — or still on
    // its way in. Waiting for it to let go beats exiting, which would leave
    // an update finishing with no app on screen at all. An owner that dies
    // holding the mutex hands it over abandoned; that counts.
    const DWORD wait = ::WaitForSingleObject(lock, 3000);
    if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
      return false;
    }
    ::CloseHandle(lock);
    return true;
  }

  ::CloseHandle(lock);
  // It may be in the notification area rather than merely behind something,
  // which is the whole reason the user reached for the icon again.
  ::ShowWindow(running, ::IsIconic(running) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(running);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (HandOverToRunningInstance()) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(600, 630);
  if (!window.Create(L"Kapy Notes", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
