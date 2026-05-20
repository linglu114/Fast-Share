#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

void FlutterWindow::SetFixedSize(int width, int height) {
  fixed_width_ = width;
  fixed_height_ = height;
}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // Remove resize border and maximize button for fixed-size window
  HWND hwnd = GetHandle();
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
  // Handle size constraints before Flutter — WM_GETMINMAXINFO must not
  // be intercepted by Flutter's HandleTopLevelWindowProc.
  if (message == WM_GETMINMAXINFO) {
    MINMAXINFO* mmi = reinterpret_cast<MINMAXINFO*>(lparam);
    mmi->ptMinTrackSize.x = fixed_width_;
    mmi->ptMinTrackSize.y = fixed_height_;
    mmi->ptMaxTrackSize.x = fixed_width_;
    mmi->ptMaxTrackSize.y = fixed_height_;
    mmi->ptMaxSize.x = fixed_width_;
    mmi->ptMaxSize.y = fixed_height_;
    return 0;
  }

  // Prevent Windows from changing our size during DPI transitions
  if (message == WM_DPICHANGED) {
    auto newRect = reinterpret_cast<RECT*>(lparam);
    double dpiScale = static_cast<double>(LOWORD(wparam)) / 96.0;
    SetWindowPos(hwnd, nullptr, newRect->left, newRect->top,
                 static_cast<int>(fixed_width_ * dpiScale),
                 static_cast<int>(fixed_height_ * dpiScale),
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

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
