#ifndef RUNNER_SYSTEM_SHUTDOWN_H_
#define RUNNER_SYSTEM_SHUTDOWN_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The runner's end of `kapynotes/system_shutdown`, the channel the Windows
// runner uses for the same purpose.
//
// Sends `shutdown` when the session ends (GtkApplication's query-end at
// logout), the process is asked to stop (SIGTERM, SIGINT, SIGHUP), or
// `window` is closed and the app has not taken the close over to hide it.
// The app saves and asks for `quit`, which is also how it quits on its own.
// The main loop stops when it asks, or ten seconds after a request it has
// not finished. Asking again in the meantime, by signal, logout or close,
// waits for the save rather than cutting it short.
//
// Create it after the plugins are registered: window_manager's delete-event
// handler, which is the one that hides the window, has to run before this
// one.
typedef struct _SystemShutdown SystemShutdown;

SystemShutdown* system_shutdown_new(FlBinaryMessenger* messenger,
                                    GApplication* application,
                                    GtkWindow* window);

void system_shutdown_free(SystemShutdown* shutdown);

#endif  // RUNNER_SYSTEM_SHUTDOWN_H_
