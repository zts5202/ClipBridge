#include "platform_win.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <flutter_windows.h>

#include <dwmapi.h>
#include <objidl.h>
#include <shellapi.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;

constexpr UINT kTrayCallback = WM_APP + 21;
constexpr UINT kCmdShow = 2101;
constexpr UINT kCmdPause = 2103;
constexpr UINT kCmdQuit = 2104;
constexpr UINT kCmdSync = 2105;
constexpr UINT kCmdStartup = 2106;
constexpr UINT kCmdSound = 2107;
constexpr UINT_PTR kFullscreenTimer = 42;

#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif
#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif
#ifndef DWMWA_USE_HOSTBACKDROPBRUSH
#define DWMWA_USE_HOSTBACKDROPBRUSH 17
#endif
#ifndef NIIF_NOSOUND
#define NIIF_NOSOUND 0x00000010
#endif

HWND g_hwnd = nullptr;
bool g_paused = false;
bool g_auto_sync = false;
bool g_launch = false;
bool g_allow_activate = false;
bool g_user_visible = true;
bool g_hidden_for_fullscreen = false;
bool g_pointer_near = false;
bool g_notification_sound = false;
bool g_force_quit = false;
std::string g_monitor_fp;
bool g_tray_added = false;
NOTIFYICONDATAW g_nid{};
std::function<void()> g_quit;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

void ApplyDockGlass(HWND hwnd);

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return L"";
  int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0);
  std::wstring out(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      out.data(), size);
  return out;
}

// Tray menu labels are ASCII hex so the binary stays correct even if /utf-8 is
// dropped. Notifications, tooltip updates, and Explorer paths already call
// Utf8ToWide. The window title is ASCII "ClipBridge". File dialogs are the
// file_picker plugin, which takes Flutter UTF-8 strings.
std::wstring MenuText(const char* utf8) { return Utf8ToWide(utf8); }

std::string WideToUtf8(const wchar_t* text) {
  if (text == nullptr || text[0] == L'\0') return "";
  int size = WideCharToMultiByte(CP_UTF8, 0, text, -1, nullptr, 0, nullptr,
                                 nullptr);
  if (size <= 1) return "";
  std::string out(size - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, -1, out.data(), size, nullptr, nullptr);
  return out;
}

void InvokeTray(const std::string& action) {
  if (!g_channel) return;
  g_channel->InvokeMethod(
      "onTray", std::make_unique<flutter::EncodableValue>(action));
}

bool OpenClipboardRetry(HWND hwnd) {
  for (int i = 0; i < 8; ++i) {
    if (OpenClipboard(hwnd)) return true;
    Sleep(15);
  }
  return false;
}

const flutter::EncodableMap* AsMap(const flutter::EncodableValue* value) {
  if (value == nullptr) return nullptr;
  return std::get_if<flutter::EncodableMap>(value);
}

std::string MapString(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return "";
  if (const auto* text = std::get_if<std::string>(&it->second)) return *text;
  return "";
}

bool MapBool(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return false;
  if (const auto* value = std::get_if<bool>(&it->second)) return *value;
  return false;
}

int MapInt(const flutter::EncodableMap& map, const char* key, int fallback) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return fallback;
  if (const auto* value = std::get_if<int32_t>(&it->second)) return *value;
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(*value);
  }
  return fallback;
}

bool IsShellWindow(HWND hwnd) {
  if (!hwnd) return false;
  if (hwnd == GetShellWindow()) return true;
  wchar_t cls[64];
  const int length = GetClassNameW(hwnd, cls, 64);
  if (length <= 0) return false;
  return wcscmp(cls, L"Progman") == 0 || wcscmp(cls, L"WorkerW") == 0 ||
         wcscmp(cls, L"Shell_TrayWnd") == 0 ||
         wcscmp(cls, L"Shell_SecondaryTrayWnd") == 0;
}

