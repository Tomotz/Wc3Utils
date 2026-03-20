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
#include <shlobj.h>

#pragma comment(lib, "Shell32.lib")

/* ------------------------------------------------------------------ */
/*  DbgHelp – loaded dynamically so there is zero cost without a PDB  */
/* ------------------------------------------------------------------ */

#include <dbghelp.h>

typedef BOOL  (WINAPI *pfnSymInitialize)(HANDLE, PCSTR, BOOL);
typedef BOOL  (WINAPI *pfnSymCleanup)(HANDLE);
typedef BOOL  (WINAPI *pfnSymFromAddr)(HANDLE, DWORD64, PDWORD64, PSYMBOL_INFO);
typedef BOOL  (WINAPI *pfnSymGetLineFromAddr64)(HANDLE, DWORD64, PDWORD, PIMAGEHLP_LINE64);
typedef BOOL  (WINAPI *pfnStackWalk64)(DWORD, HANDLE, HANDLE, LPSTACKFRAME64,
              PVOID, PREAD_PROCESS_MEMORY_ROUTINE64,
              PFUNCTION_TABLE_ACCESS_ROUTINE64,
              PGET_MODULE_BASE_ROUTINE64, PTRANSLATE_ADDRESS_ROUTINE64);
typedef PVOID (WINAPI *pfnSymFunctionTableAccess64)(HANDLE, DWORD64);
typedef DWORD64 (WINAPI *pfnSymGetModuleBase64)(HANDLE, DWORD64);
typedef BOOL  (WINAPI *pfnSymSetContext)(HANDLE, PIMAGEHLP_STACK_FRAME, PIMAGEHLP_CONTEXT);
typedef BOOL  (WINAPI *pfnSymEnumSymbols)(HANDLE, ULONG64, PCSTR,
              PSYM_ENUMERATESYMBOLS_CALLBACK, PVOID);

static HMODULE                       g_dbgHelp;
static pfnSymInitialize              g_SymInitialize;
static pfnSymCleanup                 g_SymCleanup;
static pfnSymFromAddr                g_SymFromAddr;
static pfnSymGetLineFromAddr64       g_SymGetLineFromAddr64;
static pfnStackWalk64                g_StackWalk64;
static pfnSymFunctionTableAccess64   g_SymFunctionTableAccess64;
static pfnSymGetModuleBase64         g_SymGetModuleBase64;
static pfnSymSetContext              g_SymSetContext;
static pfnSymEnumSymbols             g_SymEnumSymbols;
static BOOL                          g_hasSymbols = FALSE;

/* Forward declaration – LogEvent is defined later with the async ring buffer */
static void LogEvent(const char* fmt, ...);

