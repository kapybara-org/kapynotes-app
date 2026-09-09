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

// The pre-22H2 route, shared with the Start menu. Values from the Windows
// internals that every acrylic library on Windows 10 relies on.
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
  // settings slider: on this route the tint is the only knob there is, so a
  // window asked to be nearly invisible has to give it up.
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
    ApplySystemBackdrop(window, false);
    ApplyAccentPolicy(window, false, 0);
    ExtendFrameIntoClient(window, false);
    return false;
  }
  // The documented route first. It fails cleanly before 22H2, where the
  // attribute is unknown to the DWM, and that is when the older one is tried.
  //
  // Note that the amount only reaches the older route. Windows 11's acrylic
  // backdrop is a fixed recipe with no tint or strength to set, so there the
  // slider moves the tints Flutter paints and nothing else.
  bool on = ApplySystemBackdrop(window, true) ||
            ApplyAccentPolicy(window, true, amount);
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