bool ForegroundCoversMonitor() {
  HWND foreground = GetForegroundWindow();
  if (!foreground || foreground == g_hwnd || !IsWindowVisible(foreground)) {
    return false;
  }
  // The desktop (Progman / WorkerW) covers the monitor whenever the user is
  // looking at the wallpaper. Treating that as fullscreen hid the strip, so
  // the only way to see ClipBridge was the tray.
  if (IsShellWindow(foreground)) return false;
  RECT window_rect;
  if (!GetWindowRect(foreground, &window_rect)) return false;
  if (window_rect.right - window_rect.left < 200 ||
      window_rect.bottom - window_rect.top < 200) {
    return false;
  }
  HMONITOR monitor = MonitorFromWindow(foreground, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info;
  info.cbSize = sizeof(info);
  if (!GetMonitorInfo(monitor, &info)) return false;
  const RECT& screen = info.rcMonitor;
  constexpr int tolerance = 4;
  return window_rect.left <= screen.left + tolerance &&
         window_rect.top <= screen.top + tolerance &&
         window_rect.right >= screen.right - tolerance &&
         window_rect.bottom >= screen.bottom - tolerance;
}

std::string MonitorFingerprint() {
  std::string fingerprint;
  EnumDisplayMonitors(
      nullptr, nullptr,
      [](HMONITOR monitor, HDC, LPRECT, LPARAM data) -> BOOL {
        auto* text = reinterpret_cast<std::string*>(data);
        MONITORINFO info;
        info.cbSize = sizeof(info);
        if (!GetMonitorInfo(monitor, &info)) return TRUE;
        const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
        *text += std::to_string(info.rcWork.left);
        *text += ',';
        *text += std::to_string(info.rcWork.top);
        *text += ',';
        *text += std::to_string(info.rcWork.right);
        *text += ',';
        *text += std::to_string(info.rcWork.bottom);
        *text += ',';
        *text += std::to_string(dpi);
        *text += ';';
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&fingerprint));
  return fingerprint;
}

bool PointerNearDock() {
  if (!g_hwnd || !IsWindowVisible(g_hwnd)) return false;
  POINT cursor;
  if (!GetCursorPos(&cursor)) return false;
  RECT rect;
  if (!GetWindowRect(g_hwnd, &rect)) return false;
  const HMONITOR monitor = MonitorFromWindow(g_hwnd, MONITOR_DEFAULTTONEAREST);
  const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
  const int pad = dpi == 0 ? 8 : static_cast<int>(8.0 * dpi / 96.0 + 0.5);
  InflateRect(&rect, pad, pad);
  return PtInRect(&rect, cursor) == TRUE;
}

void PollFullscreenAndMonitors() {
  if (!g_hwnd) return;
  const bool fullscreen = ForegroundCoversMonitor();
  if (fullscreen && IsWindowVisible(g_hwnd)) {
    g_hidden_for_fullscreen = true;
    ShowWindow(g_hwnd, SW_HIDE);
  } else if (!fullscreen && g_hidden_for_fullscreen && g_user_visible) {
    g_hidden_for_fullscreen = false;
    ShowWindow(g_hwnd, SW_SHOWNOACTIVATE);
  }
  const std::string fingerprint = MonitorFingerprint();
  if (!fingerprint.empty() && fingerprint != g_monitor_fp) {
    const bool first = g_monitor_fp.empty();
    g_monitor_fp = fingerprint;
    if (!first && g_channel) {
      g_channel->InvokeMethod("onMonitorsChanged",
                              std::make_unique<flutter::EncodableValue>());
    }
  }
  // "near" is a Windows macro, so the local name cannot be that word.
  const bool cursor_near = PointerNearDock();
  if (cursor_near != g_pointer_near) {
    g_pointer_near = cursor_near;
    if (g_channel) {
      g_channel->InvokeMethod(
          "onPointerNear",
          std::make_unique<flutter::EncodableValue>(cursor_near));
    }
  }
}

const std::vector<uint8_t>* MapBytes(const flutter::EncodableMap& map,
                                     const char* key) {
  auto it = map.find(flutter::EncodableValue(std::string(key)));
  if (it == map.end()) return nullptr;
  return std::get_if<std::vector<uint8_t>>(&it->second);
}

bool PngToDib(const uint8_t* data, size_t size, HGLOBAL* out) {
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
  if (!memory) return false;
  void* locked = GlobalLock(memory);
  memcpy(locked, data, size);
  GlobalUnlock(memory);
  ComPtr<IStream> stream;
  if (FAILED(CreateStreamOnHGlobal(memory, TRUE, &stream))) {
    GlobalFree(memory);
    return false;
  }
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
    return false;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromStream(
          stream.Get(), nullptr, WICDecodeMetadataCacheOnLoad, &decoder))) {
    return false;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame))) return false;
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter))) return false;
  if (FAILED(converter->Initialize(
          frame.Get(), GUID_WICPixelFormat32bppBGRA, WICBitmapDitherTypeNone,
          nullptr, 0.0, WICBitmapPaletteTypeCustom))) {
    return false;
  }
  UINT width = 0;
  UINT height = 0;
  converter->GetSize(&width, &height);
  if (width == 0 || height == 0 || width > 16000 || height > 16000) return false;
  const UINT stride = width * 4;
  const UINT image = stride * height;
  std::vector<BYTE> pixels(image);
  if (FAILED(converter->CopyPixels(nullptr, stride, image, pixels.data()))) {
    return false;
  }
  HGLOBAL dib = GlobalAlloc(GMEM_MOVEABLE, sizeof(BITMAPINFOHEADER) + image);
  if (!dib) return false;
  auto* base = static_cast<BYTE*>(GlobalLock(dib));
  auto* header = reinterpret_cast<BITMAPINFOHEADER*>(base);
  ZeroMemory(header, sizeof(*header));
  header->biSize = sizeof(BITMAPINFOHEADER);
  header->biWidth = static_cast<LONG>(width);
  header->biHeight = static_cast<LONG>(height);
  header->biPlanes = 1;
  header->biBitCount = 32;
  header->biCompression = BI_RGB;
  header->biSizeImage = image;
  BYTE* dest = base + sizeof(BITMAPINFOHEADER);
  for (UINT y = 0; y < height; ++y) {
    memcpy(dest + static_cast<size_t>(height - 1 - y) * stride,
           pixels.data() + static_cast<size_t>(y) * stride, stride);
  }
  GlobalUnlock(dib);
  *out = dib;
  return true;
}

