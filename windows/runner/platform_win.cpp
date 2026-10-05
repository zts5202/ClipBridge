#include "platform_win.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

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
constexpr UINT kCmdHide = 2102;
constexpr UINT kCmdPause = 2103;
constexpr UINT kCmdQuit = 2104;

HWND g_hwnd = nullptr;
bool g_paused = false;
bool g_force_quit = false;
bool g_tray_added = false;
NOTIFYICONDATAW g_nid{};
std::function<void()> g_quit;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return L"";
  int size = MultiByteToWideChar(CP_UTF8, 0, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0);
  std::wstring out(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      out.data(), size);
  return out;
}

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
  wcscpy_s(g_nid.szTip, L"ClipBridge 正在局域网待命");
  g_tray_added = Shell_NotifyIconW(NIM_ADD, &g_nid) == TRUE;
}

void ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kCmdShow, L"显示主窗口");
  AppendMenuW(menu, MF_STRING, kCmdHide, L"隐藏主窗口");
  AppendMenuW(menu, MF_STRING, kCmdPause, g_paused ? L"继续同步" : L"暂停同步");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kCmdQuit, L"退出");
  POINT point;
  GetCursorPos(&point);
  SetForegroundWindow(g_hwnd);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON, point.x, point.y, 0, g_hwnd, nullptr);
  DestroyMenu(menu);
}

void ShowMainWindow() {
  if (!g_hwnd) return;
  ShowWindow(g_hwnd, SW_SHOW);
  if (IsIconic(g_hwnd)) ShowWindow(g_hwnd, SW_RESTORE);
  SetForegroundWindow(g_hwnd);
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
        g_nid.dwInfoFlags = NIIF_INFO;
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
    if (method == "showWindow") {
      ShowMainWindow();
      result->Success();
      return;
    }
    if (method == "hideWindow") {
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
}

void RemoveClipBridgeTray() {
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
        InvokeTray("show");
      } else if (lparam == WM_RBUTTONUP) {
        ShowTrayMenu();
      }
      *result = 0;
      return true;
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case kCmdShow:
          ShowMainWindow();
          InvokeTray("show");
          *result = 0;
          return true;
        case kCmdHide:
          ShowWindow(hwnd, SW_HIDE);
          InvokeTray("hide");
          *result = 0;
          return true;
        case kCmdPause:
          InvokeTray("pause");
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
      info->ptMinTrackSize.x = 880;
      info->ptMinTrackSize.y = 640;
      *result = 0;
      return true;
    }
    default:
      return false;
  }
}
