#include "spell_check.h"

#include <flutter/standard_method_codec.h>
#include <objidl.h>
#include <spellcheck.h>
#include <windows.h>
#include <wrl/client.h>

#include <cstdint>
#include <limits>
#include <string>
#include <variant>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr char kChannelName[] = "kapynotes/spell_check";
constexpr size_t kMaximumResults = 100;
constexpr size_t kMaximumSuggestions = 5;

const EncodableValue* Find(const EncodableMap& arguments,
                           const std::string& name) {
  const auto found = arguments.find(EncodableValue(name));
  return found == arguments.end() ? nullptr : &found->second;
}

const std::string* StringArgument(const EncodableMap& arguments,
                                  const std::string& name) {
  const auto* value = Find(arguments, name);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

// The standard codec narrows a Dart int to whichever of the two integer
// variants it fits, so a text offset can arrive as either.
bool IntArgument(const EncodableMap& arguments,
                 const std::string& name,
                 int64_t* out) {
  const auto* value = Find(arguments, name);
  if (value == nullptr) {
    return false;
  }
  if (const auto* narrow = std::get_if<int32_t>(value)) {
    *out = *narrow;
    return true;
  }
  if (const auto* wide = std::get_if<int64_t>(value)) {
    *out = *wide;
    return true;
  }
  return false;
}

std::wstring Utf16FromUtf8(const std::string& source) {
  if (source.empty() ||
      source.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return std::wstring();
  }
  const int source_size = static_cast<int>(source.size());
  const int length = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                            source.data(), source_size,
                                            nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(length, L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source.data(),
                            source_size, result.data(), length) != length) {
    return std::wstring();
  }
  return result;
}

std::string Utf8FromUtf16(const wchar_t* source) {
  if (source == nullptr || *source == L'\0') {
    return std::string();
  }
  const int source_size = static_cast<int>(::wcslen(source));
  const int length = ::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
                                            source, source_size, nullptr, 0,
                                            nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string result(length, '\0');
  if (::WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, source,
                            source_size, result.data(), length, nullptr,
                            nullptr) != length) {
    return std::string();
  }
  return result;
}

bool Supports(ISpellCheckerFactory* factory, const std::wstring& language) {
  BOOL supported = FALSE;
  return !language.empty() &&
         SUCCEEDED(factory->IsSupported(language.c_str(), &supported)) &&
         supported;
}

std::wstring BestLanguage(ISpellCheckerFactory* factory,
                          const std::wstring& requested) {
  if (Supports(factory, requested)) {
    return requested;
  }
  wchar_t system_language[LOCALE_NAME_MAX_LENGTH] = {};
  if (::GetUserDefaultLocaleName(system_language, LOCALE_NAME_MAX_LENGTH) > 0 &&
      Supports(factory, system_language)) {
    return system_language;
  }
  return std::wstring();
}

bool CreateChecker(const std::wstring& language,
                   ComPtr<ISpellChecker>& checker) {
  if (language.empty()) {
    return false;
  }
  ComPtr<ISpellCheckerFactory> factory;
  if (FAILED(::CoCreateInstance(__uuidof(SpellCheckerFactory), nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&factory)))) {
    return false;
  }
  const std::wstring selected_language = BestLanguage(factory.Get(), language);
  if (selected_language.empty()) {
    return false;
  }
  return SUCCEEDED(
      factory->CreateSpellChecker(selected_language.c_str(), &checker));
}

// The corrections Windows hands over with the error itself: a single
// replacement, or the marker for a word typed twice. Everything else needs a
// lookup of its own, which waits for a menu that will actually show it.
EncodableList InlineSuggestionsFor(ISpellingError* error) {
  EncodableList result;
  CORRECTIVE_ACTION action = CORRECTIVE_ACTION_NONE;
  if (FAILED(error->get_CorrectiveAction(&action))) {
    return result;
  }
  if (action == CORRECTIVE_ACTION_REPLACE) {
    wchar_t* replacement = nullptr;
    if (SUCCEEDED(error->get_Replacement(&replacement)) &&
        replacement != nullptr) {
      result.emplace_back(Utf8FromUtf16(replacement));
      ::CoTaskMemFree(replacement);
    }
  } else if (action == CORRECTIVE_ACTION_DELETE) {
    result.emplace_back(std::string());
  }
  return result;
}

