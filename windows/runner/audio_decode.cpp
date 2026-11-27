#include "audio_decode.h"

#include <windows.h>

#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <objbase.h>
#include <wmcodecdsp.h>
#include <wrl/client.h>

#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

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
constexpr UINT32 kBlockAlign = kChannels * kBitsPerSample / 8;

// The rates Media Foundation's AAC encoder accepts, and the only ones it will
// write. It refuses 16 kHz, which is why `record`, asking for 16 kHz mono at
// 48 kbps, picks the encoder's nearest output type and every recording made
// on a PC is mono AAC-LC at 44.1 kHz and 96 kbps. An encode picks the same
// way, so a cleaned recording is the file a Windows recording would have been.
constexpr UINT32 kAacSampleRates[] = {44100, 48000};

// The encoder's bit rates, in bytes per second: 96, 128, 160 and 192 kbps.
constexpr UINT32 kAacBytesPerSecond[] = {12000, 16000, 20000, 24000};

// How much PCM is read per pass: half a second at 16 kHz. Never the whole
// file, which is 57 MB at thirty minutes.
constexpr DWORD kPcmChunkBytes = 16 * 1024;

// Posted by the worker thread to hand a finished decode or encode back to the
// platform thread. Flutter's method results may only be completed there.
constexpr UINT kDecodeFinished = WM_APP + 71;
constexpr UINT kEncodeFinished = WM_APP + 72;

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

// Media Foundation started for the life of one decode or encode.
// Reference-counted by the platform, so two running at the same time is safe.
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

// One finished decode or encode, on its way back to the platform thread.
struct Completion {
  std::unique_ptr<flutter::MethodResult<EncodableValue>> result;
  bool ok = false;
  std::string message;
  // Which step failed and how, for the log: never shown to anyone.
  std::string detail;
  std::string path;
  int64_t frames = 0;
  int sample_rate = 0;
};

void FailedAt(Completion* out, const char* step, HRESULT hr) {
  char detail[64];
  snprintf(detail, sizeof(detail), "%s 0x%08lX", step,
           static_cast<unsigned long>(hr));
  out->detail = detail;
}

// Whether the reader hands over mono 16-bit PCM at [sample_rate], which is
// what Decode asked for and what the file it writes is read as.
bool IsWanted(IMFSourceReader* reader, int sample_rate) {
  ComPtr<IMFMediaType> current;
  if (FAILED(reader->GetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM),
          current.GetAddressOf()))) {
    return false;
  }
  GUID subtype = GUID_NULL;
  UINT32 rate = 0;
  UINT32 channels = 0;
  UINT32 bits = 0;
  return SUCCEEDED(current->GetGUID(MF_MT_SUBTYPE, &subtype)) &&
         subtype == MFAudioFormat_PCM &&
         SUCCEEDED(current->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &rate)) &&
         rate == static_cast<UINT32>(sample_rate) &&
         SUCCEEDED(current->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &channels)) &&
         channels == kChannels &&
         SUCCEEDED(current->GetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, &bits)) &&
         bits == kBitsPerSample;
}

