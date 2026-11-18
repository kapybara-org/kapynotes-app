#include "system_shutdown.h"

#include <glib-unix.h>
#include <signal.h>

struct _SystemShutdown {
  FlMethodChannel* channel;
  GApplication* application;
  GtkWindow* window;
  gboolean requested;
  guint signal_sources[3];
  guint deadline;
  gulong query_end;
  gulong delete_event;
};

static gboolean quit_now(gpointer user_data) {
  SystemShutdown* shutdown = static_cast<SystemShutdown*>(user_data);
  shutdown->deadline = 0;
  g_application_quit(shutdown->application);
  return G_SOURCE_REMOVE;
}

static void request(SystemShutdown* shutdown) {
  if (shutdown->requested) {
    quit_now(shutdown);
    return;
  }
  shutdown->requested = TRUE;
  fl_method_channel_invoke_method(shutdown->channel, "shutdown", nullptr,
                                  nullptr, nullptr, nullptr);
  shutdown->deadline = g_timeout_add_seconds(10, quit_now, shutdown);
}

static gboolean signal_cb(gpointer user_data) {
  request(static_cast<SystemShutdown*>(user_data));
  return G_SOURCE_CONTINUE;
}

static void query_end_cb(GtkApplication* application, gpointer user_data) {
  request(static_cast<SystemShutdown*>(user_data));
}

// A close the app has not taken over. window_manager's handler runs first and
// stops the signal when the app hides to the tray instead, so arriving here
// means the app is to quit, and it does that the way it does for a logout.
// Letting GTK destroy the window would leave the isolate running against a
// window that is gone, and GApplication still dispatches what is queued once
// its last window has closed: the app's next window call then reaches
// window_manager with no window, and the process crashes on its way out.
// Closing again while the app saves just waits for it.
static gboolean delete_event_cb(GtkWidget* window, GdkEvent* event,
                                gpointer user_data) {
  SystemShutdown* shutdown = static_cast<SystemShutdown*>(user_data);
  if (!shutdown->requested) request(shutdown);
  return TRUE;
}

SystemShutdown* system_shutdown_new(FlBinaryMessenger* messenger,
                                    GApplication* application,
                                    GtkWindow* window) {
  SystemShutdown* shutdown = g_new0(SystemShutdown, 1);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  shutdown->channel = fl_method_channel_new(
      messenger, "kapynotes/system_shutdown", FL_METHOD_CODEC(codec));
  shutdown->application = application;
  const int signals[] = {SIGTERM, SIGINT, SIGHUP};
  for (int i = 0; i < 3; i++) {
    shutdown->signal_sources[i] = g_unix_signal_add(signals[i], signal_cb, shutdown);
  }
  shutdown->query_end = g_signal_connect(application, "query-end",
                                         G_CALLBACK(query_end_cb), shutdown);
  shutdown->window = GTK_WINDOW(g_object_ref(window));
  shutdown->delete_event = g_signal_connect(
      window, "delete-event", G_CALLBACK(delete_event_cb), shutdown);
  return shutdown;
}

void system_shutdown_free(SystemShutdown* shutdown) {
  for (guint source : shutdown->signal_sources) {
    if (source != 0) g_source_remove(source);
  }
  if (shutdown->deadline != 0) g_source_remove(shutdown->deadline);
  if (shutdown->query_end != 0) {
    g_signal_handler_disconnect(shutdown->application, shutdown->query_end);
  }
  g_signal_handler_disconnect(shutdown->window, shutdown->delete_event);
  g_clear_object(&shutdown->window);
  g_clear_object(&shutdown->channel);
  g_free(shutdown);
}