static void InitSymbols(void) {
    g_dbgHelp = LoadLibraryA("dbghelp.dll");
    if (!g_dbgHelp) return;

    g_SymInitialize            = (pfnSymInitialize)           GetProcAddress(g_dbgHelp, "SymInitialize");
    g_SymCleanup               = (pfnSymCleanup)              GetProcAddress(g_dbgHelp, "SymCleanup");
    g_SymFromAddr              = (pfnSymFromAddr)              GetProcAddress(g_dbgHelp, "SymFromAddr");
    g_SymGetLineFromAddr64     = (pfnSymGetLineFromAddr64)    GetProcAddress(g_dbgHelp, "SymGetLineFromAddr64");
    g_StackWalk64              = (pfnStackWalk64)              GetProcAddress(g_dbgHelp, "StackWalk64");
    g_SymFunctionTableAccess64 = (pfnSymFunctionTableAccess64)GetProcAddress(g_dbgHelp, "SymFunctionTableAccess64");
    g_SymGetModuleBase64       = (pfnSymGetModuleBase64)      GetProcAddress(g_dbgHelp, "SymGetModuleBase64");
    g_SymSetContext            = (pfnSymSetContext)            GetProcAddress(g_dbgHelp, "SymSetContext");
    g_SymEnumSymbols           = (pfnSymEnumSymbols)           GetProcAddress(g_dbgHelp, "SymEnumSymbols");

    if (!g_SymInitialize || !g_StackWalk64 || !g_SymFunctionTableAccess64 || !g_SymGetModuleBase64) return;

    /* Allow loading PDBs even when GUID doesn't match the PE
       (our generated PDBs may have a different GUID) */
    typedef DWORD (WINAPI *pfnSymSetOptions)(DWORD);
    pfnSymSetOptions setOpts = (pfnSymSetOptions)GetProcAddress(g_dbgHelp, "SymSetOptions");
    if (setOpts) {
        typedef DWORD (WINAPI *pfnSymGetOptions)(void);
        pfnSymGetOptions getOpts = (pfnSymGetOptions)GetProcAddress(g_dbgHelp, "SymGetOptions");
        DWORD opts = getOpts ? getOpts() : 0;
        setOpts(opts | 0x00000040 /* SYMOPT_LOAD_ANYTHING */);
    }

    HANDLE hProc = GetCurrentProcess();
    if (!g_SymInitialize(hProc, NULL, TRUE)) return;

    /* Probe: check if the main executable (wc3.exe) has symbols loaded. */
    /* The entry point is a known valid address inside the EXE. */
    HMODULE hExe = GetModuleHandleA(NULL);
    if (hExe && g_SymFromAddr) {
        /* Use the EXE's base address + entry point from the PE header */
        DWORD64 probeAddr = (DWORD64)hExe;
        IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)hExe;
        IMAGE_NT_HEADERS* nt  = (IMAGE_NT_HEADERS*)((BYTE*)hExe + dos->e_lfanew);
        probeAddr += nt->OptionalHeader.AddressOfEntryPoint;

        char buf[sizeof(SYMBOL_INFO) + MAX_SYM_NAME];
        PSYMBOL_INFO sym = (PSYMBOL_INFO)buf;
        sym->SizeOfStruct = sizeof(SYMBOL_INFO);
        sym->MaxNameLen   = MAX_SYM_NAME;
        DWORD64 disp = 0;
        if (g_SymFromAddr(hProc, probeAddr, &disp, sym))
            g_hasSymbols = TRUE;
    }
}

/* ------------------------------------------------------------------ */
/*  Parameter enumeration via SymSetContext + SymEnumSymbols            */
/* ------------------------------------------------------------------ */

/* CodeView register IDs for AMD64 (from cvconst.h / CV_HREG_e) */
#define CV_AMD64_RAX  328
#define CV_AMD64_RBX  329
#define CV_AMD64_RCX  330
#define CV_AMD64_RDX  331
#define CV_AMD64_RSI  332
#define CV_AMD64_RDI  333
#define CV_AMD64_RBP  334
#define CV_AMD64_RSP  335
#define CV_AMD64_R8   336
#define CV_AMD64_R9   337
#define CV_AMD64_R10  338
#define CV_AMD64_R11  339
#define CV_AMD64_R12  340
#define CV_AMD64_R13  341
#define CV_AMD64_R14  342
#define CV_AMD64_R15  343

typedef struct {
    CONTEXT* ctx;           /* register state for reading values */
    HANDLE   hProc;
    int      paramCount;    /* how many params we've collected so far */
    char     buf[1000];      /* accumulated "name=0xval, name=0xval, ..." */
    int      bufPos;
} EnumParamsCtx;

