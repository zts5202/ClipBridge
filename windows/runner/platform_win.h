#ifndef RUNNER_PLATFORM_WIN_H_
#define RUNNER_PLATFORM_WIN_H_

#include <flutter/binary_messenger.h>

#include <windows.h>

#include <functional>

void InstallClipBridgeChannel(flutter::BinaryMessenger* messenger,
                              HWND hwnd,
                              std::function<void()> quit);
void RemoveClipBridgeTray();
bool HandleClipBridgeMessage(HWND hwnd,
                             UINT message,
                             WPARAM wparam,
                             LPARAM lparam,
                             LRESULT* result);

#endif  // RUNNER_PLATFORM_WIN_H_
