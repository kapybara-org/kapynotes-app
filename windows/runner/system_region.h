#ifndef RUNNER_SYSTEM_REGION_H_
#define RUNNER_SYSTEM_REGION_H_

#include <memory>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

// Backs the `kapynotes/region` channel: the country this device is set to.
//
// Windows keeps three settings that all look like "language" from Dart: the
// display language, the regional format, and Country or region. Only the last
// says where the user is, and Flutter's locale is built from the first — so
// the Dart side asks here instead. See lib/core/system_region.dart.
//
// The returned channel must be kept alive for as long as the engine is.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterSystemRegionChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_SYSTEM_REGION_H_