/* Map a CodeView register ID to the value from the CONTEXT struct */
static DWORD64 CvRegToValue(CONTEXT* ctx, ULONG cvReg) {
    switch (cvReg) {
        case CV_AMD64_RAX: return ctx->Rax;
        case CV_AMD64_RBX: return ctx->Rbx;
        case CV_AMD64_RCX: return ctx->Rcx;
        case CV_AMD64_RDX: return ctx->Rdx;
        case CV_AMD64_RSI: return ctx->Rsi;
        case CV_AMD64_RDI: return ctx->Rdi;
        case CV_AMD64_RBP: return ctx->Rbp;
        case CV_AMD64_RSP: return ctx->Rsp;
        case CV_AMD64_R8:  return ctx->R8;
        case CV_AMD64_R9:  return ctx->R9;
        case CV_AMD64_R10: return ctx->R10;
        case CV_AMD64_R11: return ctx->R11;
        case CV_AMD64_R12: return ctx->R12;
        case CV_AMD64_R13: return ctx->R13;
        case CV_AMD64_R14: return ctx->R14;
        case CV_AMD64_R15: return ctx->R15;
        default:           return 0;
    }
}

/* Safe memory read — returns FALSE if the address is not readable */
static BOOL SafeRead(HANDLE hProc, DWORD64 addr, void* out, SIZE_T size) {
    SIZE_T bytesRead = 0;
    return ReadProcessMemory(hProc, (LPCVOID)addr, out, size, &bytesRead)
           && bytesRead == size;
}

static BOOL CALLBACK EnumParamsCallback(PSYMBOL_INFO sym, ULONG symSize, PVOID userCtx) {
    (void)symSize;
    EnumParamsCtx* ep = (EnumParamsCtx*)userCtx;

    /* Only enumerate parameters, not all locals */
    if (!(sym->Flags & SYMFLAG_PARAMETER)) return TRUE; /* continue enumeration */

    if (ep->paramCount >= 16) return FALSE; /* enough params, stop */

    DWORD64 value = 0;
    BOOL    hasValue = FALSE;

    if (sym->Flags & SYMFLAG_REGISTER) {
        value = CvRegToValue(ep->ctx, sym->Register);
        hasValue = TRUE;
    } else if (sym->Flags & SYMFLAG_REGREL) {
        DWORD64 base = CvRegToValue(ep->ctx, sym->Register);
        DWORD64 addr = base + (LONG64)sym->Address;
        SIZE_T readSize = (sym->Size > 0 && sym->Size <= 8) ? sym->Size : 8;
        hasValue = SafeRead(ep->hProc, addr, &value, readSize);
    } else if (sym->Flags & SYMFLAG_FRAMEREL) {
        DWORD64 addr = ep->ctx->Rbp + (LONG64)sym->Address;
        SIZE_T readSize = (sym->Size > 0 && sym->Size <= 8) ? sym->Size : 8;
        hasValue = SafeRead(ep->hProc, addr, &value, readSize);
    }

    /* Append "name=0xvalue" or "name=?" to the buffer */
    int remaining = (int)sizeof(ep->buf) - ep->bufPos;
    if (remaining <= 1) return FALSE;

    int n;
    if (ep->paramCount > 0)
        n = sprintf_s(ep->buf + ep->bufPos, remaining, ", ");
    else
        n = 0;
    ep->bufPos += (n > 0) ? n : 0;
    remaining = (int)sizeof(ep->buf) - ep->bufPos;

    if (hasValue)
        n = sprintf_s(ep->buf + ep->bufPos, remaining, "%s=0x%llx",
                      sym->Name, (unsigned long long)value);
    else
        n = sprintf_s(ep->buf + ep->bufPos, remaining, "%s=?", sym->Name);
    ep->bufPos += (n > 0) ? n : 0;

    ep->paramCount++;
    return TRUE; /* continue enumeration */
}

