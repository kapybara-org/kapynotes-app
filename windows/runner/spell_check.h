#ifndef RUNNER_SPELL_CHECK_H_
#define RUNNER_SPELL_CHECK_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Backs the system spelling service used by the note editor. The returned
// channel must live for as long as the Flutter engine.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterSpellCheckChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SPELL_CHECK_H_
