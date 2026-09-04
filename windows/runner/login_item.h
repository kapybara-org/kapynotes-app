#ifndef RUNNER_LOGIN_ITEM_H_
#define RUNNER_LOGIN_ITEM_H_

#include <memory>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

// Backs the `kapynotes/login_item` channel: "Open at login" in Settings.
//
// A per-user autorun entry in the registry, written here rather than by a
// package: the ones on pub pin a `win32` major that `package_info_plus` has
// already moved past, and the app would rather keep its version check.
//
// The returned channel must be kept alive for as long as the engine is.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterLoginItemChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_LOGIN_ITEM_H_
