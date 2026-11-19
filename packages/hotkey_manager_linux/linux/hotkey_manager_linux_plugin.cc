#include "include/hotkey_manager_linux/hotkey_manager_linux_plugin.h"

#include <cstring>
#include <map>
#include <string>

#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <gdk/gdkx.h>

#define HOTKEY_MANAGER_LINUX_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), hotkey_manager_linux_plugin_get_type(), \
                              HotkeyManagerLinuxPlugin))

namespace {

constexpr guint kModifierMask = ShiftMask | ControlMask | Mod1Mask | Mod2Mask |
                                Mod3Mask | Mod4Mask | Mod5Mask;

struct Binding {
  KeySym keysym;
  KeyCode keycode;
  guint modifiers;
  bool down;
};

}  // namespace

struct _HotkeyManagerLinuxPlugin {
  GObject parent_instance;
  FlEventChannel* events;
  std::map<std::string, Binding>* bindings;
  guint num_lock;
  guint scroll_lock;
};

G_DEFINE_TYPE(HotkeyManagerLinuxPlugin,
              hotkey_manager_linux_plugin,
              g_object_get_type())

static FlMethodResponse* success() {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

static FlMethodResponse* failure(const gchar* code, const gchar* message) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message, nullptr));
}

static void read_lock_modifiers(HotkeyManagerLinuxPlugin* self,
                                Display* xdisplay) {
  self->num_lock = XkbKeysymToModifiers(xdisplay, XK_Num_Lock);
  self->scroll_lock = XkbKeysymToModifiers(xdisplay, XK_Scroll_Lock);
}

// Caps Lock, Num Lock and Scroll Lock change nothing about a shortcut, so a
// binding is grabbed under every combination of them. The grab fails as a
// whole when another client holds any one of those combinations.
static bool set_grab(HotkeyManagerLinuxPlugin* self,
                     const Binding& binding,
                     bool grab) {
  GdkDisplay* display = gdk_display_get_default();
  Display* xdisplay = GDK_DISPLAY_XDISPLAY(display);
  Window root = DefaultRootWindow(xdisplay);
  gdk_x11_display_error_trap_push(display);
  for (guint i = 0; i < 8; i++) {
    const guint modifiers = binding.modifiers | (i & 1 ? LockMask : 0) |
                            (i & 2 ? self->num_lock : 0) |
                            (i & 4 ? self->scroll_lock : 0);
    if (grab) {
      XGrabKey(xdisplay, binding.keycode, modifiers, root, False,
               GrabModeAsync, GrabModeAsync);
    } else {
      XUngrabKey(xdisplay, binding.keycode, modifiers, root);
    }
  }
  return gdk_x11_display_error_trap_pop(display) == 0;
}

static void send_key_down(HotkeyManagerLinuxPlugin* self,
                          const std::string& identifier) {
  g_autoptr(FlValue) data = fl_value_new_map();
  fl_value_set_string_take(data, "identifier",
                           fl_value_new_string(identifier.c_str()));
  g_autoptr(FlValue) event = fl_value_new_map();
  fl_value_set_string_take(event, "type", fl_value_new_string("onKeyDown"));
  fl_value_set_string(event, "data", data);
  fl_event_channel_send(self->events, event, nullptr, nullptr);
}

// A held key repeats as further presses with no release between them, and a
// summon that toggles the window must not flicker through each of them.
static GdkFilterReturn filter_key(GdkXEvent* gdk_xevent,
                                  GdkEvent* event,
                                  gpointer user_data) {
  HotkeyManagerLinuxPlugin* self = HOTKEY_MANAGER_LINUX_PLUGIN(user_data);
  XEvent* xevent = static_cast<XEvent*>(gdk_xevent);
  if (xevent->type != KeyPress && xevent->type != KeyRelease) {
    return GDK_FILTER_CONTINUE;
  }
  const guint modifiers =
      xevent->xkey.state & kModifierMask &
      ~(LockMask | self->num_lock | self->scroll_lock);
  GdkFilterReturn result = GDK_FILTER_CONTINUE;
  for (auto& entry : *self->bindings) {
    Binding& binding = entry.second;
    if (binding.keycode != xevent->xkey.keycode) continue;
    result = GDK_FILTER_REMOVE;
    if (xevent->type == KeyRelease) {
      binding.down = false;
    } else if (binding.modifiers == modifiers && !binding.down) {
      binding.down = true;
      send_key_down(self, entry.first);
    }
  }
  return result;
}

static void keys_changed_cb(GdkKeymap* keymap, gpointer user_data) {
  HotkeyManagerLinuxPlugin* self = HOTKEY_MANAGER_LINUX_PLUGIN(user_data);
  Display* xdisplay = GDK_DISPLAY_XDISPLAY(gdk_display_get_default());
  for (auto& entry : *self->bindings) set_grab(self, entry.second, false);
  read_lock_modifiers(self, xdisplay);
  for (auto& entry : *self->bindings) {
    Binding& binding = entry.second;
    binding.keycode = XKeysymToKeycode(xdisplay, binding.keysym);
    binding.down = false;
    if (binding.keycode != 0) set_grab(self, binding, true);
  }
}

static void release(HotkeyManagerLinuxPlugin* self, FlValue* args) {
  FlValue* identifier = fl_value_lookup_string(args, "identifier");
  if (identifier == nullptr ||
      fl_value_get_type(identifier) != FL_VALUE_TYPE_STRING) {
    return;
  }
  auto found = self->bindings->find(fl_value_get_string(identifier));
  if (found == self->bindings->end()) return;
  set_grab(self, found->second, false);
  self->bindings->erase(found);
}

