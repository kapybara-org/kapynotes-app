#include "login_item.h"

#include <windows.h>

#include <memory>
#include <string>
#include <variant>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// The per-user autorun list, which is the right one here: the installer is
// per-user too (PrivilegesRequired=lowest), so there is no machine-wide
// install to speak for anybody else.
constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kValueName[] = L"Kapy Notes";

std::wstring ExecutableCommand() {
  wchar_t path[MAX_PATH];
  DWORD length = ::GetModuleFileNameW(nullptr, path, MAX_PATH);
  return L"\"" + std::wstring(path, length) + L"\"";
}

std::wstring ReadLoginItem() {
  HKEY key;
  if (::RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_QUERY_VALUE, &key) !=
      ERROR_SUCCESS) {
    return L"";
  }

  DWORD type = 0;
  DWORD bytes = 0;
  LSTATUS status =
      ::RegQueryValueExW(key, kValueName, nullptr, &type, nullptr, &bytes);
  if (status != ERROR_SUCCESS || type != REG_SZ || bytes == 0) {
    ::RegCloseKey(key);
    return L"";
  }

  // One element longer than the value needs, so a stored string that was
  // written without its terminator still ends somewhere.
  std::wstring value((bytes / sizeof(wchar_t)) + 1, L'\0');
  status = ::RegQueryValueExW(key, kValueName, nullptr, nullptr,
                              reinterpret_cast<LPBYTE>(value.data()), &bytes);
  ::RegCloseKey(key);
  if (status != ERROR_SUCCESS) {
    return L"";
  }
  // REG_SZ is stored with its terminator, which std::wstring supplies itself.
  value.resize(::wcslen(value.c_str()));
  return value;
}

bool WriteLoginItem(bool enabled) {
  HKEY key;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
                        KEY_SET_VALUE, nullptr, &key, nullptr) !=
      ERROR_SUCCESS) {
    return false;
  }

  LSTATUS status;
  if (enabled) {
    const std::wstring command = ExecutableCommand();
    status = ::RegSetValueExW(
        key, kValueName, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = ::RegDeleteValueW(key, kValueName);
    // Already absent is the state that was asked for.
    if (status == ERROR_FILE_NOT_FOUND) {
      status = ERROR_SUCCESS;
    }
  }

  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

// True when the app is set to start with the session.
//
// An entry left pointing at a path the app no longer lives at — reinstalled
// into a different folder, moved by hand — is repaired rather than reported
// as off. The user asked to be opened at login and never asked to stop; a
// switch that silently flipped itself would be the wrong answer twice.
bool IsLoginItemEnabled() {
  const std::wstring stored = ReadLoginItem();
  if (stored.empty()) {
    return false;
  }
  if (stored != ExecutableCommand()) {
    WriteLoginItem(true);
  }
  return true;
}

void HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "isSupported") {
    result->Success(EncodableValue(true));
    return;
  }

  if (method == "isEnabled") {
    result->Success(EncodableValue(IsLoginItemEnabled()));
    return;
  }

  if (method == "setEnabled") {
    const bool* enabled = nullptr;
    if (const auto* arguments = std::get_if<EncodableMap>(call.arguments())) {
      const auto entry = arguments->find(EncodableValue("enabled"));
      if (entry != arguments->end()) {
        enabled = std::get_if<bool>(&entry->second);
      }
    }
    if (enabled == nullptr) {
      result->Error("bad-arguments", "Expected an enabled flag.");
      return;
    }
    if (!WriteLoginItem(*enabled)) {
      result->Error("login-item",
                    "Windows would not change the startup entry for Kapy Notes.");
      return;
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterLoginItemChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "kapynotes/login_item",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) { HandleMethodCall(call, std::move(result)); });
  return channel;
}