/* Collect frame params into outBuf as "name=0xval, name=0xval, ..." */
static void CollectFrameParams(HANDLE hProc, CONTEXT* ctx, STACKFRAME64* frame,
                               char* outBuf, int outBufSize) {
    outBuf[0] = '\0';
    if (!g_SymSetContext || !g_SymEnumSymbols) return;

    IMAGEHLP_STACK_FRAME imgFrame;
    memset(&imgFrame, 0, sizeof(imgFrame));
    imgFrame.InstructionOffset = frame->AddrPC.Offset;
    imgFrame.FrameOffset       = frame->AddrFrame.Offset;
    imgFrame.StackOffset       = frame->AddrStack.Offset;

    if (!g_SymSetContext(hProc, &imgFrame, NULL)) return;

    EnumParamsCtx ep;
    ep.ctx        = ctx;
    ep.hProc      = hProc;
    ep.paramCount = 0;
    ep.buf[0]     = '\0';
    ep.bufPos     = 0;

    g_SymEnumSymbols(hProc, 0, "*", EnumParamsCallback, &ep);

    if (ep.bufPos > 0 && ep.bufPos < outBufSize)
        memcpy(outBuf, ep.buf, ep.bufPos + 1);
}

static void LogStackTrace(CONTEXT* ctx) {
    if (!g_hasSymbols) return;

    HANDLE hProc   = GetCurrentProcess();
    HANDLE hThread = GetCurrentThread();

    CONTEXT ctxCopy = *ctx;  /* StackWalk64 may modify the context */

    STACKFRAME64 frame;
    memset(&frame, 0, sizeof(frame));
    frame.AddrPC.Offset    = ctxCopy.Rip;
    frame.AddrPC.Mode      = AddrModeFlat;
    frame.AddrFrame.Offset = ctxCopy.Rbp;
    frame.AddrFrame.Mode   = AddrModeFlat;
    frame.AddrStack.Offset = ctxCopy.Rsp;
    frame.AddrStack.Mode   = AddrModeFlat;

    LogEvent("  --- Stack Trace (Newest first) ---");

    for (int i = 0; i < 64; i++) {
        if (!g_StackWalk64(IMAGE_FILE_MACHINE_AMD64, hProc, hThread, &frame,
                           &ctxCopy, NULL, g_SymFunctionTableAccess64,
                           g_SymGetModuleBase64, NULL))
            break;

        if (frame.AddrPC.Offset == 0) break;

        DWORD64 pc = frame.AddrPC.Offset;

        /* Resolve symbol name */
        char symBuf[sizeof(SYMBOL_INFO) + MAX_SYM_NAME];
        PSYMBOL_INFO sym = (PSYMBOL_INFO)symBuf;
        sym->SizeOfStruct = sizeof(SYMBOL_INFO);
        sym->MaxNameLen   = MAX_SYM_NAME;
        DWORD64 symDisp = 0;
        const char* funcName = "???";
        if (g_SymFromAddr && g_SymFromAddr(hProc, pc, &symDisp, sym))
            funcName = sym->Name;

        /* Collect function parameters */
        char paramsBuf[400] = "";
        CollectFrameParams(hProc, &ctxCopy, &frame, paramsBuf, sizeof(paramsBuf));

        /* Resolve source file + line, output in gdb format */
        IMAGEHLP_LINE64 line;
        line.SizeOfStruct = sizeof(line);
        DWORD lineDisp = 0;
        if (g_SymGetLineFromAddr64 && g_SymGetLineFromAddr64(hProc, pc, &lineDisp, &line))
            LogEvent("  #0x%x  0x%llx in %s (%s) at %s:0x%lx", i, (unsigned long long)pc,
                     funcName, paramsBuf, line.FileName, line.LineNumber);
        else
            LogEvent("  #0x%x  0x%llx in %s (%s)", i, (unsigned long long)pc,
                     funcName, paramsBuf);
    }
}

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
/*  Async Logging                                                     */
/* ------------------------------------------------------------------ */

static HANDLE g_logFile = INVALID_HANDLE_VALUE;
static HANDLE g_logFileArchive = INVALID_HANDLE_VALUE;
static char g_archivePath[MAX_PATH];
static volatile LONG g_crashesSaved = 0;
static char g_logDir[MAX_PATH];

