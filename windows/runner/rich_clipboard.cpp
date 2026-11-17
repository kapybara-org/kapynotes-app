#include "rich_clipboard.h"

#include <flutter/standard_method_codec.h>
#include <objbase.h>
#include <shellapi.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdint>
#include <cstring>
#include <iomanip>
#include <limits>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr wchar_t kPngClipboardFormat[] = L"PNG";
constexpr wchar_t kKapyClipboardFormat[] = L"KapyNotes Fragment";

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

std::string Utf8FromUtf16(const wchar_t* source, size_t length) {
  if (length == 0 ||
      length > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return std::string();
  }
  const int source_length = static_cast<int>(length);
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, source, source_length,
                                         nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(size), '\0');
  if (::WideCharToMultiByte(CP_UTF8, 0, source, source_length, result.data(),
                            size, nullptr, nullptr) != size) {
    return std::string();
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

bool SetKapyFragment(const std::string& fragment) {
  return SetGlobalClipboardData(::RegisterClipboardFormatW(kKapyClipboardFormat),
                                fragment.c_str(), fragment.size() + 1);
}

// Every byte of |format| on the open clipboard. The allocation can be
// larger than what was written, so text formats are cut at their NUL.
std::vector<uint8_t> ClipboardBytes(UINT format) {
  if (format == 0) {
    return std::vector<uint8_t>();
  }
  HANDLE memory = ::GetClipboardData(format);
  if (memory == nullptr) {
    return std::vector<uint8_t>();
  }
  const auto* data = static_cast<const uint8_t*>(::GlobalLock(memory));
  if (data == nullptr) {
    return std::vector<uint8_t>();
  }
  std::vector<uint8_t> bytes(data, data + ::GlobalSize(memory));
  ::GlobalUnlock(memory);
  return bytes;
}

// |bytes| up to their first NUL as UTF-8. Invalid sequences become U+FFFD,
// because Dart refuses a channel string that isn't UTF-8.
std::string ClipboardUtf8(const std::vector<uint8_t>& bytes) {
  size_t length = 0;
  while (length < bytes.size() && bytes[length] != 0) {
    ++length;
  }
  if (length == 0 ||
      length > static_cast<size_t>(std::numeric_limits<int>::max())) {
    return std::string();
  }
  std::string text(reinterpret_cast<const char*>(bytes.data()), length);
  const int text_length = static_cast<int>(text.size());
  if (::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                            text_length, nullptr, 0) > 0) {
    return text;
  }
  const int wide_length =
      ::MultiByteToWideChar(CP_UTF8, 0, text.data(), text_length, nullptr, 0);
  if (wide_length <= 0) {
    return std::string();
  }
  std::wstring wide(static_cast<size_t>(wide_length), L'\0');
  if (::MultiByteToWideChar(CP_UTF8, 0, text.data(), text_length, wide.data(),
                            wide_length) != wide_length) {
    return std::string();
  }
  return Utf8FromUtf16(wide.c_str(), wide.size());
}

std::string ClipboardUnicodeText() {
  const std::vector<uint8_t> bytes = ClipboardBytes(CF_UNICODETEXT);
  const auto* text = reinterpret_cast<const wchar_t*>(bytes.data());
  const size_t capacity = bytes.size() / sizeof(wchar_t);
  size_t length = 0;
  while (length < capacity && text[length] != L'\0') {
    ++length;
  }
  return Utf8FromUtf16(text, length);
}

std::vector<std::string> ClipboardFiles() {
  std::vector<std::string> paths;
  HANDLE memory = ::GetClipboardData(CF_HDROP);
  if (memory == nullptr) {
    return paths;
  }
  HDROP drop = static_cast<HDROP>(memory);
  const UINT count = ::DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
  for (UINT index = 0; index < count; ++index) {
    const UINT length = ::DragQueryFileW(drop, index, nullptr, 0);
    if (length == 0) {
      continue;
    }
    std::wstring path(static_cast<size_t>(length) + 1, L'\0');
    if (::DragQueryFileW(drop, index, path.data(), length + 1) == 0) {
      continue;
    }
    std::string utf8 = Utf8FromUtf16(path.c_str(), length);
    if (!utf8.empty()) {
      paths.push_back(std::move(utf8));
    }
  }
  return paths;
}