void Decode(const std::string& source, int sample_rate, Completion* out) {
  out->message = "This recording could not be read.";
  out->sample_rate = sample_rate;

  MediaFoundationSession session;
  if (!session.ok()) return FailedAt(out, "startup", E_FAIL);

  ComPtr<IMFSourceReader> reader;
  HRESULT hr = MFCreateSourceReaderFromURL(Widen(source).c_str(), nullptr,
                                           reader.GetAddressOf());
  if (FAILED(hr)) return FailedAt(out, "open", hr);

  // Only the audio, and all of it. Leaving other streams selected would make
  // the read loop step over samples it has no use for.
  reader->SetStreamSelection(static_cast<DWORD>(MF_SOURCE_READER_ALL_STREAMS),
                             FALSE);
  reader->SetStreamSelection(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), TRUE);

  // Asking for uncompressed PCM at the model's rate is what makes the reader
  // build a decode-and-resample chain for us.
  ComPtr<IMFMediaType> wanted;
  hr = MFCreateMediaType(wanted.GetAddressOf());
  if (FAILED(hr)) return FailedAt(out, "type", hr);
  wanted->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  wanted->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  wanted->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, kBitsPerSample);
  wanted->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND,
                    static_cast<UINT32>(sample_rate));
  wanted->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kChannels);
  hr = reader->SetCurrentMediaType(
      static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
      wanted.Get());
  if (FAILED(hr)) return FailedAt(out, "format", hr);

  const std::wstring pcm_path = TempPcmPath();
  if (pcm_path.empty()) return FailedAt(out, "temp", E_FAIL);
  FILE* sink = nullptr;
  if (_wfopen_s(&sink, pcm_path.c_str(), L"wb") != 0 || sink == nullptr) {
    return FailedAt(out, "create", E_FAIL);
  }

  int64_t frames = 0;
  bool failed = false;
  while (true) {
    DWORD flags = 0;
    ComPtr<IMFSample> sample;
    hr = reader->ReadSample(
        static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), 0, nullptr,
        &flags, nullptr, sample.GetAddressOf());
    if (FAILED(hr)) {
      FailedAt(out, "read", hr);
      failed = true;
      break;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) break;
    // The AAC decoder announces its output once it has seen the first frame,
    // so every recording made on a PC reports a change here (KAP-437). A change
    // that leaves the samples as asked for is no change at all. One that does
    // not is asked for the same samples again, and what came with it, in the
    // other shape, is dropped:
    // written into the same file, it would be a transcript that drifts rather
    // than one that fails.
    if ((flags & MF_SOURCE_READERF_CURRENTMEDIATYPECHANGED) &&
        !IsWanted(reader.Get(), sample_rate)) {
      hr = reader->SetCurrentMediaType(
          static_cast<DWORD>(MF_SOURCE_READER_FIRST_AUDIO_STREAM), nullptr,
          wanted.Get());
      if (FAILED(hr) || !IsWanted(reader.Get(), sample_rate)) {
        FailedAt(out, "format-changed", hr);
        failed = true;
        break;
      }
      continue;
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

template <size_t N>
UINT32 Nearest(const UINT32 (&choices)[N], UINT32 wanted) {
  UINT32 best = choices[0];
  for (UINT32 choice : choices) {
    const UINT32 distance = choice > wanted ? choice - wanted : wanted - choice;
    const UINT32 best_distance = best > wanted ? best - wanted : wanted - best;
    if (distance < best_distance) best = choice;
  }
  return best;
}

// Uncompressed 16-bit mono at `sample_rate`, spelled out in full: the
// resampler and the sink writer both refuse a PCM type missing its block
// alignment or byte rate.
ComPtr<IMFMediaType> PcmType(UINT32 sample_rate) {
  ComPtr<IMFMediaType> type;
  if (FAILED(MFCreateMediaType(type.GetAddressOf()))) return nullptr;
  type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
  type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, kBitsPerSample);
  type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kChannels);
  type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, sample_rate);
  type->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, kBlockAlign);
  type->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, sample_rate * kBlockAlign);
  return type;
}

// Places `frames` frames starting `frame` frames into a stream at
// `sample_rate`. Media Foundation keeps time in 100 ns units, and the sink
// writer takes the recording's timing from these.
void Stamp(IMFSample* sample, LONGLONG frame, LONGLONG frames,
           UINT32 sample_rate) {
  const LONGLONG start = frame * 10000000LL / sample_rate;
  sample->SetSampleTime(start);
  sample->SetSampleDuration((frame + frames) * 10000000LL / sample_rate -
                            start);
}

// An empty sample with room for `capacity` bytes.
ComPtr<IMFSample> NewSample(DWORD capacity) {
  ComPtr<IMFMediaBuffer> buffer;
  ComPtr<IMFSample> sample;
  if (FAILED(MFCreateMemoryBuffer(capacity, buffer.GetAddressOf())) ||
      FAILED(MFCreateSample(sample.GetAddressOf())) ||
      FAILED(sample->AddBuffer(buffer.Get()))) {
    return nullptr;
  }
  return sample;
}

