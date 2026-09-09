#include "audio_decode.h"

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <objbase.h>
#include <wrl/client.h>

#include <cstdio>
#include <memory>
#include <string>
#include <thread>

#include <flutter/standard_method_codec.h>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Microsoft::WRL::ComPtr;

constexpr char kChannelName[] = "kapynotes/audio_decode";

// What the recogniser is trained on. Asked of the source reader rather than
// done here: Media Foundation inserts its own decoder and resampler to satisfy
// whatever uncompressed type it is given, and its resampler is better than a
// hand-written one would be.
constexpr UINT32 kBitsPerSample = 16;
constexpr UINT32 kChannels = 1;

// Posted by the worker thread to hand a finished decode back to the platform
// thread. Flutter's method results may only be completed there.
constexpr UINT kDecodeFinished = WM_APP + 71;

std::wstring Widen(const std::string& value) {
  if (value.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                                 static_cast<int>(value.size()), nullptr, 0);
  std::wstring out(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                      out.data(), size);
  return out;
}

std::string Narrow(const std::wstring& value) {
  if (value.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                 static_cast<int>(value.size()), nullptr, 0,
                                 nullptr, nullptr);
  std::string out(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), static_cast<int>(value.size()),
                      out.data(), size, nullptr, nullptr);
  return out;
}

// A temporary file for the decoded samples, in the place Windows keeps them.
std::wstring TempPcmPath() {
  wchar_t directory[MAX_PATH] = {0};
  if (GetTempPathW(MAX_PATH, directory) == 0) return std::wstring();
  wchar_t path[MAX_PATH] = {0};
  if (GetTempFileNameW(directory, L"kpy", 0, path) == 0) return std::wstring();
  return std::wstring(path);
}

// Media Foundation started for the life of one decode. Reference-counted by
// the platform, so a second decode running at the same time is safe.
class MediaFoundationSession {
 public:
  MediaFoundationSession() : ok_(SUCCEEDED(MFStartup(MF_VERSION))) {}
  ~MediaFoundationSession() {
    if (ok_) MFShutdown();
  }
  bool ok() const { return ok_; }

 private:
  bool ok_;
};

// One finished decode, on its way back to the platform thread.
struct Completion {
  std::unique_ptr<flutter::MethodResult<EncodableValue>> result;
  bool ok = false;
  std::string message;
  std::string path;
  int64_t frames = 0;
  int sample_rate = 0;
};

void Decode(const std::string& source, int sample_rate, Completion* out) {
  out->message = "This recording could not be read.";
  out->sample_rate = sample_rate;

  MediaFoundationSession session;
  if (!session.ok()) return;

  ComPtr<IMFSourceReader> reader;
  if (FAILED(MFCreateSourceReaderFromURL(Widen(source).c_str(), nullptr,
                                         reader.GetAddressOf()))) {
    return;
  }

  // Only the audio, and all of it. Leaving other streams selected would make
  // the read loop step over samples it has no use for.
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), TRUE);

  // Asking for uncompressed PCM at the model's rate is what makes the reader
  // build a decode-and-resample chain for us.
  ComPtr<IMFMediaType> wanted;
  if (FAILED(MFCreateMediaType(wanted.GetAddressOf()))) return;
  wanted->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  wanted->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  wanted->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, kBitsPerSample);
  wanted->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                    static_cast<UINT32>(sample_rate));
  wanted->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kChannels);
  if (FAILED(reader->SetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
          wanted.Get()))) {
    return;
  }

  const std::wstring pcm_path = TempPcmPath();
  if (pcm_path.empty()) return;
  FILE* sink = nullptr;
  if (_wfopen_s(&sink, pcm_path.c_str(), L"wb") != 0 || sink == nullptr) {
    return;
  }

  int64_t frames = 0;
  bool failed = false;
  while (true) {
    DWORD flags = 0;
    ComPtr<IMFSample> sample;
    if (FAILED(reader->ReadSample(
            static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, nullptr,
            &flags, nullptr, sample.GetAddressOf()))) {
      failed = true;
      break;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    // A format change mid-file would quietly start writing samples at another
    // rate into the same file, which is a transcript that drifts rather than
    // one that fails. Stop instead.
    if (flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) {
      failed = true;
      break;
    }
    if (!sample) continue;

    ComPtr<IMFMediaBuffer> buffer;
    if (FAILED(sample->ConvertToContiguousBuffer(buffer.GetAddressOf()))) {
      failed = true;
      break;
    }
    BYTE* bytes = nullptr;
    DWORD length = 0;
    if (FAILED(buffer->Lock(&bytes, nullptr, &length))) {
      failed = true;
      break;
    }
    if (length > 0) {
      if (fwrite(bytes, 1, length, sink) != length) {
        buffer->Unlock();
        failed = true;
        break;
      }
      frames += length / (kBitsPerSample / 8) / kChannels;
    }
    buffer->Unlock();
  }

  fclose(sink);
  if (failed || frames == 0) {
    DeleteFileW(pcm_path.c_str());
    if (!failed) out->message = "This recording has no audio in it.";
    return;
  }

  out->ok = true;
  out->message.clear();
  out->path = Narrow(pcm_path);
  out->frames = frames;
}