std::vector<uint8_t> DibToPng(const BYTE* dib, size_t size) {
  if (size < sizeof(BITMAPINFOHEADER)) return {};
  const auto* header = reinterpret_cast<const BITMAPINFOHEADER*>(dib);
  if (header->biCompression != BI_RGB) return {};
  if (header->biBitCount != 32 && header->biBitCount != 24) return {};
  const int width = header->biWidth;
  int height = std::abs(header->biHeight);
  const bool bottom_up = header->biHeight > 0;
  if (width <= 0 || height <= 0 || header->biSize > size) return {};
  const UINT src_stride = ((width * header->biBitCount + 31) / 32) * 4;
  if (header->biSize + static_cast<size_t>(src_stride) * height > size) return {};
  const BYTE* pixels = dib + header->biSize;
  std::vector<BYTE> bgra(static_cast<size_t>(width) * height * 4);
  for (int y = 0; y < height; ++y) {
    const int src_y = bottom_up ? height - 1 - y : y;
    const BYTE* row = pixels + static_cast<size_t>(src_y) * src_stride;
    BYTE* dest = bgra.data() + static_cast<size_t>(y) * width * 4;
    if (header->biBitCount == 32) {
      memcpy(dest, row, static_cast<size_t>(width) * 4);
    } else {
      for (int x = 0; x < width; ++x) {
        dest[x * 4 + 0] = row[x * 3 + 0];
        dest[x * 4 + 1] = row[x * 3 + 1];
        dest[x * 4 + 2] = row[x * 3 + 2];
        dest[x * 4 + 3] = 255;
      }
    }
  }
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
    return {};
  }
  ComPtr<IWICBitmap> bitmap;
  if (FAILED(factory->CreateBitmapFromMemory(
          width, height, GUID_WICPixelFormat32bppBGRA, width * 4,
          static_cast<UINT>(bgra.size()), bgra.data(), &bitmap))) {
    return {};
  }
  ComPtr<IStream> stream;
  if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) return {};
  ComPtr<IWICBitmapEncoder> encoder;
  if (FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                    &encoder))) {
    return {};
  }
  if (FAILED(encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache))) {
    return {};
  }
  ComPtr<IWICBitmapFrameEncode> frame;
  ComPtr<IPropertyBag2> props;
  if (FAILED(encoder->CreateNewFrame(&frame, &props))) return {};
  if (FAILED(frame->Initialize(props.Get()))) return {};
  if (FAILED(frame->SetSize(width, height))) return {};
  WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
  if (FAILED(frame->SetPixelFormat(&format))) return {};
  if (FAILED(frame->WriteSource(bitmap.Get(), nullptr))) return {};
  if (FAILED(frame->Commit()) || FAILED(encoder->Commit())) return {};
  HGLOBAL global = nullptr;
  if (FAILED(GetHGlobalFromStream(stream.Get(), &global)) || !global) return {};
  const SIZE_T png_size = GlobalSize(global);
  void* png = GlobalLock(global);
  std::vector<uint8_t> out(png_size);
  if (png != nullptr) memcpy(out.data(), png, png_size);
  GlobalUnlock(global);
  return out;
}

std::string ReadClipboardText() {
  if (!OpenClipboardRetry(g_hwnd)) return "";
  HANDLE data = GetClipboardData(CF_UNICODETEXT);
  std::string text;
  if (data) {
    const auto* wide = static_cast<const wchar_t*>(GlobalLock(data));
    if (wide) {
      text = WideToUtf8(wide);
      GlobalUnlock(data);
    }
  }
  CloseClipboard();
  return text;
}

