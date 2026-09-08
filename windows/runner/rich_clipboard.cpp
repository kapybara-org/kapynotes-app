#include "rich_clipboard.h"

#include <flutter/standard_method_codec.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdint>
#include <cstring>
#include <iomanip>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr wchar_t kPngClipboardFormat[] = L"PNG";

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

const std::vector<uint8_t>* BytesArgument(const EncodableMap& arguments,
                                          const std::string& name) {
  const auto* value = Find(arguments, name);
  return value == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(value);
}

bool OpenClipboardWithRetry(HWND owner) {
  for (int attempt = 0; attempt < 5; ++attempt) {
    if (::OpenClipboard(owner)) {
      return true;
    }
    ::Sleep(5);
  }
  return false;
}

bool SetGlobalClipboardData(UINT format, const void* source, size_t bytes) {
  if (format == 0 || source == nullptr || bytes == 0) {
    return false;
  }
  HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (memory == nullptr) {
    return false;
  }
  void* destination = ::GlobalLock(memory);
  if (destination == nullptr) {
    ::GlobalFree(memory);
    return false;
  }
  std::memcpy(destination, source, bytes);
  ::GlobalUnlock(memory);
  if (::SetClipboardData(format, memory) == nullptr) {
    ::GlobalFree(memory);
    return false;
  }
  // SetClipboardData owns the HGLOBAL from here.
  return true;
}

std::wstring Utf16FromUtf8(const std::string& source) {
  if (source.empty()) {
    return std::wstring();
  }
  if (source.size() > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return std::wstring();
  }
  const int source_length = static_cast<int>(source.size());
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, source.data(), source_length, nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring result(static_cast<size_t>(length), L'\0');
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, source.data(),
                            source_length, result.data(), length) != length) {
    return std::wstring();
  }
  return result;
}

bool SetPlainText(const std::string& text) {
  const std::wstring wide = Utf16FromUtf8(text);
  if (!text.empty() && wide.empty()) {
    return false;
  }
  return SetGlobalClipboardData(CF_UNICODETEXT, wide.c_str(),
                                (wide.size() + 1) * sizeof(wchar_t));
}

std::string TenDigitOffset(size_t value) {
  std::ostringstream output;
  output << std::setfill('0') << std::setw(10) << value;
  return output.str();
}

bool SetHtml(const std::string& fragment) {
  const UINT format = ::RegisterClipboardFormatW(L"HTML Format");
  if (format == 0) {
    return false;
  }
  const std::string header_template =
      "Version:0.9\r\n"
      "StartHTML:0000000000\r\n"
      "EndHTML:0000000000\r\n"
      "StartFragment:0000000000\r\n"
      "EndFragment:0000000000\r\n";
  const std::string prefix = "<html><body><!--StartFragment-->";
  const std::string suffix = "<!--EndFragment--></body></html>";
  const size_t start_html = header_template.size();
  const size_t start_fragment = start_html + prefix.size();
  const size_t end_fragment = start_fragment + fragment.size();
  const size_t end_html = end_fragment + suffix.size();
  if (end_html > 9999999999ULL) {
    return false;
  }
  const std::string header =
      "Version:0.9\r\nStartHTML:" + TenDigitOffset(start_html) +
      "\r\nEndHTML:" + TenDigitOffset(end_html) +
      "\r\nStartFragment:" + TenDigitOffset(start_fragment) +
      "\r\nEndFragment:" + TenDigitOffset(end_fragment) + "\r\n";
  const std::string payload = header + prefix + fragment + suffix;
  return SetGlobalClipboardData(format, payload.c_str(), payload.size() + 1);
}

