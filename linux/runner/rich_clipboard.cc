#include "rich_clipboard.h"

#include <gtk/gtk.h>

#include <cstring>

namespace {

// Kapy Notes' own fragment. Only another Kapy Notes on this desktop reads it.
constexpr char kKapyTarget[] = "application/x-kapynotes-fragment";
constexpr char kHtmlTarget[] = "text/html";
constexpr char kVsCodeTarget[] = "vscode-editor-data";

enum Target : guint {
  kText = 1,
  kHtml,
  kKapy,
  kImage,
};

struct Payload {
  gchar* text;
  GBytes* html;
  GBytes* kapy;
  GBytes* image;
  GdkAtom image_target;
};

void payload_free(Payload* payload) {
  g_free(payload->text);
  g_clear_pointer(&payload->html, g_bytes_unref);
  g_clear_pointer(&payload->kapy, g_bytes_unref);
  g_clear_pointer(&payload->image, g_bytes_unref);
  g_free(payload);
}

void set_bytes(GtkSelectionData* selection, GBytes* bytes) {
  gsize length = 0;
  const guchar* data =
      static_cast<const guchar*>(g_bytes_get_data(bytes, &length));
  gtk_selection_data_set(selection, gtk_selection_data_get_target(selection),
                         8, data, static_cast<gint>(length));
}

void get_cb(GtkClipboard* clipboard, GtkSelectionData* selection, guint info,
            gpointer user_data) {
  Payload* payload = static_cast<Payload*>(user_data);
  switch (info) {
    case kText:
      gtk_selection_data_set_text(selection, payload->text, -1);
      break;
    case kHtml:
      set_bytes(selection, payload->html);
      break;
    case kKapy:
      set_bytes(selection, payload->kapy);
      break;
    case kImage:
      set_bytes(selection, payload->image);
      break;
  }
}

void clear_cb(GtkClipboard* clipboard, gpointer user_data) {
  payload_free(static_cast<Payload*>(user_data));
}

const gchar* string_argument(FlValue* args, const char* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  const gchar* string = fl_value_get_string(value);
  return string[0] == '\0' ? nullptr : string;
}

GBytes* bytes_argument(FlValue* args, const char* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr ||
      fl_value_get_type(value) != FL_VALUE_TYPE_UINT8_LIST ||
      fl_value_get_length(value) == 0) {
    return nullptr;
  }
  return g_bytes_new(fl_value_get_uint8_list(value),
                     fl_value_get_length(value));
}

GBytes* string_bytes(const gchar* string) {
  return string == nullptr ? nullptr : g_bytes_new(string, strlen(string));
}

FlMethodResponse* write_clipboard(FlValue* args) {
  if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "bad-arguments", "Expected a map", nullptr));
  }
  Payload* payload = g_new0(Payload, 1);
  payload->text = g_strdup(string_argument(args, "text"));
  payload->html = string_bytes(string_argument(args, "html"));
  payload->kapy = string_bytes(string_argument(args, "kapy"));
  payload->image = bytes_argument(args, "image");
  const gchar* mime = string_argument(args, "imageMime");
  payload->image_target = gdk_atom_intern(mime == nullptr ? "image/png" : mime,
                                          FALSE);

  g_autoptr(GtkTargetList) targets = gtk_target_list_new(nullptr, 0);
  if (payload->text != nullptr) gtk_target_list_add_text_targets(targets, kText);
  if (payload->html != nullptr) {
    gtk_target_list_add(targets, gdk_atom_intern_static_string(kHtmlTarget), 0,
                        kHtml);
  }
  if (payload->kapy != nullptr) {
    gtk_target_list_add(targets, gdk_atom_intern_static_string(kKapyTarget), 0,
                        kKapy);
  }
  if (payload->image != nullptr) {
    gtk_target_list_add(targets, payload->image_target, 0, kImage);
  }

  gint count = 0;
  GtkTargetEntry* table = gtk_target_table_new_from_list(targets, &count);
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  gboolean owned = count > 0 && gtk_clipboard_set_with_data(
                                    clipboard, table, count, get_cb, clear_cb,
                                    payload);
  gtk_target_table_free(table, count);
  if (!owned) {
    payload_free(payload);
    if (count == 0) {
      gtk_clipboard_clear(clipboard);
      return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "unavailable", "The clipboard could not be written", nullptr));
  }
  // So a clipboard manager can keep the copy once the app has quit.
  gtk_clipboard_set_can_store(clipboard, nullptr, 0);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

// Firefox writes text/html as UTF-16 with a byte-order mark; everything else
// writes UTF-8.
gchar* selection_text(GtkSelectionData* data) {
  gint length = 0;
  const guchar* bytes = gtk_selection_data_get_data_with_length(data, &length);
  if (bytes == nullptr || length <= 0) return nullptr;
  if (length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return g_convert(reinterpret_cast<const gchar*>(bytes) + 2, length - 2,
                     "UTF-8", "UTF-16LE", nullptr, nullptr, nullptr);
  }
  if (length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return g_convert(reinterpret_cast<const gchar*>(bytes) + 2, length - 2,
                     "UTF-8", "UTF-16BE", nullptr, nullptr, nullptr);
  }
  return g_utf8_make_valid(reinterpret_cast<const gchar*>(bytes), length);
}

