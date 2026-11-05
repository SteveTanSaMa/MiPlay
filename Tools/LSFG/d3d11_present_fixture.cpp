// Synthetic D3D11 presentation fixture. It never loads game files or settings.
// A white block moves ten pixels per source frame; a generated middle frame
// must lie between two adjacent source positions rather than repeat either.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <mmsystem.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <algorithm>

template <typename T> struct Ref {
  T *value = nullptr;
  ~Ref() { if (value) value->Release(); }
  T **out() { return &value; }
  T *operator->() const { return value; }
};

static bool check(HRESULT hr, const char *step) {
  if (SUCCEEDED(hr)) return true;
  std::printf("FIXTURE_FAIL step=%s hresult=%08lx\n", step, (unsigned long)hr);
  return false;
}

static bool dimension(const char *name, int fallback, int &value) {
  const char *raw = std::getenv(name);
  if (!raw || !*raw) { value = fallback; return true; }
  char *end = nullptr;
  errno = 0;
  const long parsed = std::strtol(raw, &end, 10);
  if (errno || end == raw || *end || parsed < 128 || parsed > 4096) {
    std::printf("FIXTURE_FAIL step=dimensions variable=%s expected=128..4096\n", name);
    return false;
  }
  value = static_cast<int>(parsed);
  return true;
}

static LRESULT CALLBACK window_proc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
  if (message == WM_CLOSE) { DestroyWindow(window); return 0; }
  if (message == WM_DESTROY) { PostQuitMessage(0); return 0; }
  return DefWindowProcW(window, message, wp, lp);
}

