#include "../crash_protector.c"
#include <assert.h>
int main(void) {
    char path[MAX_PATH]; GetModuleFileNameA(NULL, path, MAX_PATH);
    *strrchr(path, 0x5c) = 0;
    strcpy_s(g_logDir, MAX_PATH, path);
    BYTE* memory = (BYTE*)VirtualAlloc(NULL, 8192, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    assert(memory); memset(memory, 0x42, 8192);
    DWORD prior; assert(VirtualProtect(memory+4096, 4096, PAGE_NOACCESS, &prior));
    g_captureImage = (BYTE*)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, 8704);
    assert(g_captureImage);
    g_captureBase=memory; g_captureRva=0; g_captureOffset=512; g_captureSize=8192; g_captureFileSize=8704;
    g_captureState=1; g_captureReady=1;
    FillCodeCapture("startup",0);
    assert(g_captureFailures==1 && g_captureValid[0] && !g_captureValid[1]);
    FlushCodeCapture(); assert(g_captureHasBaseline && g_captureState==0);
    memory[16]=0x55;
    CaptureCrashCode((DWORD64)(memory+16));
    assert(g_captureState==2 && g_captureImage[512+16]==0x55);
    memory[16]=0x66;
    CaptureCrashCode((DWORD64)(memory+16));
    assert(g_captureImage[512+16]==0x55 && g_captureSequence==2);
    FlushCodeCapture(); assert(g_captureState==0);
    char meta[MAX_PATH]; sprintf_s(meta,MAX_PATH,"%s\\wc3_capture_%lu_crash_2_%llu.exe.json",g_logDir,GetCurrentProcessId(),(unsigned long long)g_captureTick);
    FILE* file=NULL; assert(fopen_s(&file,meta,"rb")==0);
    char contents[2048]={0}; fread(contents,1,sizeof(contents)-1,file); fclose(file);
    assert(strstr(contents,"\"unreadable_pages\": 1") && strstr(contents,"\"changed_pages\": 1"));
    assert(VirtualProtect(memory+4096,4096,PAGE_READWRITE,&prior));
    char request[MAX_PATH]; sprintf_s(request,MAX_PATH,"%s\\capture-%lu.request",g_logDir,GetCurrentProcessId());
    assert(fopen_s(&file,request,"wb")==0); fclose(file);
    ServiceCodeCaptureRequest(); assert(g_captureState==2 && g_captureFailures==0);
    assert(g_captureImage[512+16]==0x66 && g_captureSequence==3);
    FlushCodeCapture();
    VirtualFree(memory,0,MEM_RELEASE); HeapFree(GetProcessHeap(),0,g_captureImage);
    puts("PASS: first-crash bytes frozen before recovery; unreadable pages reported; baseline changes detected; manual capture works.");
    return 0;
}