bool SetDecodedBitmap(const std::vector<uint8_t>& encoded) {
  if (encoded.empty() ||
      encoded.size() > static_cast<size_t>(std::numeric_limits<DWORD>::max())) {
    return false;
  }

  ComPtr<IWICImagingFactory> factory;
  if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&factory)))) {
    return false;
  }
  ComPtr<IWICStream> stream;
  if (FAILED(factory->CreateStream(&stream)) ||
      FAILED(stream->InitializeFromMemory(
          const_cast<BYTE*>(encoded.data()), static_cast<DWORD>(encoded.size())))) {
    return false;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromStream(
          stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder))) {
    return false;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame))) {
    return false;
  }
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0,
                                   WICBitmapPaletteTypeCustom))) {
    return false;
  }

  UINT width = 0;
  UINT height = 0;
  if (FAILED(converter->GetSize(&width, &height)) || width == 0 || height == 0 ||
      width > std::numeric_limits<UINT>::max() / 4 ||
      width > static_cast<UINT>(std::numeric_limits<LONG>::max()) ||
      height > static_cast<UINT>(std::numeric_limits<LONG>::max())) {
    return false;
  }
  const UINT stride = width * 4;
  const uint64_t pixel_bytes = static_cast<uint64_t>(stride) * height;
  if (pixel_bytes > std::numeric_limits<UINT>::max() ||
      pixel_bytes > std::numeric_limits<size_t>::max() - sizeof(BITMAPV5HEADER)) {
    return false;
  }

  const size_t allocation = sizeof(BITMAPV5HEADER) +
                            static_cast<size_t>(pixel_bytes);
  HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, allocation);
  if (memory == nullptr) {
    return false;
  }
  auto* header = static_cast<BITMAPV5HEADER*>(::GlobalLock(memory));
  if (header == nullptr) {
    ::GlobalFree(memory);
    return false;
  }
  header->bV5Size = sizeof(BITMAPV5HEADER);
  header->bV5Width = static_cast<LONG>(width);
  header->bV5Height = -static_cast<LONG>(height);
  header->bV5Planes = 1;
  header->bV5BitCount = 32;
  header->bV5Compression = BI_BITFIELDS;
  header->bV5SizeImage = static_cast<DWORD>(pixel_bytes);
  header->bV5RedMask = 0x00FF0000;
  header->bV5GreenMask = 0x0000FF00;
  header->bV5BlueMask = 0x000000FF;
  header->bV5AlphaMask = 0xFF000000;
  header->bV5CSType = LCS_sRGB;
  header->bV5Intent = LCS_GM_IMAGES;
  BYTE* pixels = reinterpret_cast<BYTE*>(header) + sizeof(BITMAPV5HEADER);
  const HRESULT copied = converter->CopyPixels(
      nullptr, stride, static_cast<UINT>(pixel_bytes), pixels);
  ::GlobalUnlock(memory);
  if (FAILED(copied) || ::SetClipboardData(CF_DIBV5, memory) == nullptr) {
    ::GlobalFree(memory);
    return false;
  }
  return true;
}

bool SetEncodedImage(const std::vector<uint8_t>& bytes,
                     const std::string& mime) {
  const std::wstring format_name =
      mime == "image/png" ? kPngClipboardFormat : Utf16FromUtf8(mime);
  const UINT format = format_name.empty()
                          ? 0
                          : ::RegisterClipboardFormatW(format_name.c_str());
  return SetGlobalClipboardData(format, bytes.data(), bytes.size());
}

std::string ReadHtml() {
  const UINT format = ::RegisterClipboardFormatW(L"HTML Format");
  if (format == 0 || !::IsClipboardFormatAvailable(format) ||
      !OpenClipboardWithRetry(nullptr)) {
    return std::string();
  }
  std::string result;
  HANDLE memory = ::GetClipboardData(format);
  if (memory != nullptr) {
    const char* data = static_cast<const char*>(::GlobalLock(memory));
    if (data != nullptr) {
      const size_t capacity = ::GlobalSize(memory);
      size_t length = 0;
      while (length < capacity && data[length] != '\0') {
        ++length;
      }
      result.assign(data, length);
      ::GlobalUnlock(memory);
    }
  }
  ::CloseClipboard();
  return result;
}

void HandleWrite(
    HWND owner, const EncodableValue* raw_arguments,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* arguments =
      raw_arguments == nullptr ? nullptr : std::get_if<EncodableMap>(raw_arguments);
  if (arguments == nullptr) {
    result->Error("clipboard_arguments", "Missing clipboard data");
    return;
  }
  const auto* text = StringArgument(*arguments, "text");
  const auto* html = StringArgument(*arguments, "html");
  if (text == nullptr || html == nullptr) {
    result->Error("clipboard_arguments", "Missing clipboard data");
    return;
  }
  if (!OpenClipboardWithRetry(owner)) {
    result->Error("clipboard_open", "The clipboard is busy");
    return;
  }
  ::EmptyClipboard();
  const bool text_written = SetPlainText(*text);
  const bool html_written = SetHtml(*html);
  bool image_written = true;
  const auto* image = BytesArgument(*arguments, "image");
  const auto* mime = StringArgument(*arguments, "imageMime");
  if (image != nullptr && !image->empty() && mime != nullptr) {
    const bool encoded_written = SetEncodedImage(*image, *mime);
    const bool bitmap_written = SetDecodedBitmap(*image);
    image_written = encoded_written || bitmap_written;
  }
  ::CloseClipboard();

  if (!text_written || !html_written || !image_written) {
    result->Error("clipboard_write", "Could not publish every clipboard format");
    return;
  }
  result->Success(EncodableValue());
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterRichClipboardChannel(flutter::BinaryMessenger* messenger, HWND owner) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "kapynotes/rich_clipboard",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [owner](const flutter::MethodCall<EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() == "write") {
          HandleWrite(owner, call.arguments(), std::move(result));
        } else if (call.method_name() == "readHtml") {
          const std::string html = ReadHtml();
          if (html.empty()) {
            result->Success();
          } else {
            result->Success(EncodableValue(html));
          }
        } else {
          result->NotImplemented();
        }
      });
  return channel;
}
