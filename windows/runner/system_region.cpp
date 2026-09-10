#include "system_region.h"

#include <windows.h>

#include <memory>
#include <string>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "utils.h"

namespace {

using flutter::EncodableValue;

constexpr char kChannelName[] = "kapynotes/region";

// "Country or region" in Settings — the home location, which is the setting
// that actually says where the user is. Resolved at run time rather than
// linked: it arrived in Windows 10 1709, and looking it up this way means the
// runner still builds against an SDK that predates it and still runs on a
// system that lacks it.
std::wstring GeoName() {
  using GetUserDefaultGeoNameFn = int(WINAPI*)(LPWSTR, int);
  HMODULE kernel = ::GetModuleHandleW(L"kernel32.dll");
  if (kernel == nullptr) {
    return L"";
  }
  auto get_geo_name = reinterpret_cast<GetUserDefaultGeoNameFn>(
      ::GetProcAddress(kernel, "GetUserDefaultGeoName"));
  if (get_geo_name == nullptr) {
    return L"";
  }
  // Asks for the length first; the answer counts the terminator.
  int length = get_geo_name(nullptr, 0);
  if (length <= 1) {
    return L"";
  }
  std::wstring buffer(length, L'\0');
  if (get_geo_name(buffer.data(), length) == 0) {
    return L"";
  }
  buffer.resize(::wcslen(buffer.c_str()));
  return buffer;
}

// The regional format's own country, for systems too old to have the setting
// above. Not as direct — it is the format the user reads numbers in rather
// than where they live — but on this question those two agree.
std::wstring FormatCountry() {
  wchar_t buffer[16] = {};
  int written = ::GetLocaleInfoEx(LOCALE_NAME_USER_DEFAULT,
                                  LOCALE_SISO3166CTRYNAME, buffer,
                                  static_cast<int>(std::size(buffer)));
  if (written <= 1) {
    return L"";
  }
  return std::wstring(buffer, written - 1);
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<EncodableValue>>
RegisterSystemRegionChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "region") {
          result->NotImplemented();
          return;
        }
        std::wstring region = GeoName();
        if (region.empty()) {
          region = FormatCountry();
        }
        // Null rather than an empty string where nothing named a country:
        // Dart reads that as "fall back to the language".
        if (region.empty()) {
          result->Success();
          return;
        }
        result->Success(EncodableValue(Utf8FromUtf16(region.c_str())));
      });

  return channel;
}
