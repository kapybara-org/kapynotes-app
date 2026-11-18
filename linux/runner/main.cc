#include <glib.h>

#include "my_application.h"

// The helpers the packages ship beside the binary, in libexec/: an ffmpeg
// and a parecord in front of it, which is what package:record runs on Linux
// to capture and encode a voice note, and what playback and transcription
// decode recordings with. Found by name on PATH, so the bundle's own copies
// go first and every package behaves the same whatever the system has
// installed. A build run from the source tree has no libexec/ and uses the
// system's.
static void prepend_bundled_helpers_to_path() {
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", nullptr);
  if (executable == nullptr) return;
  g_autofree gchar* directory = g_path_get_dirname(executable);
  g_autofree gchar* helpers = g_build_filename(directory, "libexec", nullptr);
  if (!g_file_test(helpers, G_FILE_TEST_IS_DIR)) return;
  const gchar* path = g_getenv("PATH");
  g_autofree gchar* value = path != nullptr && path[0] != '\0'
                                ? g_strconcat(helpers, ":", path, nullptr)
                                : g_strdup(helpers);
  g_setenv("PATH", value, TRUE);
}

int main(int argc, char** argv) {
  prepend_bundled_helpers_to_path();
  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