bool WriteClipboardText(const std::string& text) {
  const std::wstring wide = Utf8ToWide(text);
  const size_t bytes = (wide.size() + 1) * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (!memory) return false;
  auto* dest = static_cast<wchar_t*>(GlobalLock(memory));
  memcpy(dest, wide.c_str(), bytes);
  GlobalUnlock(memory);
  if (!OpenClipboardRetry(g_hwnd)) {
    GlobalFree(memory);
    return false;
  }
  EmptyClipboard();
  if (!SetClipboardData(CF_UNICODETEXT, memory)) {
    GlobalFree(memory);
    CloseClipboard();
    return false;
  }
  CloseClipboard();
  return true;
}

std::vector<uint8_t> ReadClipboardPng() {
  if (!OpenClipboardRetry(g_hwnd)) return {};
  std::vector<uint8_t> png;
  const UINT format = RegisterClipboardFormatW(L"PNG");
  if (format != 0) {
    HANDLE data = GetClipboardData(format);
    if (data) {
      const SIZE_T size = GlobalSize(data);
      const auto* bytes = static_cast<const uint8_t*>(GlobalLock(data));
      if (bytes && size > 0) png.assign(bytes, bytes + size);
      GlobalUnlock(data);
    }
  }
  if (png.empty()) {
    HANDLE data = GetClipboardData(CF_DIB);
    if (data) {
      const SIZE_T size = GlobalSize(data);
      const auto* bytes = static_cast<const BYTE*>(GlobalLock(data));
      if (bytes && size > 0) png = DibToPng(bytes, size);
      GlobalUnlock(data);
    }
  }
  CloseClipboard();
  return png;
}

bool WriteClipboardPng(const std::vector<uint8_t>& png) {
  HGLOBAL png_mem = GlobalAlloc(GMEM_MOVEABLE, png.size());
  if (!png_mem) return false;
  memcpy(GlobalLock(png_mem), png.data(), png.size());
  GlobalUnlock(png_mem);
  HGLOBAL dib = nullptr;
  const bool have_dib = PngToDib(png.data(), png.size(), &dib);
  if (!OpenClipboardRetry(g_hwnd)) {
    GlobalFree(png_mem);
    if (dib) GlobalFree(dib);
    return false;
  }
  EmptyClipboard();
  const UINT format = RegisterClipboardFormatW(L"PNG");
  bool ok = false;
  if (format != 0 && SetClipboardData(format, png_mem)) {
    ok = true;
    png_mem = nullptr;
  }
  if (have_dib && SetClipboardData(CF_DIB, dib)) {
    ok = true;
    dib = nullptr;
  }
  CloseClipboard();
  if (png_mem) GlobalFree(png_mem);
  if (dib) GlobalFree(dib);
  return ok;
}

DWORD IntegrityLevel(HANDLE token) {
  DWORD length = 0;
  GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &length);
  if (length == 0) return 0;
  std::vector<BYTE> buffer(length);
  if (!GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), length,
                           &length)) {
    return 0;
  }
  auto* label = reinterpret_cast<TOKEN_MANDATORY_LABEL*>(buffer.data());
  PUCHAR count = GetSidSubAuthorityCount(label->Label.Sid);
  if (count == nullptr || *count == 0) return 0;
  DWORD* authority =
      GetSidSubAuthority(label->Label.Sid, static_cast<DWORD>(*count - 1));
  return authority == nullptr ? 0 : *authority;
}

bool TargetIsHigherIntegrity(HWND hwnd) {
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return true;
  HANDLE token = nullptr;
  if (!OpenProcessToken(process, TOKEN_QUERY, &token)) {
    CloseHandle(process);
    return true;
  }
  HANDLE self = nullptr;
  DWORD self_level = 0;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &self)) {
    self_level = IntegrityLevel(self);
    CloseHandle(self);
  }
  const DWORD other = IntegrityLevel(token);
  CloseHandle(token);
  CloseHandle(process);
  return other > self_level && other != 0 && self_level != 0;
}

flutter::EncodableMap PasteResultMap(bool ok, const char* reason) {
  flutter::EncodableMap map;
  map[flutter::EncodableValue("ok")] = flutter::EncodableValue(ok);
  map[flutter::EncodableValue("reason")] = flutter::EncodableValue(std::string(reason));
  return map;
}

