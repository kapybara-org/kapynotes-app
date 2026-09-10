#include "synthetic_keys.h"

#include <commctrl.h>

#include <optional>

namespace {

// Any value; it only has to be ours. The engine does not subclass its window.
constexpr UINT_PTR kSubclassId = 0x4B415059;  // "KAPY"

// Bits 16–23 of a key message's lParam hold the scan code; bit 24 says the key
// is from the extended set (the arrow cluster, the right-hand modifiers, the
// Windows keys) whose scan codes are prefixed 0xE0 on the wire.
constexpr LPARAM kScanCodeMask = 0xFF << 16;
constexpr LPARAM kExtendedBit = LPARAM{1} << 24;

struct ScanCode {
  BYTE code;
  bool extended;
};

// The scan code and extended bit written into the last key message, kept for
// the WM_CHAR messages TranslateMessage derives from it. Those inherit the
// key message's lParam — so they inherit its missing scan code too, and the
// engine reads the scan code out of the WM_CHAR, not the key-down, when the
// two are paired.
std::optional<ScanCode> g_last_repair;

// Keys that a keyboard reports with the 0xE0 prefix. MapVirtualKey only sets
// the prefix for the right-hand modifiers, but the engine tells Left from
// Numpad 4 by it, so the rest of the extended set is listed here.
bool IsExtendedKey(UINT virtual_key) {
  switch (virtual_key) {
    case VK_RCONTROL:
    case VK_RMENU:
    case VK_LWIN:
    case VK_RWIN:
    case VK_APPS:
    case VK_INSERT:
    case VK_DELETE:
    case VK_HOME:
    case VK_END:
    case VK_PRIOR:
    case VK_NEXT:
    case VK_LEFT:
    case VK_UP:
    case VK_RIGHT:
    case VK_DOWN:
    case VK_NUMLOCK:
    case VK_DIVIDE:
    case VK_SNAPSHOT:
    case VK_CANCEL:
    case VK_SLEEP:
    case VK_BROWSER_BACK:
    case VK_BROWSER_FORWARD:
    case VK_BROWSER_REFRESH:
    case VK_BROWSER_STOP:
    case VK_BROWSER_SEARCH:
    case VK_BROWSER_FAVORITES:
    case VK_BROWSER_HOME:
    case VK_VOLUME_MUTE:
    case VK_VOLUME_DOWN:
    case VK_VOLUME_UP:
    case VK_MEDIA_NEXT_TRACK:
    case VK_MEDIA_PREV_TRACK:
    case VK_MEDIA_STOP:
    case VK_MEDIA_PLAY_PAUSE:
    case VK_LAUNCH_MAIL:
    case VK_LAUNCH_MEDIA_SELECT:
    case VK_LAUNCH_APP1:
    case VK_LAUNCH_APP2:
      return true;
    default:
      return false;
  }
}

// The scan code a keyboard would have sent for |virtual_key|, or nothing when
// Windows has none for it.
std::optional<ScanCode> ScanCodeFor(UINT virtual_key) {
  // The _EX form tells VK_RCONTROL from VK_LCONTROL and reports the 0xE0
  // prefix in its high byte; a plain VK_CONTROL gets the left key, which is
  // what a keyboard sends and what the engine expects.
  const UINT mapped = ::MapVirtualKeyW(virtual_key, MAPVK_VK_TO_VSC_EX);
  const BYTE code = static_cast<BYTE>(mapped & 0xFF);
  if (code == 0) {
    return std::nullopt;
  }
  const bool prefixed = (mapped >> 8) == 0xE0 || (mapped >> 8) == 0xE1;
  return ScanCode{code, prefixed || IsExtendedKey(virtual_key)};
}

LPARAM WithScanCode(LPARAM lparam, ScanCode scan) {
  lparam &= ~(kScanCodeMask | kExtendedBit);
  lparam |= static_cast<LPARAM>(scan.code) << 16;
  if (scan.extended) {
    lparam |= kExtendedBit;
  }
  return lparam;
}

// A key message with its scan code filled in, or the message as it came.
LPARAM RepairKeyMessage(WPARAM wparam, LPARAM lparam) {
  // Whatever happens to this message decides what happens to its characters.
  g_last_repair.reset();

  if ((lparam & kScanCodeMask) != 0) {
    // A keyboard sent this. Not ours to touch.
    return lparam;
  }
  // VK_PACKET carries a Unicode character with no key behind it, and its scan
  // code is legitimately empty; the engine lets it through to TranslateMessage.
  if (wparam == VK_PACKET) {
    return lparam;
  }
  const std::optional<ScanCode> scan = ScanCodeFor(static_cast<UINT>(wparam));
  if (!scan) {
    return lparam;
  }
  g_last_repair = scan;
  return WithScanCode(lparam, *scan);
}

// A character message given the scan code of the key that produced it, when
// that key was one we repaired.
LPARAM RepairCharMessage(LPARAM lparam) {
  if ((lparam & kScanCodeMask) != 0 || !g_last_repair) {
    return lparam;
  }
  return WithScanCode(lparam, *g_last_repair);
}

LRESULT CALLBACK RepairProc(HWND hwnd, UINT message, WPARAM wparam,
                            LPARAM lparam, UINT_PTR subclass_id,
                            DWORD_PTR /*reference*/) {
  switch (message) {
    case WM_KEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYDOWN:
    case WM_SYSKEYUP:
      lparam = RepairKeyMessage(wparam, lparam);
      break;
    case WM_CHAR:
    case WM_SYSCHAR:
    case WM_DEADCHAR:
    case WM_SYSDEADCHAR:
      lparam = RepairCharMessage(lparam);
      break;
    case WM_NCDESTROY:
      ::RemoveWindowSubclass(hwnd, RepairProc, subclass_id);
      g_last_repair.reset();
      break;
  }
  return ::DefSubclassProc(hwnd, message, wparam, lparam);
}

}  // namespace

void RepairSyntheticKeys(HWND flutter_view) {
  if (flutter_view == nullptr) {
    return;
  }
  ::SetWindowSubclass(flutter_view, RepairProc, kSubclassId, 0);
}
