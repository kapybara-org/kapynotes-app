#include "system_shutdown.h"

#include <glib-unix.h>
#include <signal.h>

struct _SystemShutdown {
  FlMethodChannel* channel;
  GApplication* application;
  gboolean requested;
  guint signal_sources[3];
  guint deadline;
  gulong query_end;
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

SystemShutdown* system_shutdown_new(FlBinaryMessenger* messenger,
                                    GApplication* application) {
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
  g_clear_object(&shutdown->channel);
  g_free(shutdown);
}