std::string FormatName(UINT format) {
  wchar_t name[256];
  const int length = ::GetClipboardFormatNameW(format, name, 256);
  if (length > 0) {
    return Utf8FromUtf16(name, static_cast<size_t>(length));
  }
  switch (format) {
    case CF_TEXT:
      return "CF_TEXT";
    case CF_BITMAP:
      return "CF_BITMAP";
    case CF_METAFILEPICT:
      return "CF_METAFILEPICT";
    case CF_OEMTEXT:
      return "CF_OEMTEXT";
    case CF_DIB:
      return "CF_DIB";
    case CF_UNICODETEXT:
      return "CF_UNICODETEXT";
    case CF_ENHMETAFILE:
      return "CF_ENHMETAFILE";
    case CF_HDROP:
      return "CF_HDROP";
    case CF_LOCALE:
      return "CF_LOCALE";
    case CF_DIBV5:
      return "CF_DIBV5";
    default:
      return "CF_" + std::to_string(format);
  }
}

// Any picture WIC can decode, as PNG.
std::vector<uint8_t> PngFromEncoded(const std::vector<uint8_t>& encoded) {
  if (encoded.empty() ||
      encoded.size() > static_cast<size_t>(std::numeric_limits<DWORD>::max())) {
    return std::vector<uint8_t>();
  }
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(::CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(&factory)))) {
    return std::vector<uint8_t>();
  }
  ComPtr<IWICStream> input;
  if (FAILED(factory->CreateStream(&input)) ||
      FAILED(input->InitializeFromMemory(
          const_cast<BYTE*>(encoded.data()), static_cast<DWORD>(encoded.size())))) {
    return std::vector<uint8_t>();
  }
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateDecoderFromStream(
          input.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame)) ||
      FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0,
                                   WICBitmapPaletteTypeCustom))) {
    return std::vector<uint8_t>();
  }
  UINT width = 0;
  UINT height = 0;
  if (FAILED(converter->GetSize(&width, &height)) || width == 0 || height == 0) {
    return std::vector<uint8_t>();
  }

  ComPtr<IStream> output;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> target;
  if (FAILED(::CreateStreamOnHGlobal(nullptr, TRUE, &output)) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder)) ||
      FAILED(encoder->Initialize(output.Get(), WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(&target, nullptr)) ||
      FAILED(target->Initialize(nullptr)) ||
      FAILED(target->SetSize(width, height))) {
    return std::vector<uint8_t>();
  }
  WICPixelFormatGUID pixel_format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(target->SetPixelFormat(&pixel_format)) ||
      !IsEqualGUID(pixel_format, GUID_WICPixelFormat32bppBGRA) ||
      FAILED(target->WriteSource(converter.Get(), nullptr)) ||
      FAILED(target->Commit()) || FAILED(encoder->Commit())) {
    return std::vector<uint8_t>();
  }

  STATSTG stat = {};
  HGLOBAL memory = nullptr;
  if (FAILED(output->Stat(&stat, STATFLAG_NONAME)) ||
      FAILED(::GetHGlobalFromStream(output.Get(), &memory)) ||
      stat.cbSize.QuadPart == 0 ||
      stat.cbSize.QuadPart > ::GlobalSize(memory)) {
    return std::vector<uint8_t>();
  }
  const auto* data = static_cast<const uint8_t*>(::GlobalLock(memory));
  if (data == nullptr) {
    return std::vector<uint8_t>();
  }
  std::vector<uint8_t> png(data, data + static_cast<size_t>(stat.cbSize.QuadPart));
  ::GlobalUnlock(memory);
  return png;
}

