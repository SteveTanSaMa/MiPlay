#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
int main(void) {
  setvbuf(stdout,NULL,_IONBF,0);
  for (int i=0;i<40;i++) {
    ID3D11Device *device=NULL; ID3D11DeviceContext *context=NULL; D3D_FEATURE_LEVEL level;
    // Reuse nonzero heap contents, as a real game does. Size comes from
    // CommandQueue DWARF for this exact build; all writes precede free.
    void *blocks[256];
    for(int j=0;j<256;j++) {
      blocks[j]=malloc(0x10410);
      if(!blocks[j]) return 3;
      for(size_t k=0;k<0x10410/8;k++) ((uint64_t*)blocks[j])[k]=0x5c77656e5f657461ULL;
    }
    for(int j=255;j>=0;j--) free(blocks[j]);
    printf("MIPLAY_DEVICE_REPRO begin %d\n",i);
    HRESULT hr=D3D11CreateDevice(NULL,D3D_DRIVER_TYPE_HARDWARE,NULL,0,NULL,0,D3D11_SDK_VERSION,&device,&level,&context);
    printf("MIPLAY_DEVICE_REPRO created %d hr=%lx device=%p\n",i,(unsigned long)hr,device);
    if (FAILED(hr)) return 2;
    ID3D11DeviceContext_Flush(context); ID3D11DeviceContext_Release(context); ID3D11Device_Release(device);
    printf("MIPLAY_DEVICE_REPRO released %d\n",i);
  }
  return 0;
}
