#ifndef RUNNER_WINDOW_MATERIAL_H_
#define RUNNER_WINDOW_MATERIAL_H_

#include <windows.h>

#include <memory>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

// Backs the `kapynotes/window_material` channel: the "Transparency" switch in
// Settings, on the native side.
//
// Puts the desktop, blurred, behind the Flutter view so that the thin tints
// Flutter paints in transparency mode have something to be thin over. The
// blur comes from the composition attribute that the system's own Start menu
// and taskbar use: undocumented, but held since 1803, present on Windows 11,
// and the only route whose strength the settings slider can move. Windows
// 11's documented acrylic backdrop is the fallback where that attribute is
// missing; it is a fixed recipe that goes solid when the window is inactive.
// Where neither works the window stays as it was and the Dart side is told,
// so it keeps its opaque paint rather than showing black through the gaps.
//
// The returned channel must be kept alive for as long as the engine is.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterWindowMaterialChannel(flutter::BinaryMessenger* messenger,
                              HWND window);

// Applies or removes the glass on |window|, at |amount| from the settings
// slider (0 to 1). Returns whether it is now on.
bool SetWindowGlass(HWND window, bool enabled, double amount);

#endif  // RUNNER_WINDOW_MATERIAL_H_
