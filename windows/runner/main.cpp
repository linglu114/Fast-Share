#include <algorithm>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);

  // 9:20 ratio window.
  // SystemParametersInfo returns physical pixels; convert to logical
  // (96 DPI) since Win32Window::Create() scales the passed size by DPI.
  HDC hdc = GetDC(nullptr);
  int dpi = GetDeviceCaps(hdc, LOGPIXELSX);
  ReleaseDC(nullptr, hdc);
  double dpiScale = dpi / 96.0;

  RECT workArea;
  int width = 400;
  int height = 889;  // 400 * 20/9 fallback
  if (::SystemParametersInfo(SPI_GETWORKAREA, 0, &workArea, 0)) {
    int logicalW = static_cast<int>((workArea.right - workArea.left) / dpiScale);
    int logicalH = static_cast<int>((workArea.bottom - workArea.top) / dpiScale);

    // Height is the primary constraint (screens are usually wider than tall).
    // At 9:20 ratio, width = height * 9/20.
    int maxH = logicalH * 90 / 100;
    int maxW = logicalW * 85 / 100;

    width = maxH * 9 / 20;
    if (width > maxW) width = maxW;
    if (width > 540) width = 540;
    if (width < 360) width = 360;

    height = width * 20 / 9;
    if (height > maxH) {
      height = maxH;
      width = height * 9 / 20;
    }
  }
  window.SetFixedSize(width, height, dpiScale);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(width, height);
  if (!window.Create(L"fastshare", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
