/*
 * WC3 CrashProtector - Prevents crashes from invalid pointer access (x64)
 *
 * Loads as a version.dll proxy into WC3 Reforged's process.
 * Installs a Vectored Exception Handler that catches
 * access violations, skips the faulting instruction, and logs the event.
 *
 * The .def file forwards all real version.dll exports by loading
 * the original system version.dll from System32 at runtime.
 */

#define WIN32_LEAN_AND_MEAN
#include <stdio.h>
#include <windows.h>

#include "hde64.h"
#include <windows.h>
#include <shellapi.h>

#pragma comment(lib, "Shell32.lib")

void ShowBalloon(const char* title, const char* message)
{
    NOTIFYICONDATAA nid = {0};
    nid.cbSize = sizeof(NOTIFYICONDATAA);
    nid.hWnd = GetForegroundWindow();   // any window handle works
    nid.uID = 1;
    nid.uFlags = NIF_INFO;

    strcpy_s(nid.szInfoTitle, strlen(title) + 1, title);
    strcpy_s(nid.szInfo, strlen(message) + 1, message);

    nid.dwInfoFlags = NIIF_INFO; // icon type

    Shell_NotifyIconA(NIM_ADD, &nid);
    Shell_NotifyIconA(NIM_MODIFY, &nid);
}

/* ------------------------------------------------------------------ */
/*  Logging                                                           */
/* ------------------------------------------------------------------ */

static HANDLE g_logFile = INVALID_HANDLE_VALUE;
static CRITICAL_SECTION g_logLock;
static volatile LONG g_crashesSaved = 0;
static char cwd[MAX_PATH];

