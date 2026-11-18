#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "desktop_session.h"
#include "flutter/generated_plugin_registrant.h"
#include "rich_clipboard.h"
#include "system_region.h"
#include "system_shutdown.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlView* view;
  // gtk/application is package:gtk's channel, which app_links reads deep
  // links from. See command_line_cb for why this side writes to it.
  FlMethodChannel* links_channel;
  DesktopSession* session;
  RichClipboard* clipboard;
  SystemRegion* region;
  SystemShutdown* shutdown;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// The icon an X11 window manager and the Alt+Tab switcher draw. An installed
// package puts it in the icon theme, where the name finds it; the tarball and
// an AppImage nobody has integrated only have the copy inside the bundle.
static void set_default_icon() {
  if (gtk_icon_theme_has_icon(gtk_icon_theme_get_default(), APPLICATION_ID)) {
    gtk_window_set_default_icon_name(APPLICATION_ID);
    return;
  }
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable == nullptr) return;
  g_autofree gchar* directory = g_path_get_dirname(executable);
  g_autofree gchar* icon =
      g_build_filename(directory, "share", "icons", "hicolor", "256x256",
                       "apps", APPLICATION_ID ".png", nullptr);
  gtk_window_set_default_icon_from_file(icon, nullptr);
}

// Implements GApplication::activate.
//
// A second launch of an app that is already running arrives here or in
// command_line_cb, and either way it raises the window it already has rather
// than opening another.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    gtk_window_present(self->window);
    return;
  }

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Kapy Notes");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Kapy Notes");
  }

  gtk_window_set_default_size(window, 1280, 720);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  self->view = view;
  // The light paper, for the moment between the window appearing and Flutter
  // drawing into it.
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#F6F2E8");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->links_channel = fl_method_channel_new(messenger, "gtk/application",
                                              FL_METHOD_CODEC(codec));
  self->session = desktop_session_new(messenger);
  self->clipboard = rich_clipboard_new(messenger);
  self->region = system_region_new(messenger);
  self->shutdown = system_shutdown_new(messenger, application);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

static gboolean is_link(const gchar* argument) {
  return argument != nullptr && argument[0] != '-' &&
         g_uri_peek_scheme(argument) != nullptr;
}

// Every launch's command line, this process's own and every later one's.
//
// Connected before the plugins are registered, so it is the handler that
// answers: the signal takes the first handler's answer and calls no other.
// package:gtk connects one of its own, to hand app_links the links a second
// launch carries; this does that job instead, for the first launch too, which
// package:gtk would miss because its handler only exists once the window
// does.
static gint command_line_cb(GApplication* application,
                            GApplicationCommandLine* command_line,
                            MyApplication* self) {
  g_auto(GStrv) arguments =
      g_application_command_line_get_arguments(command_line, nullptr);
  gchar** given = arguments[0] == nullptr ? arguments : arguments + 1;

  if (self->window == nullptr) {
    self->dart_entrypoint_arguments = g_strdupv(given);
    g_application_activate(application);
  } else {
    gtk_window_present(self->window);
  }

  for (gchar** argument = given; *argument != nullptr; argument++) {
    if (g_strcmp0(*argument, "--new-note") == 0) {
      desktop_session_request_new_note(self->session);
    } else if (is_link(*argument)) {
      g_autoptr(FlValue) link = fl_value_new_list();
      fl_value_append_take(link, fl_value_new_string(*argument));
      fl_method_channel_invoke_method(self->links_channel, "command-line",
                                      link, nullptr, nullptr, nullptr);
    }
  }
  return 0;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  g_signal_connect(application, "command-line", G_CALLBACK(command_line_cb),
                   self);
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  // The X11 WM_CLASS class, which is what the desktop entry's StartupWMClass
  // names, so a dock groups the window under the app's own icon. GTK's own
  // startup above sets it to the program name with a capital first letter,
  // overwriting any earlier call, and the window takes it when it is created
  // after this.
  gdk_set_program_class(APPLICATION_ID);
  set_default_icon();
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->links_channel);
  g_clear_pointer(&self->session, desktop_session_free);
  g_clear_pointer(&self->clipboard, rich_clipboard_free);
  g_clear_pointer(&self->region, system_region_free);
  g_clear_pointer(&self->shutdown, system_shutdown_free);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // Unique, rather than the template's G_APPLICATION_NON_UNIQUE: a second
  // launch, a deep link or a system shortcut running the binary hands its
  // command line to the copy already running and exits. With no session bus
  // GLib falls back to running as a non-unique app.
  return MY_APPLICATION(g_object_new(
      my_application_get_type(), "application-id", APPLICATION_ID, "flags",
      G_APPLICATION_HANDLES_COMMAND_LINE, "register-session", TRUE, nullptr));
}