// What Windows would put at the top of its own menu for one flagged word.
EncodableList Suggest(const std::wstring& language, const std::wstring& word) {
  EncodableList result;
  if (word.empty()) {
    return result;
  }
  ComPtr<ISpellChecker> checker;
  if (!CreateChecker(language, checker)) {
    return result;
  }
  ComPtr<IEnumString> suggestions;
  if (FAILED(checker->Suggest(word.c_str(), &suggestions))) {
    return result;
  }
  while (result.size() < kMaximumSuggestions) {
    wchar_t* suggestion = nullptr;
    ULONG fetched = 0;
    const HRESULT next = suggestions->Next(1, &suggestion, &fetched);
    if (next != S_OK || fetched == 0 || suggestion == nullptr) {
      if (suggestion != nullptr) {
        ::CoTaskMemFree(suggestion);
      }
      break;
    }
    result.emplace_back(Utf8FromUtf16(suggestion));
    ::CoTaskMemFree(suggestion);
  }
  return result;
}

EncodableList Check(const std::wstring& language,
                    const std::wstring& text) {
  EncodableList response;
  if (language.empty() || text.empty()) {
    return response;
  }

  ComPtr<ISpellChecker> checker;
  if (!CreateChecker(language, checker)) {
    return response;
  }
  ComPtr<IEnumSpellingError> errors;
  if (FAILED(checker->Check(text.c_str(), &errors))) {
    return response;
  }

  while (response.size() < kMaximumResults) {
    ComPtr<ISpellingError> error;
    if (errors->Next(&error) != S_OK || error.Get() == nullptr) {
      break;
    }
    ULONG start = 0;
    ULONG length = 0;
    if (FAILED(error->get_StartIndex(&start)) ||
        FAILED(error->get_Length(&length)) || length == 0 ||
        start > text.size() || length > text.size() - start) {
      continue;
    }
    response.emplace_back(EncodableMap{
        {EncodableValue("startIndex"),
         EncodableValue(static_cast<int32_t>(start))},
        {EncodableValue("endIndex"),
         EncodableValue(static_cast<int32_t>(start + length))},
        {EncodableValue("suggestions"),
         EncodableValue(InlineSuggestionsFor(error.Get()))},
    });
  }
  return response;
}

void HandleCheck(
    const EncodableValue* raw_arguments,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* arguments = raw_arguments == nullptr
                              ? nullptr
                              : std::get_if<EncodableMap>(raw_arguments);
  if (arguments == nullptr) {
    result->Error("spell-check-arguments", "Missing spell-check data");
    return;
  }
  const auto* language = StringArgument(*arguments, "language");
  const auto* text = StringArgument(*arguments, "text");
  if (language == nullptr || text == nullptr) {
    result->Error("spell-check-arguments", "Missing language or text");
    return;
  }
  result->Success(EncodableValue(
      Check(Utf16FromUtf8(*language), Utf16FromUtf8(*text))));
}

void HandleSuggest(
    const EncodableValue* raw_arguments,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* arguments = raw_arguments == nullptr
                              ? nullptr
                              : std::get_if<EncodableMap>(raw_arguments);
  if (arguments == nullptr) {
    result->Error("spell-check-arguments", "Missing spell-check data");
    return;
  }
  const auto* language = StringArgument(*arguments, "language");
  const auto* text = StringArgument(*arguments, "text");
  int64_t start = 0;
  int64_t end = 0;
  if (language == nullptr || text == nullptr ||
      !IntArgument(*arguments, "startIndex", &start) ||
      !IntArgument(*arguments, "endIndex", &end) || start < 0 || end <= start) {
    result->Error("spell-check-arguments", "Missing language, text or range");
    return;
  }
  const std::wstring wide_text = Utf16FromUtf8(*text);
  const auto offset = static_cast<size_t>(start);
  const auto length = static_cast<size_t>(end - start);
  if (offset > wide_text.size() || length > wide_text.size() - offset) {
    result->Success(EncodableValue(EncodableList()));
    return;
  }
  result->Success(EncodableValue(Suggest(Utf16FromUtf8(*language),
                                         wide_text.substr(offset, length))));
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterSpellCheckChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "check") {
          HandleCheck(call.arguments(), std::move(result));
        } else if (call.method_name() == "suggest") {
          HandleSuggest(call.arguments(), std::move(result));
        } else {
          result->NotImplemented();
        }
      });
  return channel;
}