flutter::EncodableMap PasteCtrlV() {
  HWND foreground = GetForegroundWindow();
  if (!foreground) return PasteResultMap(false, "no_window");
  HWND root = GetAncestor(foreground, GA_ROOT);
  if (foreground == g_hwnd || root == g_hwnd) return PasteResultMap(false, "self");
  if (TargetIsHigherIntegrity(foreground)) return PasteResultMap(false, "elevated");
  const DWORD fg_thread = GetWindowThreadProcessId(foreground, nullptr);
  const DWORD our_thread = GetCurrentThreadId();
  AttachThreadInput(our_thread, fg_thread, TRUE);
  SetForegroundWindow(foreground);
  AttachThreadInput(our_thread, fg_thread, FALSE);
  INPUT inputs[4] = {};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = VK_CONTROL;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = 'V';
  inputs[2].type = INPUT_KEYBOARD;
  inputs[2].ki.wVk = 'V';
  inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
  inputs[3].type = INPUT_KEYBOARD;
  inputs[3].ki.wVk = VK_CONTROL;
  inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
  const UINT sent = SendInput(4, inputs, sizeof(INPUT));
  return PasteResultMap(sent == 4, sent == 4 ? "" : "sendinput");
}

void AddTrayIcon() {
  if (!g_hwnd || g_tray_added) return;
  ZeroMemory(&g_nid, sizeof(g_nid));
  g_nid.cbSize = sizeof(g_nid);
  g_nid.hWnd = g_hwnd;
  g_nid.uID = 1;
  g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  g_nid.uCallbackMessage = kTrayCallback;
  g_nid.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(101));
  const std::wstring initialTip = MenuText(
      "ClipBridge \xE6\xAD\xA3\xE5\x9C\xA8\xE5\xB1\x80\xE5\x9F\x9F\xE7\xBD\x91\xE5\xBE\x85\xE5\x91\xBD");
  wcsncpy_s(g_nid.szTip, initialTip.c_str(), _TRUNCATE);
  g_tray_added = Shell_NotifyIconW(NIM_ADD, &g_nid) == TRUE;
}

void ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  const std::wstring show =
      MenuText("\xE6\x98\xBE\xE7\xA4\xBA\xE5\xB9\xB6\xE9\x92\x89\xE4\xBD\x8F\xE9\x9D\xA2\xE6\x9D\xBF");
  const std::wstring pause = MenuText(
      g_paused ? "\xE7\xBB\xA7\xE7\xBB\xAD\xE5\x90\x8C\xE6\xAD\xA5"
               : "\xE6\x9A\x82\xE5\x81\x9C\xE5\x90\x8C\xE6\xAD\xA5");
  const std::wstring sync = MenuText(
      g_auto_sync ? "\xE5\x85\xB3\xE9\x97\xAD\xE8\x87\xAA\xE5\x8A\xA8\xE5\x90\x8C\xE6\xAD\xA5"
                  : "\xE5\xBC\x80\xE5\x90\xAF\xE8\x87\xAA\xE5\x8A\xA8\xE5\x90\x8C\xE6\xAD\xA5");
  const std::wstring startup = MenuText(
      g_launch ? "\xE5\x85\xB3\xE9\x97\xAD\xE5\xBC\x80\xE6\x9C\xBA\xE8\x87\xAA\xE5\x90\xAF"
               : "\xE5\xBC\x80\xE5\x90\xAF\xE5\xBC\x80\xE6\x9C\xBA\xE8\x87\xAA\xE5\x90\xAF");
  const std::wstring sound = MenuText(
      g_notification_sound
          ? "\xE5\x85\xB3\xE9\x97\xAD\xE6\x8F\x90\xE7\xA4\xBA\xE9\x9F\xB3"
          : "\xE5\xBC\x80\xE5\x90\xAF\xE6\x8F\x90\xE7\xA4\xBA\xE9\x9F\xB3");
  const std::wstring quit = MenuText("\xE9\x80\x80\xE5\x87\xBA");
  AppendMenuW(menu, MF_STRING, kCmdShow, show.c_str());
  AppendMenuW(menu, MF_STRING, kCmdPause, pause.c_str());
  AppendMenuW(menu, MF_STRING, kCmdSync, sync.c_str());
  AppendMenuW(menu, MF_STRING, kCmdStartup, startup.c_str());
  AppendMenuW(menu, MF_STRING, kCmdSound, sound.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdQuit, quit.c_str());
  POINT point;
  GetCursorPos(&point);
  HWND previous = GetForegroundWindow();
  SetForegroundWindow(g_hwnd);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, point.x, point.y, 0, g_hwnd, nullptr);
  DestroyMenu(menu);
  if (previous && previous != g_hwnd) SetForegroundWindow(previous);
}

void ShowMainWindow() {
  if (!g_hwnd) return;
  g_user_visible = true;
  g_hidden_for_fullscreen = false;
  ShowWindow(g_hwnd, SW_SHOWNOACTIVATE);
}