gboolean offers(GdkAtom* targets, gint count, const char* name) {
  GdkAtom wanted = gdk_atom_intern(name, FALSE);
  for (gint i = 0; i < count; i++) {
    if (targets[i] == wanted) return TRUE;
  }
  return FALSE;
}

void read_string(GtkClipboard* clipboard, FlValue* result, const char* target,
                 const char* key) {
  GtkSelectionData* data =
      gtk_clipboard_wait_for_contents(clipboard, gdk_atom_intern(target, FALSE));
  if (data == nullptr) return;
  g_autofree gchar* text = selection_text(data);
  gtk_selection_data_free(data);
  if (text != nullptr && text[0] != '\0') {
    fl_value_set_string_take(result, key, fl_value_new_string(text));
  }
}

void read_image(GtkClipboard* clipboard, FlValue* result, GdkAtom* targets,
                gint count) {
  if (offers(targets, count, "image/png")) {
    GtkSelectionData* data = gtk_clipboard_wait_for_contents(
        clipboard, gdk_atom_intern_static_string("image/png"));
    if (data != nullptr) {
      gint length = 0;
      const guchar* bytes =
          gtk_selection_data_get_data_with_length(data, &length);
      if (bytes != nullptr && length > 0) {
        fl_value_set_string_take(result, "image",
                                 fl_value_new_uint8_list(bytes, length));
        fl_value_set_string_take(result, "imageMime",
                                 fl_value_new_string("image/png"));
      }
      gtk_selection_data_free(data);
      return;
    }
  }
  if (!gtk_targets_include_image(targets, count, FALSE)) return;
  g_autoptr(GdkPixbuf) pixbuf = gtk_clipboard_wait_for_image(clipboard);
  if (pixbuf == nullptr) return;
  gchar* buffer = nullptr;
  gsize length = 0;
  if (!gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &length, "png", nullptr,
                                 nullptr)) {
    return;
  }
  fl_value_set_string_take(
      result, "image",
      fl_value_new_uint8_list(reinterpret_cast<const uint8_t*>(buffer),
                              length));
  fl_value_set_string_take(result, "imageMime",
                           fl_value_new_string("image/png"));
  g_free(buffer);
}

void read_files(GtkClipboard* clipboard, FlValue* result) {
  g_auto(GStrv) uris = gtk_clipboard_wait_for_uris(clipboard);
  if (uris == nullptr) return;
  FlValue* files = fl_value_new_list();
  for (gchar** uri = uris; *uri != nullptr; uri++) {
    g_autofree gchar* path = g_filename_from_uri(*uri, nullptr, nullptr);
    if (path != nullptr) fl_value_append_take(files, fl_value_new_string(path));
  }
  fl_value_set_string_take(result, "files", files);
}

FlMethodResponse* read_clipboard() {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  g_autoptr(FlValue) result = fl_value_new_map();
  GdkAtom* targets = nullptr;
  gint count = 0;
  if (!gtk_clipboard_wait_for_targets(clipboard, &targets, &count)) {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  }

  FlValue* types = fl_value_new_list();
  for (gint i = 0; i < count; i++) {
    g_autofree gchar* name = gdk_atom_name(targets[i]);
    fl_value_append_take(types, fl_value_new_string(name));
  }
  fl_value_set_string_take(result, "types", types);

  if (gtk_targets_include_text(targets, count)) {
    g_autofree gchar* text = gtk_clipboard_wait_for_text(clipboard);
    if (text != nullptr && text[0] != '\0') {
      fl_value_set_string_take(result, "text", fl_value_new_string(text));
    }
  }
  if (offers(targets, count, kHtmlTarget)) {
    read_string(clipboard, result, kHtmlTarget, "html");
  }
  if (offers(targets, count, kKapyTarget)) {
    read_string(clipboard, result, kKapyTarget, "kapy");
  }
  if (offers(targets, count, kVsCodeTarget)) {
    read_string(clipboard, result, kVsCodeTarget, "vscode");
  }
  read_image(clipboard, result, targets, count);
  if (gtk_targets_include_uri(targets, count)) read_files(clipboard, result);
  g_free(targets);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                    gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (g_strcmp0(method, "write") == 0) {
    response = write_clipboard(fl_method_call_get_args(method_call));
  } else if (g_strcmp0(method, "read") == 0) {
    response = read_clipboard();
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(method_call, response, nullptr);
}

}  // namespace

struct _RichClipboard {
  FlMethodChannel* channel;
};

RichClipboard* rich_clipboard_new(FlBinaryMessenger* messenger) {
  RichClipboard* clipboard = g_new0(RichClipboard, 1);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  clipboard->channel = fl_method_channel_new(
      messenger, "kapynotes/rich_clipboard", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(clipboard->channel, method_call_cb,
                                            nullptr, nullptr);
  return clipboard;
}

void rich_clipboard_free(RichClipboard* clipboard) {
  g_clear_object(&clipboard->channel);
  g_free(clipboard);
}
