#include "desktop_session.h"

#include <gio/gio.h>
#include <gtk/gtk.h>
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif

struct _DesktopSession {
  FlMethodChannel* channel;
};

static gboolean is_wayland() {
#ifdef GDK_WINDOWING_WAYLAND
  return GDK_IS_WAYLAND_DISPLAY(gdk_display_get_default());
#else
  return FALSE;
#endif
}

static void respond(FlMethodCall* method_call, gboolean answer) {
  g_autoptr(FlValue) result = fl_value_new_bool(answer);
  fl_method_call_respond_success(method_call, result, nullptr);
}

// Whether something on the session bus will draw a tray icon.
//
// AppIndicator icons are StatusNotifierItems: they appear only where a
// StatusNotifierWatcher runs with a host registered against it. KDE, Xfce,
// Cinnamon, MATE and Ubuntu's GNOME (its AppIndicator extension) have one;
// stock GNOME does not, and there an icon is accepted and never shown.
static void host_cb(GObject* source, GAsyncResult* result, gpointer user_data) {
  g_autoptr(FlMethodCall) method_call = FL_METHOD_CALL(user_data);
  g_autoptr(GVariant) reply = g_dbus_connection_call_finish(
      G_DBUS_CONNECTION(source), result, nullptr);
  gboolean registered = FALSE;
  if (reply != nullptr) {
    g_autoptr(GVariant) value = nullptr;
    g_variant_get(reply, "(v)", &value);
    registered = g_variant_is_of_type(value, G_VARIANT_TYPE_BOOLEAN) &&
                 g_variant_get_boolean(value);
  }
  respond(method_call, registered);
}

static void has_tray_host(FlMethodCall* method_call) {
  g_autoptr(GDBusConnection) bus =
      g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
  if (bus == nullptr) {
    respond(method_call, FALSE);
    return;
  }
  // No auto-start: asking must not be what launches a watcher.
  g_dbus_connection_call(
      bus, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
      "org.freedesktop.DBus.Properties", "Get",
      g_variant_new("(ss)", "org.kde.StatusNotifierWatcher",
                    "IsStatusNotifierHostRegistered"),
      G_VARIANT_TYPE("(v)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, nullptr,
      host_cb, g_object_ref(method_call));
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "isWayland") == 0) {
    respond(method_call, is_wayland());
    return;
  }
  if (g_strcmp0(method, "hasTrayHost") == 0) {
    has_tray_host(method_call);
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

DesktopSession* desktop_session_new(FlBinaryMessenger* messenger) {
  DesktopSession* session = g_new0(DesktopSession, 1);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  session->channel =
      fl_method_channel_new(messenger, "kapynotes/linux", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(session->channel, method_call_cb,
                                            nullptr, nullptr);
  return session;
}

void desktop_session_request_new_note(DesktopSession* session) {
  if (session == nullptr) return;
  fl_method_channel_invoke_method(session->channel, "newNote", nullptr,
                                  nullptr, nullptr, nullptr);
}

void desktop_session_free(DesktopSession* session) {
  g_clear_object(&session->channel);
  g_free(session);
}
