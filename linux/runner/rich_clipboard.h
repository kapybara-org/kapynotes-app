#ifndef RUNNER_RICH_CLIPBOARD_H_
#define RUNNER_RICH_CLIPBOARD_H_

#include <flutter_linux/flutter_linux.h>

// Backs the `kapynotes/rich_clipboard` channel, as the macOS and Windows
// runners do: a copy publishes the plain text, the HTML, Kapy Notes' own
// fragment and a picture at once, and a paste reads every one of them, so
// formatting, tables and pictures survive a trip through the clipboard in
// either direction.
//
//   write {text, html, kapy, image, imageMime}
//   read  -> {types, text, html, kapy, vscode, image, imageMime, files}
typedef struct _RichClipboard RichClipboard;

RichClipboard* rich_clipboard_new(FlBinaryMessenger* messenger);

void rich_clipboard_free(RichClipboard* clipboard);

#endif  // RUNNER_RICH_CLIPBOARD_H_
