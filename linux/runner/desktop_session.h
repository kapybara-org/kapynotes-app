#ifndef RUNNER_DESKTOP_SESSION_H_
#define RUNNER_DESKTOP_SESSION_H_

#include <flutter_linux/flutter_linux.h>

// Backs the `kapynotes/linux` channel: what the desktop session can do for
// the app, which on Linux depends on the session rather than the OS.
//
//   isWayland    -> bool, whether GTK draws through Wayland
//   hasTrayHost  -> bool, whether a StatusNotifierWatcher with a host is on
//                   the session bus, so that a tray icon will be shown
//   newNote      <- sent to Dart when a launch asks for a new note
//                   (`kapynotes --new-note`, a system shortcut on Wayland)
typedef struct _DesktopSession DesktopSession;

DesktopSession* desktop_session_new(FlBinaryMessenger* messenger);

void desktop_session_request_new_note(DesktopSession* session);

void desktop_session_free(DesktopSession* session);

#endif  // RUNNER_DESKTOP_SESSION_H_