// Writes the PCM in `input` to an `.m4a` at `destination`, through the
// Audio Resampler DSP and then the sink writer.
//
// The resampler is here by hand because the sink writer will not resample:
// it only finds an encoder, and the AAC encoder will not take 16 kHz. So the
// PCM goes up to the encoder's rate first, a chunk at a time.
bool WriteAac(FILE* input, const std::wstring& destination, UINT32 pcm_rate,
              UINT32 aac_rate, UINT32 bit_rate) {
  ComPtr<IMFTransform> resampler;
  if (FAILED(CoCreateInstance(CLSID_CResamplerMediaObject, nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(resampler.GetAddressOf())))) {
    return false;
  }
  const ComPtr<IMFMediaType> pcm_in = PcmType(pcm_rate);
  const ComPtr<IMFMediaType> pcm_out = PcmType(aac_rate);
  if (pcm_in == nullptr || pcm_out == nullptr ||
      FAILED(resampler->SetInputType(0, pcm_in.Get(), 0)) ||
      FAILED(resampler->SetOutputType(0, pcm_out.Get(), 0))) {
    return false;
  }

  ComPtr<IMFMediaType> aac;
  if (FAILED(MFCreateMediaType(aac.GetAddressOf()))) return false;
  aac->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
  aac->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
  aac->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, kBitsPerSample);
  aac->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kChannels);
  aac->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, aac_rate);
  aac->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND,
                 Nearest(kAacBytesPerSecond, bit_rate / 8));

  // The container comes from the extension, which is why Dart's name for the
  // file being written still ends in `.m4a`.
  ComPtr<IMFSinkWriter> writer;
  DWORD stream = 0;
  if (FAILED(MFCreateSinkWriterFromURL(destination.c_str(), nullptr, nullptr,
                                       writer.GetAddressOf())) ||
      FAILED(writer->AddStream(aac.Get(), &stream)) ||
      FAILED(writer->SetInputMediaType(stream, pcm_out.Get(), nullptr)) ||
      FAILED(writer->BeginWriting())) {
    return false;
  }

  resampler->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  resampler->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

  // Room for a whole chunk once resampled, so one pass of `drain` usually
  // takes everything a chunk produced.
  const DWORD out_capacity = static_cast<DWORD>(
      (static_cast<ULONGLONG>(kPcmChunkBytes) * aac_rate / pcm_rate) +
      1024 * kBlockAlign);
  LONGLONG written = 0;

  // Hands the writer everything the resampler has ready. A fresh sample each
  // time, because the writer may still be holding the last one.
  const auto drain = [&]() -> bool {
    while (true) {
      const ComPtr<IMFSample> sample = NewSample(out_capacity);
      ComPtr<IMFMediaBuffer> buffer;
      if (sample == nullptr ||
          FAILED(sample->GetBufferByIndex(0, buffer.GetAddressOf()))) {
        return false;
      }
      MFT_OUTPUT_DATA_BUFFER output = {};
      output.pSample = sample.Get();
      DWORD status = 0;
      const HRESULT result = resampler->ProcessOutput(0, 1, &output, &status);
      if (output.pEvents != nullptr) output.pEvents->Release();
      if (result == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
      if (FAILED(result)) return false;
      DWORD length = 0;
      buffer->GetCurrentLength(&length);
      if (length == 0) return true;
      const LONGLONG frames = length / kBlockAlign;
      Stamp(sample.Get(), written, frames, aac_rate);
      if (FAILED(writer->WriteSample(stream, sample.Get()))) return false;
      written += frames;
    }
  };

  std::vector<BYTE> chunk(kPcmChunkBytes);
  LONGLONG read_frames = 0;
  while (true) {
    const size_t read = fread(chunk.data(), 1, chunk.size(), input);
    // A stray odd byte at the very end is half a sample, and not audio.
    const DWORD length = static_cast<DWORD>(read - read % kBlockAlign);
    if (length == 0) break;
    const ComPtr<IMFSample> sample = NewSample(length);
    ComPtr<IMFMediaBuffer> buffer;
    BYTE* bytes = nullptr;
    if (sample == nullptr ||
        FAILED(sample->GetBufferByIndex(0, buffer.GetAddressOf())) ||
        FAILED(buffer->Lock(&bytes, nullptr, nullptr))) {
      return false;
    }
    memcpy(bytes, chunk.data(), length);
    buffer->Unlock();
    buffer->SetCurrentLength(length);
    Stamp(sample.Get(), read_frames, length / kBlockAlign, pcm_rate);
    if (FAILED(resampler->ProcessInput(0, sample.Get(), 0)) || !drain()) {
      return false;
    }
    read_frames += length / kBlockAlign;
  }
  if (ferror(input) || read_frames == 0) return false;

  resampler->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
  resampler->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
  return drain() && SUCCEEDED(writer->Finalize());
}

