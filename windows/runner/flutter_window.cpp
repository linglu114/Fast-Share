#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

void LogWinMsg(const wchar_t* msg, int v1, int v2) {
  wchar_t buf[256];
  _snwprintf_s(buf, _TRUNCATE, L"[fastshare] %s v1=%d v2=%d\n", msg, v1, v2);
  OutputDebugStringW(buf);
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

void FlutterWindow::SetFixedSize(int width, int height, double dpiScale) {
  fixed_width_ = width;
  fixed_height_ = height;
  dpi_scale_ = dpiScale;
  LogWinMsg(L"SetFixedSize", width, height);
}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  HWND hwnd = GetHandle();

  // Remove resize border and maximize button for fixed-size window
  LONG_PTR style = GetWindowLongPtr(hwnd, GWL_STYLE);
  style &= ~(WS_THICKFRAME | WS_MAXIMIZEBOX);
  SetWindowLongPtr(hwnd, GWL_STYLE, style);
  // Recalculate the non-client area after style change
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOZORDER | SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED);

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // WM_GETMINMAXINFO is sent during window creation and when the user
  // interacts with sizing edges.  Values are in physical pixels for
  // per-monitor DPI-aware windows.
  if (message == WM_GETMINMAXINFO) {
    MINMAXINFO* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
    int w = static_cast<int>(fixed_width_ * dpi_scale_);
    int h = static_cast<int>(fixed_height_ * dpi_scale_);
    mmi->ptMinTrackSize.x = w;
    mmi->ptMinTrackSize.y = h;
    mmi->ptMaxTrackSize.x = w;
    mmi->ptMaxTrackSize.y = h;
    mmi->ptMaxSize.x = w;
    mmi->ptMaxSize.y = h;
    LogWinMsg(L"WM_GETMINMAXINFO", w, h);
    return 0;
  }

  if (message == WM_DPICHANGED) {
    dpi_scale_ = static_cast<double>(LOWORD(wparam)) / 96.0;
    int w = static_cast<int>(fixed_width_ * dpi_scale_);
    int h = static_cast<int>(fixed_height_ * dpi_scale_);
    LogWinMsg(L"WM_DPICHANGED", w, LOWORD(wparam));
    auto* newRect = reinterpret_cast<RECT*>(lparam);
    SetWindowPos(hwnd, nullptr, newRect->left, newRect->top, w, h,
                 SWP_NOZORDER | SWP_NOACTIVATE);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // Force fixed size AFTER Flutter has processed the message. If we do this
  // before Flutter, it can overwrite our values. WM_WINDOWPOSCHANGING fires
  // on every move/drag/resize — we lock cx/cy and return 0.
  if (message == WM_WINDOWPOSCHANGING) {
    auto* wp = reinterpret_cast<WINDOWPOS*>(lparam);
    wp->cx = static_cast<int>(fixed_width_ * dpi_scale_);
    wp->cy = static_cast<int>(fixed_height_ * dpi_scale_);
    wp->flags &= ~SWP_NOSIZE;
    LogWinMsg(L"WM_WINDOWPOSCHANGING force", wp->cx, wp->cy);
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