static void LogEvent(const char* fmt, ...) {
    char buf[512];
    va_list args;
    va_start(args, fmt);

    SYSTEMTIME st;
    GetLocalTime(&st);
    int prefix =
        sprintf_s(buf, sizeof(buf), "[%02d:%02d:%02d.%03d] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);

    int msg = vsprintf_s(buf + prefix, sizeof(buf) - prefix, fmt, args);
    va_end(args);

    EnterCriticalSection(&g_logLock);
    if (g_logFile != INVALID_HANDLE_VALUE) {
        DWORD written;
        WriteFile(g_logFile, buf, prefix + msg, &written, NULL);
        WriteFile(g_logFile, "\r\n", 2, &written, NULL);
        FlushFileBuffers(g_logFile);
    }
    LeaveCriticalSection(&g_logLock);
}

/* ------------------------------------------------------------------ */
/*  Register helpers (x64: 16 general-purpose registers)              */
/* ------------------------------------------------------------------ */

static DWORD64* GetRegFromContext(CONTEXT* ctx, BYTE regIdx) {
    switch (regIdx) {
        case 0:
            return &ctx->Rax;
        case 1:
            return &ctx->Rcx;
        case 2:
            return &ctx->Rdx;
        case 3:
            return &ctx->Rbx;
        case 4:
            return &ctx->Rsp;
        case 5:
            return &ctx->Rbp;
        case 6:
            return &ctx->Rsi;
        case 7:
            return &ctx->Rdi;
        case 8:
            return &ctx->R8;
        case 9:
            return &ctx->R9;
        case 10:
            return &ctx->R10;
        case 11:
            return &ctx->R11;
        case 12:
            return &ctx->R12;
        case 13:
            return &ctx->R13;
        case 14:
            return &ctx->R14;
        case 15:
            return &ctx->R15;
    }
    return NULL;
}

/* ------------------------------------------------------------------ */
/*  Vectored Exception Handler                                        */
/* ------------------------------------------------------------------ */

static LONG CALLBACK InvalidAccessHandler(PEXCEPTION_POINTERS ep) {
    if (ep->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION) return EXCEPTION_CONTINUE_SEARCH;

    /* ExceptionInformation[0]: 0 = read, 1 = write, 8 = DEP */
    /* ExceptionInformation[1]: the address that was accessed  */
    ULONG_PTR accessType = ep->ExceptionRecord->ExceptionInformation[0];
    ULONG_PTR addr = ep->ExceptionRecord->ExceptionInformation[1];

    /* Decode the faulting instruction */
    BYTE* rip = (BYTE*)ep->ContextRecord->Rip;
    hde64s hs;
    unsigned int instrLen = hde64_disasm(rip, &hs);

    if (instrLen == 0 || (hs.flags & F_ERROR)) return EXCEPTION_CONTINUE_SEARCH; /* Can't decode - let it crash */

    LONG count = InterlockedIncrement(&g_crashesSaved);

    /* Resolve the faulting RIP to a module name + offset */
    HMODULE hFaultMod = NULL;
    char modName[MAX_PATH] = "???";
    DWORD64 modOffset = 0;
    GetModuleHandleExA(
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        (LPCSTR)rip, &hFaultMod);
    if (hFaultMod) {
        GetModuleFileNameA(hFaultMod, modName, MAX_PATH);
        modOffset = (DWORD64)(rip - (BYTE*)hFaultMod);
    }

    LogEvent("SAVED #%ld: %s addr=0x%016llX RIP=0x%016llX instrLen=%u", count, (accessType == 0) ? "READ" : "WRITE",
             (unsigned long long)addr, (unsigned long long)rip, instrLen);
    LogEvent("  Module: %s +0x%llX", modName, (unsigned long long)modOffset);

    CONTEXT* ctx = ep->ContextRecord;
    LogEvent("  RAX=%016llX RBX=%016llX RCX=%016llX RDX=%016llX",
             ctx->Rax, ctx->Rbx, ctx->Rcx, ctx->Rdx);
    LogEvent("  RSI=%016llX RDI=%016llX RBP=%016llX RSP=%016llX",
             ctx->Rsi, ctx->Rdi, ctx->Rbp, ctx->Rsp);
    LogEvent("  R8 =%016llX R9 =%016llX R10=%016llX R11=%016llX",
             ctx->R8, ctx->R9, ctx->R10, ctx->R11);
    LogEvent("  R12=%016llX R13=%016llX R14=%016llX R15=%016llX",
             ctx->R12, ctx->R13, ctx->R14, ctx->R15);

    if (accessType == 0) {
        /* READ: zero the destination register so the game gets 0 */
        if (hs.flags & F_MODRM) {
            BYTE regIdx = (hs.modrm >> 3) & 7;
            /* REX.R extends the reg field to 4 bits (registers R8-R15) */
            if (hs.rex & 0x04) regIdx |= 8;
            DWORD64* reg = GetRegFromContext(ep->ContextRecord, regIdx);
            if (reg) *reg = 0;
        }
    }
    /* WRITE: nothing to do - just skip the instruction (discard the write) */

    /* Advance past the faulting instruction */
    ep->ContextRecord->Rip += instrLen;

    /* Show a window popup message on the 1st event, and on the 20th */
    if (count == 1 || count == 20) {
        char msg[300];
        sprintf_s(msg, sizeof(msg),
                  "CrashProtector: Saved from crashing.\n"
                  "See %s\\crash_protector.log for details.",
                  cwd);
        ShowBalloon("WC3 crash protector!", msg);
    }

    return EXCEPTION_CONTINUE_EXECUTION;
}
  /* ------------------------------------------------------------------ */
  /*  version.dll proxy - forward calls to the real system DLL          */
  /* ------------------------------------------------------------------ */

  static HMODULE g_realVersion = NULL;
  static FARPROC g_origFuncs[17];

  static void LoadRealVersion(void) {
      char path[MAX_PATH];
      GetSystemDirectoryA(path, MAX_PATH);
      strcat_s(path, MAX_PATH, "\\version.dll");
      g_realVersion = LoadLibraryA(path);

      static const char *names[17] = {
          "GetFileVersionInfoA",     "GetFileVersionInfoByHandle",
          "GetFileVersionInfoExA",   "GetFileVersionInfoExW",
          "GetFileVersionInfoSizeA", "GetFileVersionInfoSizeExA",
          "GetFileVersionInfoSizeExW","GetFileVersionInfoSizeW",
          "GetFileVersionInfoW",     "VerFindFileA",
          "VerFindFileW",            "VerInstallFileA",
          "VerInstallFileW",         "VerLanguageNameA",
          "VerLanguageNameW",        "VerQueryValueA",
          "VerQueryValueW"
      };
      for (int i = 0; i < 17; i++)
          g_origFuncs[i] = GetProcAddress(g_realVersion, names[i]);
  }

  /*
   * Generic proxy: each function takes 8 pointer-sized args and forwards them.
   * On x64 Windows the first 4 go in registers (rcx,rdx,r8,r9), rest on stack.
   * The real function ignores any extra unused args. The max any version.dll
   * function takes is 8 (VerInstallFile), so 8 covers all cases.
   */
  typedef DWORD_PTR (*proxy_fn)(DWORD_PTR,DWORD_PTR,DWORD_PTR,DWORD_PTR,
                                DWORD_PTR,DWORD_PTR,DWORD_PTR,DWORD_PTR);

  #define PROXY(name, idx)                                                \
      DWORD_PTR ng_##name(                                                \
          DWORD_PTR a, DWORD_PTR b, DWORD_PTR c, DWORD_PTR d,            \
          DWORD_PTR e, DWORD_PTR f, DWORD_PTR g, DWORD_PTR h) {          \
          return ((proxy_fn)g_origFuncs[idx])(a,b,c,d,e,f,g,h);          \
      }

  PROXY(GetFileVersionInfoA, 0)
  PROXY(GetFileVersionInfoByHandle, 1)
  PROXY(GetFileVersionInfoExA, 2)
  PROXY(GetFileVersionInfoExW, 3)
  PROXY(GetFileVersionInfoSizeA, 4)
  PROXY(GetFileVersionInfoSizeExA, 5)
  PROXY(GetFileVersionInfoSizeExW, 6)
  PROXY(GetFileVersionInfoSizeW, 7)
  PROXY(GetFileVersionInfoW, 8)
  PROXY(VerFindFileA, 9)
  PROXY(VerFindFileW, 10)
  PROXY(VerInstallFileA, 11)
  PROXY(VerInstallFileW, 12)
  PROXY(VerLanguageNameA, 13)
  PROXY(VerLanguageNameW, 14)
  PROXY(VerQueryValueA, 15)
  PROXY(VerQueryValueW, 16)

