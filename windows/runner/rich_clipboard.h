#ifndef RUNNER_RICH_CLIPBOARD_H_
#define RUNNER_RICH_CLIPBOARD_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
RegisterRichClipboardChannel(flutter::BinaryMessenger* messenger, HWND owner);

#endif  // RUNNER_RICH_CLIPBOARD_H_