LRESULT CALLBACK CompletionWndProc(HWND window, UINT message, WPARAM wparam,
                                   LPARAM lparam) {
  if (message == kDecodeFinished) {
    std::unique_ptr<Completion> done(reinterpret_cast<Completion*>(lparam));
    if (done->ok) {
      done->result->Success(EncodableValue(EncodableMap{
          {EncodableValue("path"), EncodableValue(done->path)},
          {EncodableValue("sampleRate"), EncodableValue(done->sample_rate)},
          {EncodableValue("frames"), EncodableValue(done->frames)},
      }));
    } else {
      done->result->Error("decode", done->message);
    }
    return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

// A message-only window, created on the platform thread, whose only job is to
// be somewhere a worker thread can post to.
//
// The runner's loop is `GetMessage(&msg, nullptr, ...)`, which dispatches for
// every window on the thread, so this needs nothing of `FlutterWindow` and
// does not have to be threaded through its message handler.
HWND CreateCompletionWindow() {
  static const wchar_t kClassName[] = L"KapyNotesAudioDecode";
  static bool registered = false;
  HINSTANCE instance = GetModuleHandle(nullptr);
  if (!registered) {
    WNDCLASSW window_class = {};
    window_class.lpfnWndProc = CompletionWndProc;
    window_class.hInstance = instance;
    window_class.lpszClassName = kClassName;
    RegisterClassW(&window_class);
    registered = true;
  }
  return CreateWindowExW(0, kClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                         nullptr, instance, nullptr);
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<EncodableValue>>
RegisterAudioDecodeChannel(flutter::BinaryMessenger* messenger) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());

  const HWND completion = CreateCompletionWindow();

  channel->SetMethodCallHandler(
      [completion](
          const flutter::MethodCall<EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        if (call.method_name() != "decode") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        std::string path;
        int sample_rate = 16000;
        if (arguments != nullptr) {
          auto found = arguments->find(EncodableValue("path"));
          if (found != arguments->end()) {
            if (const auto* value = std::get_if<std::string>(&found->second)) {
              path = *value;
            }
          }
          found = arguments->find(EncodableValue("sampleRate"));
          if (found != arguments->end()) {
            if (const auto* value = std::get_if<int32_t>(&found->second)) {
              sample_rate = *value;
            }
          }
        }
        if (path.empty()) {
          result->Error("arguments", "A recording is required.");
          return;
        }
        if (completion == nullptr) {
          result->Error("decode", "This recording could not be read.");
          return;
        }

        // Off the UI thread: a thirty-minute recording is seconds of work, and
        // the window it would otherwise block is the one telling the user the
        // transcript is being made.
        auto pending = std::make_unique<Completion>();
        pending->result = std::move(result);
        std::thread([path, sample_rate, completion,
                     raw = pending.release()]() mutable {
          // Every thread that touches COM initialises it for itself.
          const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
          Decode(path, sample_rate, raw);
          if (SUCCEEDED(com)) CoUninitialize();
          // Ownership passes to the window procedure, which runs on the
          // platform thread and is the only place the result may be answered.
          if (!PostMessage(completion, kDecodeFinished, 0,
                           reinterpret_cast<LPARAM>(raw))) {
            delete raw;
          }
        }).detach();
      });

  return channel;
}