void HandleMethod(const flutter::MethodCall<flutter::EncodableValue>& call,
                  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = AsMap(call.arguments());
  const std::string& method = call.method_name();
  try {
    if (method == "getClipboardText") {
      result->Success(flutter::EncodableValue(ReadClipboardText()));
      return;
    }
    if (method == "setClipboardText") {
      const bool ok = args && WriteClipboardText(MapString(*args, "text"));
      if (!ok) {
        result->Error("clipboard", "写入文字失败");
        return;
      }
      result->Success();
      return;
    }
    if (method == "getClipboardPng") {
      auto png = ReadClipboardPng();
      if (png.empty()) {
        result->Success();
      } else {
        result->Success(flutter::EncodableValue(png));
      }
      return;
    }
    if (method == "setClipboardPng") {
      const auto* bytes = args ? MapBytes(*args, "bytes") : nullptr;
      if (bytes == nullptr || !WriteClipboardPng(*bytes)) {
        result->Error("clipboard", "写入图片失败");
        return;
      }
      result->Success();
      return;
    }
    if (method == "getClipboardSequence") {
      result->Success(flutter::EncodableValue(
          static_cast<int32_t>(GetClipboardSequenceNumber())));
      return;
    }
    if (method == "pasteCtrlV") {
      result->Success(flutter::EncodableValue(PasteCtrlV()));
      return;
    }
    if (method == "notify") {
      if (g_tray_added && args) {
        const std::wstring title = Utf8ToWide(MapString(*args, "title"));
        const std::wstring body = Utf8ToWide(MapString(*args, "body"));
        g_nid.uFlags = NIF_INFO;
        wcsncpy_s(g_nid.szInfoTitle, title.c_str(), _TRUNCATE);
        wcsncpy_s(g_nid.szInfo, body.c_str(), _TRUNCATE);
        bool play_sound = g_notification_sound;
        const auto sound_it = args->find(flutter::EncodableValue(std::string("sound")));
        if (sound_it != args->end()) {
          if (const auto* value = std::get_if<bool>(&sound_it->second)) {
            play_sound = *value;
          }
        }
        g_notification_sound = play_sound;
        g_nid.dwInfoFlags = play_sound ? NIIF_INFO : (NIIF_INFO | NIIF_NOSOUND);
        Shell_NotifyIconW(NIM_MODIFY, &g_nid);
        g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
      }
      result->Success();
      return;
    }
    if (method == "revealPath") {
      if (args) {
        const std::wstring path = Utf8ToWide(MapString(*args, "path"));
        const std::wstring params = L"/select,\"" + path + L"\"";
        ShellExecuteW(nullptr, L"open", L"explorer.exe", params.c_str(), nullptr,
                      SW_SHOWNORMAL);
      }
      result->Success();
      return;
    }
    if (method == "trayUpdate") {
      if (args) {
        g_paused = MapBool(*args, "paused");
        g_auto_sync = MapBool(*args, "autoSync");
        g_launch = MapBool(*args, "launchAtStartup");
        const auto sound_it =
            args->find(flutter::EncodableValue(std::string("notificationSound")));
        if (sound_it != args->end()) {
          if (const auto* value = std::get_if<bool>(&sound_it->second)) {
            g_notification_sound = *value;
          }
        }
        const std::wstring tip = Utf8ToWide(MapString(*args, "tooltip"));
        if (g_tray_added && !tip.empty()) {
          g_nid.uFlags = NIF_TIP;
          wcsncpy_s(g_nid.szTip, tip.c_str(), _TRUNCATE);
          Shell_NotifyIconW(NIM_MODIFY, &g_nid);
          g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        }
      }
      result->Success();
      return;
    }
    if (method == "setFrame") {
      if (g_hwnd && args) {
        const int x = MapInt(*args, "x", 0);
        const int y = MapInt(*args, "y", 0);
        const int width = MapInt(*args, "w", 32);
        const int height = MapInt(*args, "h", 88);
        bool show = true;
        const auto show_it = args->find(flutter::EncodableValue(std::string("show")));
        if (show_it != args->end()) {
          if (const auto* value = std::get_if<bool>(&show_it->second)) show = *value;
        }
        if (width > 0 && height > 0) {
          g_user_visible = show;
          SetWindowPos(g_hwnd, HWND_TOPMOST, x, y, width, height,
                       SWP_NOACTIVATE | (show ? SWP_SHOWWINDOW : SWP_HIDEWINDOW));
          // A window region clips DWM acrylic/mica, so the rounded shape is
          // Flutter's ClipRRect (transparent corners) instead of SetWindowRgn.
          if (show) ApplyDockGlass(g_hwnd);
        }
      }
      result->Success();
      return;
    }
    if (method == "getMonitors") {
      flutter::EncodableList monitors;
      EnumDisplayMonitors(
          nullptr, nullptr,
          [](HMONITOR monitor, HDC, LPRECT, LPARAM data) -> BOOL {
            auto* list = reinterpret_cast<flutter::EncodableList*>(data);
            MONITORINFO info;
            info.cbSize = sizeof(info);
            if (!GetMonitorInfo(monitor, &info)) return TRUE;
            const UINT dpi = FlutterDesktopGetDpiForMonitor(monitor);
            flutter::EncodableMap map;
            map[flutter::EncodableValue("left")] =
                flutter::EncodableValue(static_cast<int32_t>(info.rcWork.left));
            map[flutter::EncodableValue("top")] =
                flutter::EncodableValue(static_cast<int32_t>(info.rcWork.top));
            map[flutter::EncodableValue("right")] =
                flutter::EncodableValue(static_cast<int32_t>(info.rcWork.right));
            map[flutter::EncodableValue("bottom")] =
                flutter::EncodableValue(static_cast<int32_t>(info.rcWork.bottom));
            map[flutter::EncodableValue("dpi")] =
                flutter::EncodableValue(static_cast<int32_t>(dpi == 0 ? 96 : dpi));
            list->push_back(flutter::EncodableValue(map));
            return TRUE;
          },
          reinterpret_cast<LPARAM>(&monitors));
      result->Success(flutter::EncodableValue(monitors));
      return;
    }
    if (method == "allowActivate") {
      g_allow_activate = args && MapBool(*args, "allow");
      if (g_allow_activate && g_hwnd) SetForegroundWindow(g_hwnd);
      result->Success();
      return;
    }
    if (method == "setLaunchAtStartup") {
      const bool enabled = args && MapBool(*args, "enabled");
      HKEY key = nullptr;
      if (RegOpenKeyExW(HKEY_CURRENT_USER,
                        L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0,
                        KEY_SET_VALUE, &key) == ERROR_SUCCESS) {
        if (enabled) {
          wchar_t path[MAX_PATH];
          const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
          if (length > 0 && length < MAX_PATH) {
            std::wstring command = L"\"";
            command += path;
            command += L"\"";
            RegSetValueExW(key, L"ClipBridge", 0, REG_SZ,
                           reinterpret_cast<const BYTE*>(command.c_str()),
                           static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
          }
        } else {
          RegDeleteValueW(key, L"ClipBridge");
        }
        RegCloseKey(key);
      }
      g_launch = enabled;
      result->Success();
      return;
    }
    if (method == "showWindow") {
      ShowMainWindow();
      result->Success();
      return;
    }
    if (method == "hideWindow") {
      g_user_visible = false;
      if (g_hwnd) ShowWindow(g_hwnd, SW_HIDE);
      result->Success();
      return;
    }
    if (method == "quit") {
      g_force_quit = true;
      result->Success();
      if (g_hwnd == nullptr || PostMessage(g_hwnd, WM_CLOSE, 0, 0) == FALSE) {
        if (g_quit) g_quit();
      }
      return;
    }
    if (method == "startService" || method == "updateService" ||
        method == "stopService" || method == "publishFile" ||
        method == "takePendingShare") {
      result->Success();
      return;
    }
    result->NotImplemented();
  } catch (const std::exception& error) {
    result->Error("native", error.what());
  } catch (...) {
    result->Error("native", "Windows 平台调用失败");
  }
}

bool IsAtLeastWindows11() {
  using RtlGetVersionPtr = LONG(WINAPI*)(OSVERSIONINFOW*);
  const auto rtl = reinterpret_cast<RtlGetVersionPtr>(
      GetProcAddress(GetModuleHandleW(L"ntdll.dll"), "RtlGetVersion"));
  if (rtl == nullptr) return false;
  OSVERSIONINFOW info{};
  info.dwOSVersionInfoSize = sizeof(info);
  if (rtl(&info) != 0) return false;
  return info.dwMajorVersion > 10 ||
         (info.dwMajorVersion == 10 && info.dwBuildNumber >= 22000);
}

struct AccentPolicy {
  int state;
  int flags;
  int gradient;
  int animation;
};

struct CompositionAttribute {
  int attrib;
  void* data;
  size_t size;
};

using SetCompositionFn = BOOL(WINAPI*)(HWND, CompositionAttribute*);

// Flutter's ANGLE surface already has an 8-bit alpha channel. Extending the
// DWM frame lets those pixels composite over a system backdrop, so the plate
// can be translucent while text drawn on top of it stays opaque.
// WS_EX_LAYERED is intentionally not used: a constant alpha fades the text
// with the plate, and per-pixel layered updates have gone black or
// click-through with this swapchain.
void ApplyDockGlass(HWND hwnd) {
  if (!hwnd) return;
  MARGINS margins{-1, -1, -1, -1};
  DwmExtendFrameIntoClientArea(hwnd, &margins);
  BOOL host_brush = TRUE;
  DwmSetWindowAttribute(hwnd, DWMWA_USE_HOSTBACKDROPBRUSH, &host_brush, sizeof(host_brush));
  int backdrop = 3;  // DWMSBT_TRANSIENTWINDOW: acrylic, the right look for a small panel.
  const HRESULT backdrop_hr =
      DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, sizeof(backdrop));
  int corner = 2;  // DWMWCP_ROUND
  DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));
  if (IsAtLeastWindows11() && SUCCEEDED(backdrop_hr)) return;

  const auto set_composition = reinterpret_cast<SetCompositionFn>(
      GetProcAddress(GetModuleHandleW(L"user32.dll"), "SetWindowCompositionAttribute"));
  if (set_composition == nullptr) return;
  AccentPolicy policy{};
  policy.state = 4;  // ACCENT_ENABLE_ACRYLICBLURBEHIND (Windows 10 1803+)
  policy.flags = 2;
  policy.gradient = 0xCCFAF7F7;  // ABGR tint over the blur
  CompositionAttribute attribute{};
  attribute.attrib = 19;  // WCA_ACCENT_POLICY
  attribute.data = &policy;
  attribute.size = sizeof(policy);
  if (set_composition(hwnd, &attribute) == FALSE) {
    policy.state = 3;  // ACCENT_ENABLE_BLURBEHIND
    policy.gradient = 0;
    set_composition(hwnd, &attribute);
  }
}

}  // namespace