/* ------------------------------------------------------------------ */
/*  DLL Entry Point                                                   */
/* ------------------------------------------------------------------ */

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID reserved) {
    (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        LoadRealVersion();
        DisableThreadLibraryCalls(hModule);

        /* Set up logging */
        InitializeCriticalSection(&g_logLock);

        /* Log file goes next to the game exe */
        g_logFile = CreateFileA("crash_protector.log", GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);

        GetCurrentDirectoryA(MAX_PATH, cwd);
        LogEvent("=== CrashProtector loaded (PID %lu) ===", GetCurrentProcessId());

        /* Install the exception handler (priority = last/ Let other handler handle this first) */
        if (AddVectoredExceptionHandler(0, InvalidAccessHandler)) {
            LogEvent("Vectored exception handler installed successfully");
        } else {
            LogEvent("ERROR: Failed to install exception handler!");
        }

        LogEvent("Ready - monitoring for invalid pointer access violations");
    } else if (reason == DLL_PROCESS_DETACH) {
        LogEvent("=== CrashProtector unloading. Total crashes saved: %ld ===", g_crashesSaved);
        if (g_logFile != INVALID_HANDLE_VALUE) CloseHandle(g_logFile);
        DeleteCriticalSection(&g_logLock);
        if (g_realVersion) FreeLibrary(g_realVersion);
    }

    return TRUE;
}
