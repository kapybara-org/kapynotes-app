#ifndef RUNNER_AUDIO_DECODE_H_
#define RUNNER_AUDIO_DECODE_H_

#include <memory>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

// Backs the `kapynotes/audio_decode` channel: turning an `.m4a` recording into
// the raw samples a speech model can read.
//
// Every recording this app makes is AAC; every speech model wants 16 kHz mono
// PCM; nothing in Dart decodes AAC. Windows already has a decoder in the box,
// so this reaches for Media Foundation's source reader rather than shipping a
// second one — and because the reader will hand back whichever uncompressed
// format is asked of it, the channel change and the resample come free with
// the decode instead of being written here by hand.
//
// This platform is the one that actually needs the resample. `record` cannot
// capture at 16 kHz on Windows, because the Media Foundation AAC encoder takes
// only 44.1 or 48 kHz in, so every recording made on a PC arrives at the wrong
// rate for every model in the catalogue.
//
// The returned channel must be kept alive for as long as the engine is.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterAudioDecodeChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_AUDIO_DECODE_H_