void InstallClipBridgeChannel(flutter::BinaryMessenger* messenger,
                              HWND hwnd,
                              std::function<void()> quit) {
  g_hwnd = hwnd;
  g_quit = std::move(quit);
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "app.clipbridge/platform",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        HandleMethod(call, std::move(result));
      });
  AddTrayIcon();
  ApplyDockGlass(hwnd);
  DragAcceptFiles(hwnd, TRUE);
  // 100ms is enough to notice a cursor within ~8px and a fullscreen cover,
  // without a Dart animation ticker. Each tick is a few Win32 queries.
  SetTimer(hwnd, kFullscreenTimer, 100, nullptr);
}

void RemoveClipBridgeTray() {
  if (g_hwnd) KillTimer(g_hwnd, kFullscreenTimer);
  if (!g_tray_added) return;
  Shell_NotifyIconW(NIM_DELETE, &g_nid);
  g_tray_added = false;
}

bool HandleClipBridgeMessage(HWND hwnd,
                             UINT message,
                             WPARAM wparam,
                             LPARAM lparam,
                             LRESULT* result) {
  switch (message) {
    case WM_CLOSE:
      if (!g_force_quit) {
        ShowWindow(hwnd, SW_HIDE);
        *result = 0;
        return true;
      }
      return false;
    case kTrayCallback:
      if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
        ShowMainWindow();
        InvokeTray("pin");
      } else if (lparam == WM_RBUTTONUP) {
        ShowTrayMenu();
      }
      *result = 0;
      return true;
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kCmdShow:
          ShowMainWindow();
          InvokeTray("pin");
          *result = 0;
          return true;
        case kCmdPause:
          InvokeTray("pause");
          *result = 0;
          return true;
        case kCmdSync:
          InvokeTray("autosync");
          *result = 0;
          return true;
        case kCmdStartup:
          InvokeTray("startup");
          *result = 0;
          return true;
        case kCmdSound:
          InvokeTray("sound");
          *result = 0;
          return true;
        case kCmdQuit:
          InvokeTray("quit");
          *result = 0;
          return true;
        default:
          return false;
      }
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = 8;
      info->ptMinTrackSize.y = 8;
      *result = 0;
      return true;
    }
    case WM_ERASEBKGND:
      // Let DWM show the acrylic backdrop instead of a solid GDI fill.
      *result = 1;
      return true;
    case WM_MOUSEACTIVATE:
      *result = g_allow_activate ? MA_ACTIVATE : MA_NOACTIVATE;
      return true;
    case WM_TIMER:
      if (wparam == kFullscreenTimer) {
        PollFullscreenAndMonitors();
        *result = 0;
        return true;
      }
      return false;
    case WM_DROPFILES: {
      auto drop = reinterpret_cast<HDROP>(wparam);
      const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      for (UINT index = 0; index < count; ++index) {
        wchar_t path[MAX_PATH];
        if (DragQueryFileW(drop, index, path, MAX_PATH) == 0) continue;
        if (g_channel) {
          g_channel->InvokeMethod(
              "onFileDrop",
              std::make_unique<flutter::EncodableValue>(WideToUtf8(path)));
        }
      }
      DragFinish(drop);
      *result = 0;
      return true;
    }
    default:
      return false;
  }
}