void Encode(const std::string& source, const std::string& destination,
            int sample_rate, int bit_rate, Completion* out) {
  out->message = "This recording could not be saved.";
  if (sample_rate <= 0 || bit_rate <= 0) return;

  MediaFoundationSession session;
  if (!session.ok()) return;

  FILE* input = nullptr;
  if (_wfopen_s(&input, Widen(source).c_str(), L"rb") != 0 || input == nullptr) {
    return;
  }
  const std::wstring destination_path = Widen(destination);
  const bool written = WriteAac(
      input, destination_path, static_cast<UINT32>(sample_rate),
      Nearest(kAacSampleRates, static_cast<UINT32>(sample_rate)),
      static_cast<UINT32>(bit_rate));
  fclose(input);
  // The writer has let go of the file by now: it lived only inside WriteAac.
  if (!written) {
    DeleteFileW(destination_path.c_str());
    return;
  }

  out->ok = true;
  out->message.clear();
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
      done->result->Error("decode", done->message,
                          EncodableValue(done->detail));
    }
    return 0;
  }
  if (message == kEncodeFinished) {
    std::unique_ptr<Completion> done(reinterpret_cast<Completion*>(lparam));
    if (done->ok) {
      done->result->Success();
    } else {
      done->result->Error("encode", done->message);
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
        const bool encode = call.method_name() == "encode";
        if (!encode && call.method_name() != "decode") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<EncodableMap>(call.arguments());
        const auto string_argument = [arguments](const char* key) {
          if (arguments == nullptr) return std::string();
          const auto found = arguments->find(EncodableValue(key));
          if (found == arguments->end()) return std::string();
          const auto* value = std::get_if<std::string>(&found->second);
          return value == nullptr ? std::string() : *value;
        };
        const auto int_argument = [arguments](const char* key, int fallback) {
          if (arguments == nullptr) return fallback;
          const auto found = arguments->find(EncodableValue(key));
          if (found == arguments->end()) return fallback;
          const auto* value = std::get_if<int32_t>(&found->second);
          return value == nullptr ? fallback : static_cast<int>(*value);
        };
        const std::string path = string_argument("path");
        const std::string destination = string_argument("destination");
        const int sample_rate = int_argument("sampleRate", 16000);
        const int bit_rate = int_argument("bitRate", 48000);
        if (path.empty() || (encode && destination.empty())) {
          result->Error("arguments", "A recording is required.");
          return;
        }
        if (completion == nullptr) {
          if (encode) {
            result->Error("encode", "This recording could not be saved.");
          } else {
            result->Error("decode", "This recording could not be read.");
          }
          return;
        }

        // Off the UI thread: a thirty-minute recording is seconds of work, and
        // the window it would otherwise block is the one telling the user the
        // transcript is being made, or the recording cleaned up.
        auto pending = std::make_unique<Completion>();
        pending->result = std::move(result);
        std::thread([path, destination, sample_rate, bit_rate, encode,
                     completion, raw = pending.release()]() mutable {
          // Every thread that touches COM initialises it for itself.
          const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
          if (encode) {
            Encode(path, destination, sample_rate, bit_rate, raw);
          } else {
            Decode(path, sample_rate, raw);
          }
          if (SUCCEEDED(com)) CoUninitialize();
          // Ownership passes to the window procedure, which runs on the
          // platform thread and is the only place the result may be answered.
          if (!PostMessage(completion,
                           encode ? kEncodeFinished : kDecodeFinished, 0,
                           reinterpret_cast<LPARAM>(raw))) {
            delete raw;
          }
        }).detach();
      });

  return channel;
}
