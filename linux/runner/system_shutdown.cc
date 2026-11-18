#include "system_shutdown.h"

#include <glib-unix.h>
#include <signal.h>

struct _SystemShutdown {
  FlMethodChannel* channel;
  GApplication* application;
  GtkWindow* window;
  GCancellable* cancellable;
  gboolean requested;
  guint signal_sources[3];
  guint deadline;
  gulong query_end;
  gulong delete_event;
};

// Every way out ends here. The main loop stops with the window still up:
// destroying it would leave the isolate running against a window that is
// gone while GApplication still dispatches what is queued for it, and the
// first of those calls crashes the process on its way out. The windows let go
// of the application first, as they do in the engine's own exit, so it is
// finalized once g_application_run returns.
static void quit(SystemShutdown* shutdown) {
  g_clear_handle_id(&shutdown->deadline, g_source_remove);
  g_autoptr(GList) windows = g_list_copy(
      gtk_application_get_windows(GTK_APPLICATION(shutdown->application)));
  for (GList* link = windows; link != nullptr; link = link->next) {
    gtk_window_set_application(GTK_WINDOW(link->data), nullptr);
  }
  g_application_quit(shutdown->application);
}

static gboolean deadline_cb(gpointer user_data) {
  SystemShutdown* shutdown = static_cast<SystemShutdown*>(user_data);
  shutdown->deadline = 0;
  quit(shutdown);
  return G_SOURCE_REMOVE;
}

// The app answers once it has saved and asked for `quit`. Any other answer,
// such as the empty one that comes back when nothing on the Dart side is
// listening yet, leaves nothing to wait for.
static void shutdown_answered_cb(GObject* object, GAsyncResult* result,
                                 gpointer user_data) {
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(object), result, &error);
  if (response == nullptr &&
      g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
    return;
  }
  quit(static_cast<SystemShutdown*>(user_data));
}

static void request(SystemShutdown* shutdown) {
  if (shutdown->requested) {
    quit(shutdown);
    return;
  }
  shutdown->requested = TRUE;
  fl_method_channel_invoke_method(shutdown->channel, "shutdown", nullptr,
                                  shutdown->cancellable, shutdown_answered_cb,
                                  shutdown);
  shutdown->deadline = g_timeout_add_seconds(10, deadline_cb, shutdown);
}

// The app quitting, once it has saved: from the tray, the keyboard or an
// update, or because it was asked to.
static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  if (g_strcmp0(fl_method_call_get_name(method_call), "quit") != 0) {
    fl_method_call_respond_not_implemented(method_call, nullptr);
    return;
  }
  fl_method_call_respond_success(method_call, nullptr, nullptr);
  quit(static_cast<SystemShutdown*>(user_data));
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
  fl_method_channel_set_method_call_handler(shutdown->channel, method_call_cb,
                                            shutdown, nullptr);
  shutdown->application = application;
  shutdown->cancellable = g_cancellable_new();
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
  g_cancellable_cancel(shutdown->cancellable);
  g_clear_object(&shutdown->cancellable);
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
