#include "system_region.h"

#include <locale.h>
#include <string.h>

struct _SystemRegion {
  FlMethodChannel* channel;
};

// What GTK resolved from LC_ALL, LC_NUMERIC and LANG when it called
// setlocale at startup: "en_IN.UTF-8" is IN, and "C" or "POSIX" name no
// territory at all. GNOME's Formats setting and KDE's Numbers setting both
// write LC_NUMERIC.
static FlValue* numeric_territory() {
  const gchar* locale = setlocale(LC_NUMERIC, nullptr);
  const gchar* underscore = locale == nullptr ? nullptr : strchr(locale, '_');
  if (underscore == nullptr) return fl_value_new_null();
  const gchar* territory = underscore + 1;
  return fl_value_new_string_sized(territory, strcspn(territory, ".@"));
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  if (g_strcmp0(fl_method_call_get_name(method_call), "region") != 0) {
    fl_method_call_respond_not_implemented(method_call, nullptr);
    return;
  }
  g_autoptr(FlValue) result = numeric_territory();
  fl_method_call_respond_success(method_call, result, nullptr);
}

SystemRegion* system_region_new(FlBinaryMessenger* messenger) {
  SystemRegion* region = g_new0(SystemRegion, 1);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  region->channel = fl_method_channel_new(messenger, "kapynotes/region",
                                          FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(region->channel, method_call_cb,
                                            nullptr, nullptr);
  return region;
}

void system_region_free(SystemRegion* region) {
  g_clear_object(&region->channel);
  g_free(region);
}