// A packed DIB as PNG, through the BMP file WIC decodes: a file header is
// put in front, pointing past the info header, masks and colour table.
std::vector<uint8_t> PngFromDib(const std::vector<uint8_t>& dib) {
  if (dib.size() < sizeof(BITMAPINFOHEADER) ||
      dib.size() > std::numeric_limits<DWORD>::max() - sizeof(BITMAPFILEHEADER)) {
    return std::vector<uint8_t>();
  }
  BITMAPINFOHEADER info;
  std::memcpy(&info, dib.data(), sizeof(info));
  if (info.biSize < sizeof(BITMAPINFOHEADER) || info.biSize > dib.size()) {
    return std::vector<uint8_t>();
  }
  uint64_t pixels = info.biSize;
  if (info.biSize == sizeof(BITMAPINFOHEADER) &&
      info.biCompression == BI_BITFIELDS) {
    pixels += 3 * sizeof(DWORD);
  }
  uint64_t colors = info.biClrUsed;
  if (colors == 0 && info.biBitCount >= 1 && info.biBitCount <= 8) {
    colors = uint64_t{1} << info.biBitCount;
  }
  pixels += colors * sizeof(RGBQUAD);
  if (pixels >= dib.size()) {
    return std::vector<uint8_t>();
  }

  BITMAPFILEHEADER file = {};
  file.bfType = 0x4D42;
  file.bfSize = static_cast<DWORD>(sizeof(BITMAPFILEHEADER) + dib.size());
  file.bfOffBits = static_cast<DWORD>(sizeof(BITMAPFILEHEADER) + pixels);
  std::vector<uint8_t> bmp(sizeof(BITMAPFILEHEADER) + dib.size());
  std::memcpy(bmp.data(), &file, sizeof(file));
  std::memcpy(bmp.data() + sizeof(file), dib.data(), dib.size());
  return PngFromEncoded(bmp);
}

// Everything on the clipboard that a paste can use, in the shape
// ClipboardSnapshot.fromChannel reads. "HTML Format" keeps its header, which
// Dart reads for the fragment's offsets and the page's address. A picture is
// the "PNG" format when an app published one, else the bitmap as PNG; the
// bitmap is read as CF_DIB, which Windows also offers for a CF_DIBV5, so any
// alpha a CF_DIBV5 carried is dropped.
void HandleRead(std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (!OpenClipboardWithRetry(nullptr)) {
    result->Error("clipboard_open", "The clipboard is busy");
    return;
  }
  EncodableMap snapshot;
  EncodableList types;
  for (UINT format = ::EnumClipboardFormats(0); format != 0;
       format = ::EnumClipboardFormats(format)) {
    types.push_back(EncodableValue(FormatName(format)));
  }
  snapshot[EncodableValue("types")] = EncodableValue(std::move(types));

  const std::string text = ClipboardUnicodeText();
  if (!text.empty()) {
    snapshot[EncodableValue("text")] = EncodableValue(text);
  }
  const std::string html =
      ClipboardUtf8(ClipboardBytes(::RegisterClipboardFormatW(L"HTML Format")));
  if (!html.empty()) {
    snapshot[EncodableValue("html")] = EncodableValue(html);
  }
  const std::string kapy =
      ClipboardUtf8(ClipboardBytes(::RegisterClipboardFormatW(kKapyClipboardFormat)));
  if (!kapy.empty()) {
    snapshot[EncodableValue("kapy")] = EncodableValue(kapy);
  }
  EncodableList files;
  for (const std::string& path : ClipboardFiles()) {
    files.push_back(EncodableValue(path));
  }
  if (!files.empty()) {
    snapshot[EncodableValue("files")] = EncodableValue(std::move(files));
  }
  std::vector<uint8_t> image =
      ClipboardBytes(::RegisterClipboardFormatW(kPngClipboardFormat));
  const std::vector<uint8_t> dib =
      image.empty() ? ClipboardBytes(CF_DIB) : std::vector<uint8_t>();
  ::CloseClipboard();

  if (image.empty()) {
    image = PngFromDib(dib);
  }
  if (!image.empty()) {
    snapshot[EncodableValue("image")] = EncodableValue(std::move(image));
    snapshot[EncodableValue("imageMime")] = EncodableValue("image/png");
  }
  result->Success(EncodableValue(std::move(snapshot)));
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
  const auto* kapy = StringArgument(*arguments, "kapy");
  const bool kapy_written =
      kapy == nullptr || kapy->empty() || SetKapyFragment(*kapy);
  ::CloseClipboard();

  if (!text_written || !html_written || !image_written || !kapy_written) {
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
        } else if (call.method_name() == "read") {
          HandleRead(std::move(result));
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