static void release_all(HotkeyManagerLinuxPlugin* self) {
  for (auto& entry : *self->bindings) set_grab(self, entry.second, false);
  self->bindings->clear();
}

static FlMethodResponse* grab_hotkey(HotkeyManagerLinuxPlugin* self,
                                     FlValue* args) {
  GdkDisplay* display = gdk_display_get_default();
  if (!GDK_IS_X11_DISPLAY(display)) {
    return failure("unsupported", "System-wide shortcuts need an X11 session.");
  }
  FlValue* identifier = fl_value_lookup_string(args, "identifier");
  FlValue* key = fl_value_lookup_string(args, "keyCode");
  FlValue* names = fl_value_lookup_string(args, "modifiers");
  if (identifier == nullptr ||
      fl_value_get_type(identifier) != FL_VALUE_TYPE_STRING ||
      key == nullptr || fl_value_get_type(key) != FL_VALUE_TYPE_INT ||
      names == nullptr || fl_value_get_type(names) != FL_VALUE_TYPE_LIST) {
    return failure("bad_args", "A hotkey needs an identifier, a key and modifiers.");
  }

  GdkModifierType super = GDK_SUPER_MASK;
  gdk_keymap_map_virtual_modifiers(gdk_keymap_get_for_display(display), &super);
  Binding binding = {};
  for (size_t i = 0; i < fl_value_get_length(names); i++) {
    const gchar* name = fl_value_get_string(fl_value_get_list_value(names, i));
    if (strcmp(name, "alt") == 0) {
      binding.modifiers |= Mod1Mask;
    } else if (strcmp(name, "control") == 0) {
      binding.modifiers |= ControlMask;
    } else if (strcmp(name, "shift") == 0) {
      binding.modifiers |= ShiftMask;
    } else if (strcmp(name, "meta") == 0) {
      if ((super & kModifierMask) == 0) {
        return failure("no_super", "This keyboard has no Super key.");
      }
      binding.modifiers |= super & kModifierMask;
    }
  }

  Display* xdisplay = GDK_DISPLAY_XDISPLAY(display);
  binding.keysym = gdk_keyval_to_lower(fl_value_get_int(key));
  binding.keycode = XKeysymToKeycode(xdisplay, binding.keysym);
  if (binding.keycode == 0) {
    return failure("no_key", "No key on this keyboard types that.");
  }

  release(self, args);
  if (!set_grab(self, binding, true)) {
    set_grab(self, binding, false);
    return failure("taken", "Another app already uses this shortcut.");
  }
  (*self->bindings)[fl_value_get_string(identifier)] = binding;
  return success();
}

static void method_call_cb(FlMethodChannel* channel,
                           FlMethodCall* method_call,
                           gpointer user_data) {
  HotkeyManagerLinuxPlugin* self = HOTKEY_MANAGER_LINUX_PLUGIN(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "register") == 0) {
    response = grab_hotkey(self, args);
  } else if (strcmp(method, "unregister") == 0) {
    release(self, args);
    response = success();
  } else if (strcmp(method, "unregisterAll") == 0) {
    release_all(self);
    response = success();
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

static void hotkey_manager_linux_plugin_dispose(GObject* object) {
  HotkeyManagerLinuxPlugin* self = HOTKEY_MANAGER_LINUX_PLUGIN(object);
  GdkDisplay* display = gdk_display_get_default();
  if (display != nullptr && GDK_IS_X11_DISPLAY(display)) {
    gdk_window_remove_filter(gdk_get_default_root_window(), filter_key, self);
    g_signal_handlers_disconnect_by_data(gdk_keymap_get_for_display(display),
                                         self);
  }
  g_clear_object(&self->events);
  G_OBJECT_CLASS(hotkey_manager_linux_plugin_parent_class)->dispose(object);
}

static void hotkey_manager_linux_plugin_finalize(GObject* object) {
  delete HOTKEY_MANAGER_LINUX_PLUGIN(object)->bindings;
  G_OBJECT_CLASS(hotkey_manager_linux_plugin_parent_class)->finalize(object);
}

static void hotkey_manager_linux_plugin_class_init(
    HotkeyManagerLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = hotkey_manager_linux_plugin_dispose;
  G_OBJECT_CLASS(klass)->finalize = hotkey_manager_linux_plugin_finalize;
}

static void hotkey_manager_linux_plugin_init(HotkeyManagerLinuxPlugin* self) {
  self->bindings = new std::map<std::string, Binding>();
}

void hotkey_manager_linux_plugin_register_with_registrar(
    FlPluginRegistrar* registrar) {
  HotkeyManagerLinuxPlugin* plugin = HOTKEY_MANAGER_LINUX_PLUGIN(
      g_object_new(hotkey_manager_linux_plugin_get_type(), nullptr));
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(messenger, "dev.leanflutter.plugins/hotkey_manager",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);
  plugin->events = fl_event_channel_new(
      messenger, "dev.leanflutter.plugins/hotkey_manager_event",
      FL_METHOD_CODEC(codec));

  GdkDisplay* display = gdk_display_get_default();
  if (GDK_IS_X11_DISPLAY(display)) {
    read_lock_modifiers(plugin, GDK_DISPLAY_XDISPLAY(display));
    gdk_window_add_filter(gdk_get_default_root_window(), filter_key, plugin);
    g_signal_connect(gdk_keymap_get_for_display(display), "keys-changed",
                     G_CALLBACK(keys_changed_cb), plugin);
  }

  g_object_unref(plugin);
}
