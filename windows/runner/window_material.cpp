#include "window_material.h"

#include <dwmapi.h>

#include <flutter/standard_method_codec.h>

namespace {

// Windows 11 22H2 (build 22621) and later. Redefined for older SDKs.
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif
enum BackdropType : DWORD {
  kBackdropAuto = 0,
  kBackdropNone = 1,
  kBackdropMica = 2,
  kBackdropAcrylic = 3,
  kBackdropTabbed = 4,
};

// The route shared with the Start menu and taskbar. Values from the Windows
// internals that every acrylic library on Windows relies on; undocumented,
// but unchanged since 1803 and still in use on Windows 11.
enum AccentState : DWORD {
  kAccentDisabled = 0,
  kAccentEnableAcrylicBlurBehind = 4,
};

struct AccentPolicy {
  AccentState state;
  DWORD flags;
  DWORD gradient_color;  // AABBGGRR
  DWORD animation_id;
};

struct WindowCompositionAttributeData {
  DWORD attribute;  // 19 = WCA_ACCENT_POLICY
  PVOID data;
  SIZE_T size;
};

constexpr DWORD kAccentPolicyAttribute = 19;
constexpr DWORD kAccentDrawAllBorders = 0x20;

using SetWindowCompositionAttributeFn =
    BOOL(WINAPI*)(HWND, WindowCompositionAttributeData*);

// Whether the composition attribute route exists, and a handle to it if so.
SetWindowCompositionAttributeFn LoadSetWindowCompositionAttribute() {
  HMODULE user32 = GetModuleHandleW(L"user32.dll");
  if (!user32) {
    return nullptr;
  }
  return reinterpret_cast<SetWindowCompositionAttributeFn>(
      GetProcAddress(user32, "SetWindowCompositionAttribute"));
}

// Lets the DWM paint the client area, which is what makes Flutter's
// transparent pixels show what is behind the window rather than black.
void ExtendFrameIntoClient(HWND window, bool extend) {
  MARGINS margins = extend ? MARGINS{-1, -1, -1, -1} : MARGINS{0, 0, 0, 0};
  DwmExtendFrameIntoClientArea(window, &margins);
}

bool ApplySystemBackdrop(HWND window, bool enabled) {
  DWORD backdrop = enabled ? kBackdropAcrylic : kBackdropAuto;
  HRESULT result = DwmSetWindowAttribute(window, DWMWA_SYSTEMBACKDROP_TYPE,
                                         &backdrop, sizeof(backdrop));
  return SUCCEEDED(result);
}

bool ApplyAccentPolicy(HWND window, bool enabled, double amount) {
  auto set_attribute = LoadSetWindowCompositionAttribute();
  if (!set_attribute) {
    return false;
  }
  // A faint neutral tint so the blur has a body to it; Flutter paints the
  // colour that matters. Alpha is in the top byte, and thins with the
  // settings slider: this tint is the material's only strength, so a window
  // asked to be nearly invisible has to give it up. Never quite to zero — a
  // policy with no colour at all is drawn by some builds as no blur either.
  const double t = amount < 0 ? 0 : (amount > 1 ? 1 : amount);
  const DWORD tint_alpha = static_cast<DWORD>(0x30 - (0x2c * t));
  AccentPolicy policy{
      enabled ? kAccentEnableAcrylicBlurBehind : kAccentDisabled,
      enabled ? kAccentDrawAllBorders : 0,
      enabled ? (tint_alpha << 24) : 0u, 0};
  WindowCompositionAttributeData data{kAccentPolicyAttribute, &policy,
                                      sizeof(policy)};
  return set_attribute(window, &data) != FALSE;
}

void HandleMethodCall(
    HWND window, const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "setGlass") {
    result->NotImplemented();
    return;
  }
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!arguments) {
    result->Error("bad-arguments", "Expected an enabled flag.");
    return;
  }
  auto it = arguments->find(flutter::EncodableValue("enabled"));
  const bool* enabled =
      it == arguments->end() ? nullptr : std::get_if<bool>(&it->second);
  if (!enabled) {
    result->Error("bad-arguments", "Expected an enabled flag.");
    return;
  }
  // An older Dart side that sends no amount gets the middle of the scale
  // rather than an error: the flag is the part this cannot do without.
  auto amount_it = arguments->find(flutter::EncodableValue("amount"));
  const double* amount = amount_it == arguments->end()
                             ? nullptr
                             : std::get_if<double>(&amount_it->second);
  result->Success(flutter::EncodableValue(
      SetWindowGlass(window, *enabled, amount ? *amount : 0.5)));
}

}  // namespace

bool SetWindowGlass(HWND window, bool enabled, double amount) {
  if (!window) {
    return false;
  }
  if (!enabled) {
    ApplyAccentPolicy(window, false, 0);
    ApplySystemBackdrop(window, false);
    ExtendFrameIntoClient(window, false);
    return false;
  }
  // The composition attribute first, on every Windows that has it, and the
  // documented Windows 11 backdrop only where it does not. Two things decide
  // that order, both of them what the settings slider promises:
  //
  // The backdrop is a fixed recipe. It has no tint and no strength to set, so
  // under it the slider moved the tints Flutter paints and nothing else, and
  // the window never got past "translucent" however far it was dragged — the
  // same wall the macOS material hit before its alpha was tied to the slider.
  // The accent policy's gradient alpha is that knob here.
  //
  // The backdrop also goes solid the moment the window loses focus, by
  // design and with no attribute to say otherwise. Glass that is only glass
  // while you are looking straight at it reads as broken.
  //
  // The accent route is the one the Start menu and taskbar use, so it is not
  // going anywhere, and it still blurs on Windows 11 (TranslucentTB rests on
  // it). Its known cost is a lag while dragging or resizing on some Windows
  // 10 builds; a window whose material follows the slider is worth it.
  bool on = ApplyAccentPolicy(window, true, amount) ||
            ApplySystemBackdrop(window, true);
  if (on) {
    ExtendFrameIntoClient(window, true);
  }
  return on;
}

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterWindowMaterialChannel(flutter::BinaryMessenger* messenger,
                              HWND window) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "kapynotes/window_material",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [window](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                   result) { HandleMethodCall(window, call, std::move(result)); });
  return channel;
}