/* Lock-free ring buffer for async log writes */
#define LOG_RING_SIZE 256          /* must be power of 2 */
#define LOG_ENTRY_SIZE 512

static char g_logRing[LOG_RING_SIZE][LOG_ENTRY_SIZE];
static volatile LONG g_logHead = 0;  /* next slot to write */
static volatile LONG g_logTail = 0;  /* next slot to read  */
static HANDLE g_logEvent = NULL;     /* signals writer thread */
static HANDLE g_logThread = NULL;
static volatile LONG g_logShutdown = 0;

/* Open the archive log and copy the current crash_protector.log contents into it */
static void OpenArchiveLog(void) {
    g_logFileArchive = CreateFileA(g_archivePath, GENERIC_WRITE, FILE_SHARE_READ,
                                   NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (g_logFileArchive == INVALID_HANDLE_VALUE) return;

    /* Replay crash_protector.log contents written so far */
    if (g_logFile != INVALID_HANDLE_VALUE) {
        FlushFileBuffers(g_logFile);
        char mainLogPath[MAX_PATH];
        sprintf_s(mainLogPath, MAX_PATH, "%s\\crash_protector.log", g_logDir);
        HANDLE hRead = CreateFileA(mainLogPath, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                   NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hRead != INVALID_HANDLE_VALUE) {
            char buf[4096];
            DWORD bytesRead;
            while (ReadFile(hRead, buf, sizeof(buf), &bytesRead, NULL) && bytesRead > 0) {
                DWORD written;
                WriteFile(g_logFileArchive, buf, bytesRead, &written, NULL);
            }
            CloseHandle(hRead);
        }
    }
}

static void WriteToLog(HANDLE hFile, const char* entry, DWORD len) {
    DWORD written;
    WriteFile(hFile, entry, len, &written, NULL);
    WriteFile(hFile, "\r\n", 2, &written, NULL);
}

static DWORD WINAPI LogWriterThread(LPVOID param) {
    (void)param;
    while (!g_logShutdown) {
        WaitForSingleObject(g_logEvent, 500); /* wake on signal or periodic flush */

        /* Create archive log once we hit 2 crashes */
        if (g_logFileArchive == INVALID_HANDLE_VALUE && g_crashesSaved >= 2)
            OpenArchiveLog();

        while (g_logTail != g_logHead) {
            LONG slot = g_logTail & (LOG_RING_SIZE - 1);
            DWORD len = (DWORD)strlen(g_logRing[slot]);
            if (g_logFile != INVALID_HANDLE_VALUE)
                WriteToLog(g_logFile, g_logRing[slot], len);
            if (g_logFileArchive != INVALID_HANDLE_VALUE)
                WriteToLog(g_logFileArchive, g_logRing[slot], len);
            InterlockedIncrement(&g_logTail);
        }

        if (g_logFile != INVALID_HANDLE_VALUE)
            FlushFileBuffers(g_logFile);
        if (g_logFileArchive != INVALID_HANDLE_VALUE)
            FlushFileBuffers(g_logFileArchive);
    }

    return 0;
}

static void LogEvent(const char* fmt, ...) {
    /* Grab a slot - if ring is full, drop the message (never block the game) */
    LONG head, next;
    do {
        head = g_logHead;
        next = head + 1;
        if ((next - g_logTail) >= LOG_RING_SIZE)
            return; /* ring full, drop message */
    } while (InterlockedCompareExchange(&g_logHead, next, head) != head);

    LONG slot = head & (LOG_RING_SIZE - 1);

    SYSTEMTIME st;
    GetLocalTime(&st);
    int prefix = sprintf_s(g_logRing[slot], LOG_ENTRY_SIZE,
        "[%02d:%02d:%02d.%03d] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);

    va_list args;
    va_start(args, fmt);
    vsprintf_s(g_logRing[slot] + prefix, LOG_ENTRY_SIZE - prefix, fmt, args);
    va_end(args);

    /* Signal the writer thread */
    if (g_logEvent) SetEvent(g_logEvent);
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
    BOOL baleEarly = FALSE;

    /* ExceptionInformation[0]: 0 = read, 1 = write, 8 = DEP */
    /* ExceptionInformation[1]: the address that was accessed  */
    ULONG_PTR accessType = ep->ExceptionRecord->ExceptionInformation[0];
    ULONG_PTR addr = ep->ExceptionRecord->ExceptionInformation[1];
    CONTEXT* ctx = ep->ContextRecord;

    const char* accessName = (accessType == 8) ? "EXECUTE" : (accessType == 0) ? "READ" : "WRITE";

    LONG count = InterlockedIncrement(&g_crashesSaved);

    LogEvent("ACCESS_VIOLATION #%ld: %s addr=0x%016llX RIP=0x%016llX", count, accessName, (unsigned long long)addr, (unsigned long long)ctx->Rip);

    hde64s hs;
    unsigned int instrLen = 0;
    DWORD64 retAddr = 0;

    /* Recovery */
    if (accessType == 8) {
        /* EXECUTE: simulate ret if return address is inside a known module */
        if (!SafeRead(GetCurrentProcess(), ctx->Rsp, &retAddr, sizeof(retAddr)) || retAddr == 0) {
            LogEvent("  Recovery: no valid return address on stack, cannot recover");
            baleEarly = TRUE;
        } else {
            HMODULE hRetMod = NULL;
            GetModuleHandleExA(
                GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                (LPCSTR)(ULONG_PTR)retAddr, &hRetMod);
            if (!hRetMod) {
                LogEvent("  Recovery: return address 0x%016llX not inside any module, cannot recover",
                        (unsigned long long)retAddr);
                baleEarly = TRUE;
            } else {
                char retModName[MAX_PATH];
                GetModuleFileNameA(hRetMod, retModName, MAX_PATH);
                LogEvent("  Recovery: simulating ret to 0x%016llX (%s +0x%llX)",
                        (unsigned long long)retAddr, retModName, (unsigned long long)(retAddr - (DWORD64)hRetMod));
            }
        }
    } else {
        /* For read/write, decode the faulting instruction first (bail early if we can't) */
        instrLen = hde64_disasm((BYTE*)ctx->Rip, &hs);
        if (instrLen == 0 || (hs.flags & F_ERROR))
        {
            LogEvent("  Failed to decode instruction at RIP, cannot analyze or recover");
            baleEarly = TRUE;
        }

        /* Resolve RIP module (meaningful for read/write; RIP is outside any module for execute) */
        HMODULE hFaultMod = NULL;
        char modName[MAX_PATH] = "???";
        DWORD64 modOffset = 0;
        GetModuleHandleExA(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            (LPCSTR)(ULONG_PTR)ctx->Rip, &hFaultMod);
        if (hFaultMod) {
            GetModuleFileNameA(hFaultMod, modName, MAX_PATH);
            modOffset = ctx->Rip - (DWORD64)hFaultMod;
            LogEvent("  Module: %s +0x%llX instrLen=%u", modName, (unsigned long long)modOffset, instrLen);
        }
    }

    /* Registers + stack trace (shared) */
    LogEvent("  RAX=%016llX RBX=%016llX RCX=%016llX RDX=%016llX RSI=%016llX RDI=%016llX RBP=%016llX RSP=%016llX R8 =%016llX R9 =%016llX R10=%016llX R11=%016llX R12=%016llX R13=%016llX R14=%016llX R15=%016llX", ctx->Rax, ctx->Rbx, ctx->Rcx, ctx->Rdx, ctx->Rsi, ctx->Rdi, ctx->Rbp, ctx->Rsp, ctx->R8, ctx->R9, ctx->R10, ctx->R11, ctx->R12, ctx->R13, ctx->R14, ctx->R15);
    LogStackTrace(ctx);

    if (baleEarly) {
        return EXCEPTION_CONTINUE_SEARCH;
    }

    // Try fixing what is wrong
    if (accessType == 8) {
        // Jump to return address, and fix stack.
        ctx->Rip = retAddr;
        ctx->Rsp += 8;
        ctx->Rax = 0;
    } else {
        if (accessType == 0) {
            /* READ: zero the destination register so the game gets 0 */
            if (hs.flags & F_MODRM) {
                BYTE regIdx = (hs.modrm >> 3) & 7;
                if (hs.rex & 0x04) regIdx |= 8;
                DWORD64* reg = GetRegFromContext(ctx, regIdx);
                if (reg) *reg = 0;
            }
        }
        // Skip current instruction
        ctx->Rip += instrLen;
    }

    /* Show a window popup message on the 2nd event, and on the 20th */
    if (count == 2 || count == 20) {
        char msg[300];
        sprintf_s(msg, sizeof(msg),
                  "CrashProtector: Saved from crashing.\n"
                  "See %s for details.",
                  g_logDir);
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

        /* Build log dir and both log paths under Documents\CrashProtector */
        {
            char docsPath[MAX_PATH];
            char logPath[MAX_PATH];
            if (FAILED(SHGetFolderPathA(NULL, CSIDL_PERSONAL, NULL, 0, docsPath)))
                strcpy_s(docsPath, MAX_PATH, ".");
            sprintf_s(g_logDir, MAX_PATH, "%s\\CrashProtector", docsPath);
            CreateDirectoryA(g_logDir, NULL); /* ok if already exists */

            sprintf_s(logPath, MAX_PATH, "%s\\crash_protector.log", g_logDir);
            g_logFile = CreateFileA(logPath, GENERIC_WRITE, FILE_SHARE_READ,
                                    NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);

            SYSTEMTIME st;
            GetLocalTime(&st);
            sprintf_s(g_archivePath, MAX_PATH, "%s\\crash_%04d-%02d-%02d_%02d-%02d-%02d.log",
                      g_logDir, st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
        }
        g_logEvent = CreateEventA(NULL, FALSE, FALSE, NULL);
        g_logThread = CreateThread(NULL, 0, LogWriterThread, NULL, 0, NULL);
        InitSymbols();
        LogEvent("=== CrashProtector loaded (PID %lu, symbols=%s) ===",
                 GetCurrentProcessId(), g_hasSymbols ? "YES" : "NO");

        /* Install the exception handler (priority = last/ Let other handler handle this first) */
        if (AddVectoredExceptionHandler(0, InvalidAccessHandler)) {
            LogEvent("Vectored exception handler installed successfully");
        } else {
            LogEvent("ERROR: Failed to install exception handler!");
        }

        LogEvent("Ready - monitoring for invalid pointer access violations");
    } else if (reason == DLL_PROCESS_DETACH) {
        LogEvent("=== CrashProtector unloading. Total crashes reported: %ld ===", g_crashesSaved);

        /* Shut down the log writer thread (give it 2s to drain) */
        InterlockedExchange(&g_logShutdown, 1);
        if (g_logEvent) SetEvent(g_logEvent);
        if (g_logThread) {
            WaitForSingleObject(g_logThread, 2000);
            CloseHandle(g_logThread);
        }
        if (g_logEvent) CloseHandle(g_logEvent);
        if (g_logFile != INVALID_HANDLE_VALUE) CloseHandle(g_logFile);
        if (g_logFileArchive != INVALID_HANDLE_VALUE) CloseHandle(g_logFileArchive);
        if (g_hasSymbols && g_SymCleanup) g_SymCleanup(GetCurrentProcess());
        if (g_dbgHelp) FreeLibrary(g_dbgHelp);
        if (g_realVersion) FreeLibrary(g_realVersion);
    }

    return TRUE;
}