int main(int argc, char **argv) {
  std::setvbuf(stdout, nullptr, _IONBF, 0);
  // Inspect only the launch contract, never dump the full environment.
  for (const char *key : {"MTL_DEBUG_LAYER", "METAL_DEVICE_WRAPPER_TYPE", "MTL_HUD_ENABLED"}) {
    const char *value = std::getenv(key);
    std::printf("FIXTURE_ENV %s=%s\n", key, value ? value : "<unset>");
  }
  const int frame_limit = argc > 1 ? std::clamp(std::atoi(argv[1]), 60, 1800) : 240;
  const double source_fps = argc > 2 ? std::clamp(std::atof(argv[2]), 10.0, 120.0) : 30.0;
  const char *motion = std::getenv("MIPLAY_FIXTURE_MOTION");
  const bool motion_phases = motion && std::strcmp(motion, "phases") == 0;
  if (motion && std::strcmp(motion, "moving") != 0 && !motion_phases) return 24;
  if (motion_phases && frame_limit < 480) return 24;
  int width = 640, height = 360;
  if (!dimension("MIPLAY_FIXTURE_WIDTH", width, width) ||
      !dimension("MIPLAY_FIXTURE_HEIGHT", height, height)) return 23;
  HINSTANCE instance = GetModuleHandleW(nullptr);
  WNDCLASSW wc{};
  wc.lpfnWndProc = window_proc;
  wc.hInstance = instance;
  wc.lpszClassName = L"MiPlayLSFGSyntheticFixture";
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  if (!RegisterClassW(&wc)) return 10;
  RECT bounds{0, 0, width, height};
  const DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU;
  AdjustWindowRect(&bounds, style, FALSE);
  HWND window = CreateWindowW(wc.lpszClassName, L"MiPlay LSFG Synthetic D3D11 Test",
      style, CW_USEDEFAULT, CW_USEDEFAULT, bounds.right - bounds.left,
      bounds.bottom - bounds.top, nullptr, nullptr, instance, nullptr);
  if (!window) return 11;
  ShowWindow(window, SW_SHOWNORMAL);
  UpdateWindow(window);
  // Presentation-callback acceptance requires a visible drawable. Opt-in
  // keeps this tiny, automatically closing fixture above the test host; the
  // production launcher never changes a game's window ordering this way.
  if (argc > 3 && std::strcmp(argv[3], "foreground") == 0) {
    SetWindowPos(window, HWND_TOPMOST, 100, 100, 0, 0, SWP_NOSIZE | SWP_SHOWWINDOW);
    SetForegroundWindow(window);
    std::printf("FIXTURE_VISIBILITY visible=%d iconic=%d foreground=%d\n",
        IsWindowVisible(window) != FALSE, IsIconic(window) != FALSE, GetForegroundWindow() == window);
  }

  DXGI_SWAP_CHAIN_DESC swap_desc{};
  swap_desc.BufferDesc.Width = width;
  swap_desc.BufferDesc.Height = height;
  swap_desc.BufferDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  swap_desc.SampleDesc.Count = 1;
  swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
  swap_desc.BufferCount = 2;
  swap_desc.OutputWindow = window;
  swap_desc.Windowed = TRUE;
  swap_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
  Ref<ID3D11Device> device;
  Ref<ID3D11DeviceContext> context;
  Ref<IDXGISwapChain> swapchain;
  D3D_FEATURE_LEVEL feature{};
  if (!check(D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE,
      nullptr, 0, nullptr, 0, D3D11_SDK_VERSION, &swap_desc, swapchain.out(),
      device.out(), &feature, context.out()), "device_swapchain")) return 12;
  char module[MAX_PATH]{};
  GetModuleFileNameA(GetModuleHandleA("d3d11.dll"), module, MAX_PATH);
  std::printf("FIXTURE_START width=%d height=%d requested_frames=%d source_fps=%.2f feature=%04x module=%s\n",
      width, height, frame_limit, source_fps, (unsigned)feature, module);

  const char shader[] =
      "cbuffer Params:register(b0){float4 box;}"
      "float4 vs(uint id:SV_VertexID):SV_Position{"
      "float2 p[6]={float2(-1,-1),float2(-1,1),float2(1,1),"
      "float2(-1,-1),float2(1,1),float2(1,-1)};"
      "return float4(box.xy+p[id]*box.zw,0,1);}"
      "float4 ps():SV_Target{return float4(1,1,1,1);}";
  Ref<ID3DBlob> vs_code, ps_code, errors;
  if (!check(D3DCompile(shader, sizeof(shader), "synthetic", nullptr, nullptr,
      "vs", "vs_5_0", 0, 0, vs_code.out(), errors.out()), "compile_vs")) {
    if (errors.value) std::printf("%s\n", (char *)errors->GetBufferPointer());
    return 13;
  }
  if (!check(D3DCompile(shader, sizeof(shader), "synthetic", nullptr, nullptr,
      "ps", "ps_5_0", 0, 0, ps_code.out(), nullptr), "compile_ps")) return 14;
  Ref<ID3D11VertexShader> vs;
  Ref<ID3D11PixelShader> ps;
  if (!check(device->CreateVertexShader(vs_code->GetBufferPointer(), vs_code->GetBufferSize(),
      nullptr, vs.out()), "vertex_shader")) return 15;
  if (!check(device->CreatePixelShader(ps_code->GetBufferPointer(), ps_code->GetBufferSize(),
      nullptr, ps.out()), "pixel_shader")) return 16;
  Ref<ID3D11Texture2D> backbuffer;
  Ref<ID3D11RenderTargetView> rtv;
  if (!check(swapchain->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **)backbuffer.out()), "backbuffer")) return 17;
  if (!check(device->CreateRenderTargetView(backbuffer.value, nullptr, rtv.out()), "render_target")) return 18;
  D3D11_BUFFER_DESC buffer_desc{};
  buffer_desc.ByteWidth = 16;
  buffer_desc.Usage = D3D11_USAGE_DEFAULT;
  buffer_desc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  Ref<ID3D11Buffer> params;
  if (!check(device->CreateBuffer(&buffer_desc, nullptr, params.out()), "constant_buffer")) return 19;
  D3D11_RASTERIZER_DESC raster_desc{};
  raster_desc.FillMode = D3D11_FILL_SOLID;
  raster_desc.CullMode = D3D11_CULL_NONE;
  raster_desc.DepthClipEnable = TRUE;
  Ref<ID3D11RasterizerState> raster;
  if (!check(device->CreateRasterizerState(&raster_desc, raster.out()), "rasterizer")) return 20;
  D3D11_VIEWPORT viewport{0, 0, float(width), float(height), 0, 1};
  context->RSSetViewports(1, &viewport);
  context->RSSetState(raster.value);
  context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
  context->VSSetShader(vs.value, nullptr, 0);
  context->VSSetConstantBuffers(0, 1, &params.value);
  context->PSSetShader(ps.value, nullptr, 0);

  LARGE_INTEGER frequency{}, start{}, now{};
  QueryPerformanceFrequency(&frequency);
  QueryPerformanceCounter(&start);
  timeBeginPeriod(1);
  int presented = 0;
  int previous_motion_phase = -1;
  bool quit = false;
  for (int frame = 0; frame < frame_limit && !quit; ++frame) {
    LARGE_INTEGER frame_start{};
    QueryPerformanceCounter(&frame_start);
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) { quit = true; break; }
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    if (quit) break;
    const int phase_length = frame_limit / 4;
    const int motion_phase = motion_phases ? std::min(frame / phase_length, 3) : 0;
    const char *motion_name = motion_phase == 1 ? "static" : motion_phase == 3 ? "one_pixel" : "moving";
    if (motion_phase != previous_motion_phase) {
      const double elapsed = double(frame_start.QuadPart - start.QuadPart) / frequency.QuadPart;
      std::printf("FIXTURE_PHASE index=%d motion=%s frame=%d elapsed=%.6f foreground=%d iconic=%d\n",
          motion_phase, motion_name, frame, elapsed, GetForegroundWindow() == window, IsIconic(window) != FALSE);
      previous_motion_phase = motion_phase;
    }
    // All phases issue the same draw calls. Static output is bit-identical;
    // the last phase moves the block by only one pixel on alternating frames.
    const int motion_frame = motion_phase == 1 ? phase_length - 1 :
                             motion_phase >= 2 ? frame - phase_length : frame;
    const int phase = motion_frame % 100;
    const float center_x = motion_phase == 3 ? 200.0f + float(frame % 2) :
                          30.0f + float(phase <= 50 ? phase : 100 - phase) * 10.0f;
    const float box[4] = {center_x * 2 / width - 1, 0, 20.0f * 2 / width, 20.0f * 2 / height};
    context->UpdateSubresource(params.value, 0, nullptr, box, 0, 0);
    context->OMSetRenderTargets(1, &rtv.value, nullptr);
    const float background[4] = {0.015f, 0.02f, 0.025f, 1};
    context->ClearRenderTargetView(rtv.value, background);
    context->Draw(6, 0);
    if (!check(swapchain->Present(0, 0), "present")) { timeEndPeriod(1); return 21; }
    ++presented;
    QueryPerformanceCounter(&now);
    std::printf("FIXTURE_SOURCE frame=%d center_x=%.2f motion_phase=%d elapsed=%.6f\n", frame, center_x,
        motion_phase, double(now.QuadPart - start.QuadPart) / frequency.QuadPart);
    // Cap only source frames. LSFG owns the interpolation presentation cadence.
    do {
      QueryPerformanceCounter(&now);
      const double elapsed = double(now.QuadPart - frame_start.QuadPart) / frequency.QuadPart;
      if (elapsed >= 1.0 / source_fps) break;
      Sleep(1);
    } while (true);
  }
  QueryPerformanceCounter(&now);
  const double seconds = double(now.QuadPart - start.QuadPart) / frequency.QuadPart;
  context->ClearState();
  context->Flush();
  // Give asynchronous native drawable callbacks time to settle before teardown.
  Sleep(700);
  timeEndPeriod(1);
  std::printf("FIXTURE_DONE presented=%d elapsed=%.3f measured_source_fps=%.3f\n", presented, seconds, presented / seconds);
  DestroyWindow(window);
  return presented == frame_limit ? 0 : 22;
}
