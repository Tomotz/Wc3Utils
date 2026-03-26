/*
 * WC3 CrashProtector - Prevents crashes from invalid pointer access (x64)
 *
 * Loads as a version.dll proxy into WC3 Reforged's process.
 * Uses an Unhandled Exception Filter (UEF) to catch only truly unhandled
 * access violations — the game's own SEH handlers run first, so intentional
 * AVs (page probes, etc.) are left alone.
 *
 * The .def file forwards all real version.dll exports by loading
 * the original system version.dll from System32 at runtime.
 */

#define WIN32_LEAN_AND_MEAN
#define VERSION  "v1.1.2"

#include <stdio.h>
#include <windows.h>

#include "hde64.h"
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>

#pragma comment(lib, "Shell32.lib")

/*  DbgHelp – loaded dynamically so there is zero cost without a PDB  */
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
static BOOL                          g_hasSymbols = FALSE; /* TRUE if PDB or txt symbols loaded */
static CRITICAL_SECTION              g_dbgHelpLock;

/* ------------------------------------------------------------------ */
/*  symbols.txt fallback symbol table                                  */
/* ------------------------------------------------------------------ */

typedef struct {
    DWORD nameOff;      /* offset into g_symStrings */
    BYTE  storage;      /* 0=REG, 1=STACK, 2=UNKNOWN */
    BYTE  pad;
    WORD  regIdx;       /* CV register ID for REG storage (AMD64 IDs > 255) */
    WORD  stackOff;     /* RSP offset for STACK storage */
    WORD  pad2;
} TxtParam;             /* 12 bytes */

typedef struct {
    DWORD rva;
    DWORD codeSize;
    DWORD nameOff;      /* offset into g_symStrings */
    WORD  paramCount;
    WORD  paramStart;   /* index into g_txtParams[] */
} TxtFunc;              /* 16 bytes */

static TxtFunc*  g_txtFuncs    = NULL;
static DWORD     g_txtFuncCount = 0;
static TxtParam* g_txtParams   = NULL;
static DWORD     g_txtParamCount = 0;
static char*     g_symStrings  = NULL;

static void InitTrace(const char* msg);  /* defined after g_logFile */

static void InitSymbols(void) {
    g_dbgHelp = LoadLibraryA("dbghelp.dll");
    if (!g_dbgHelp) { InitTrace("FAILED to load dbghelp.dll"); return; }

    g_SymInitialize            = (pfnSymInitialize)           GetProcAddress(g_dbgHelp, "SymInitialize");
    g_SymCleanup               = (pfnSymCleanup)              GetProcAddress(g_dbgHelp, "SymCleanup");
    g_SymFromAddr              = (pfnSymFromAddr)              GetProcAddress(g_dbgHelp, "SymFromAddr");
    g_SymGetLineFromAddr64     = (pfnSymGetLineFromAddr64)    GetProcAddress(g_dbgHelp, "SymGetLineFromAddr64");
    g_StackWalk64              = (pfnStackWalk64)              GetProcAddress(g_dbgHelp, "StackWalk64");
    g_SymFunctionTableAccess64 = (pfnSymFunctionTableAccess64)GetProcAddress(g_dbgHelp, "SymFunctionTableAccess64");
    g_SymGetModuleBase64       = (pfnSymGetModuleBase64)      GetProcAddress(g_dbgHelp, "SymGetModuleBase64");
    g_SymSetContext            = (pfnSymSetContext)            GetProcAddress(g_dbgHelp, "SymSetContext");
    g_SymEnumSymbols           = (pfnSymEnumSymbols)           GetProcAddress(g_dbgHelp, "SymEnumSymbols");

    if (!g_SymInitialize || !g_StackWalk64 || !g_SymFunctionTableAccess64 || !g_SymGetModuleBase64) {
        InitTrace("missing required dbghelp exports");
        return;
    }

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

    /* Build search path from the EXE's directory so DbgHelp can find
       PDBs placed next to the game executable (the working directory
       is often somewhere else when launched via Battle.net). */
    char searchPath[MAX_PATH] = {0};
    if (GetModuleFileNameA(NULL, searchPath, MAX_PATH)) {
        char *slash = strrchr(searchPath, '\\');
        if (slash) *slash = '\0';
    }

    if (!g_SymInitialize(hProc, searchPath[0] ? searchPath : NULL, TRUE)) {
        char msg[128];
        sprintf_s(msg, sizeof(msg), "SymInitialize FAILED err=%lu", GetLastError());
        InitTrace(msg);
        return;
    }
}

/* ------------------------------------------------------------------ */
/*  Async Logging                                                     */
/* ------------------------------------------------------------------ */

static HANDLE g_logFile = INVALID_HANDLE_VALUE;
static HANDLE g_logFileArchive = INVALID_HANDLE_VALUE;
static char g_archivePath[MAX_PATH];
static volatile LONG g_crashesSaved = 0;
static volatile LONG g_hangDetected = 0;

/* Crash dedup: suppress verbose logging for repeated crash locations */
#define CRASH_DEDUP_SIZE 32
#define CRASH_VERBOSE_LIMIT 100
#define CRASH_DEDUP_REPORT_INTERVAL 100

typedef struct {
    DWORD64 rip;
    LONG firstCrashNum;
} CrashDedupEntry;

static CrashDedupEntry g_crashDedup[CRASH_DEDUP_SIZE];
static LONG g_crashDedupCount = 0;
static volatile LONG g_crashDedupSkipped = 0;
static char g_logDir[MAX_PATH];

/* Write a debug trace directly to the log file (synchronous, for init diagnostics) */
static void InitTrace(const char* msg) {
    if (g_logFile != INVALID_HANDLE_VALUE) {
        DWORD written;
        WriteFile(g_logFile, "[InitSymbols] ", 14, &written, NULL);
        WriteFile(g_logFile, msg, (DWORD)strlen(msg), &written, NULL);
        WriteFile(g_logFile, "\r\n", 2, &written, NULL);
        FlushFileBuffers(g_logFile);
    }
}

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

        /* Create archive log on first crash or hang */
        if (g_logFileArchive == INVALID_HANDLE_VALUE && (g_crashesSaved >= 1 || g_hangDetected))
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

static void LogEventV(BOOL withTime, const char* fmt, va_list args) {
    /* Grab a slot - if ring is full, drop the message (never block the game) */
    LONG head, next;
    do {
        head = g_logHead;
        next = head + 1;
        if ((next - g_logTail) >= LOG_RING_SIZE)
            return; /* ring full, drop message */
    } while (InterlockedCompareExchange(&g_logHead, next, head) != head);

    LONG slot = head & (LOG_RING_SIZE - 1);

    int prefix = 0;
    if (withTime) {
        SYSTEMTIME st;
        GetLocalTime(&st);
        prefix = sprintf_s(g_logRing[slot], LOG_ENTRY_SIZE,
            "[%02d:%02d:%02d.%03d] ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    }

    vsprintf_s(g_logRing[slot] + prefix, LOG_ENTRY_SIZE - prefix, fmt, args);

    /* Signal the writer thread */
    if (g_logEvent) SetEvent(g_logEvent);
}

/* Log with timestamp (first message in a batch) */
static void LogWithTimeStamp(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogEventV(TRUE, fmt, args);
    va_end(args);
}

/* Log without timestamp (continuation lines in a batch) */
static void LogLine(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    LogEventV(FALSE, fmt, args);
    va_end(args);
}

static void ShowBalloon(const char* title, const char* message)
{
    NOTIFYICONDATAA nid = {0};
    nid.cbSize = sizeof(NOTIFYICONDATAA);
    nid.hWnd = GetForegroundWindow();   // any window handle works
    nid.uID = 1;
    nid.uFlags = NIF_INFO;

    strcpy_s(nid.szInfoTitle, sizeof(nid.szInfoTitle), title);
    strcpy_s(nid.szInfo, sizeof(nid.szInfo), message);

    nid.dwInfoFlags = NIIF_INFO; // icon type

    Shell_NotifyIconA(NIM_ADD, &nid);
    Shell_NotifyIconA(NIM_MODIFY, &nid);
}

/* Pending balloon — crash handler sets these, watchdog thread shows them.
   Shell_NotifyIconA uses COM/IPC and is NOT safe to call from an exception filter. */
static char g_pendingBalloonTitle[128] = "";
static char g_pendingBalloonMsg[256] = "";
static volatile LONG g_pendingBalloon = 0;

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

/* ------------------------------------------------------------------ */
/*  symbols.txt loader + lookup                                        */
/* ------------------------------------------------------------------ */

/* Map register name string to CV register ID */
static ULONG TxtRegNameToCV(const char* name) {
    if (strcmp(name, "RAX") == 0) return CV_AMD64_RAX;
    if (strcmp(name, "RBX") == 0) return CV_AMD64_RBX;
    if (strcmp(name, "RCX") == 0) return CV_AMD64_RCX;
    if (strcmp(name, "RDX") == 0) return CV_AMD64_RDX;
    if (strcmp(name, "RSI") == 0) return CV_AMD64_RSI;
    if (strcmp(name, "RDI") == 0) return CV_AMD64_RDI;
    if (strcmp(name, "RBP") == 0) return CV_AMD64_RBP;
    if (strcmp(name, "RSP") == 0) return CV_AMD64_RSP;
    if (strcmp(name, "R8")  == 0) return CV_AMD64_R8;
    if (strcmp(name, "R9")  == 0) return CV_AMD64_R9;
    if (strcmp(name, "R10") == 0) return CV_AMD64_R10;
    if (strcmp(name, "R11") == 0) return CV_AMD64_R11;
    if (strcmp(name, "R12") == 0) return CV_AMD64_R12;
    if (strcmp(name, "R13") == 0) return CV_AMD64_R13;
    if (strcmp(name, "R14") == 0) return CV_AMD64_R14;
    if (strcmp(name, "R15") == 0) return CV_AMD64_R15;
    /* raw "regN" format from quick_match */
    if (name[0] == 'r' && name[1] == 'e' && name[2] == 'g')
        return (ULONG)atoi(name + 3);
    return 0;
}

static int TxtFuncCmpRva(const void* a, const void* b) {
    DWORD ra = ((const TxtFunc*)a)->rva;
    DWORD rb = ((const TxtFunc*)b)->rva;
    return (ra > rb) - (ra < rb);
}

/* Find function containing the given RVA via binary search */
static const TxtFunc* TxtFindFunc(DWORD rva) {
    if (!g_txtFuncs || g_txtFuncCount == 0) return NULL;
    DWORD lo = 0, hi = g_txtFuncCount;
    while (lo < hi) {
        DWORD mid = lo + (hi - lo) / 2;
        if (g_txtFuncs[mid].rva <= rva)
            lo = mid + 1;
        else
            hi = mid;
    }
    if (lo == 0) return NULL;
    const TxtFunc* f = &g_txtFuncs[lo - 1];
    if (rva < f->rva + f->codeSize)
        return f;
    return NULL;
}

/* Collect parameters for a txt-symbol function */
static void TxtCollectFrameParams(const TxtFunc* func, CONTEXT* ctx,
                                   HANDLE hProc, DWORD64 frameRsp,
                                   char* outBuf, int outBufSize) {
    outBuf[0] = '\0';
    if (func->paramCount == 0) return;
    int pos = 0;
    for (WORD i = 0; i < func->paramCount && i < 16; i++) {
        const TxtParam* p = &g_txtParams[func->paramStart + i];
        const char* pname = g_symStrings + p->nameOff;

        DWORD64 value = 0;
        BOOL hasValue = FALSE;
        if (p->storage == 0) { /* REG */
            value = CvRegToValue(ctx, p->regIdx);
            hasValue = TRUE;
        } else if (p->storage == 1) { /* STACK */
            hasValue = SafeRead(hProc, frameRsp + p->stackOff, &value, 8);
        }

        int remaining = outBufSize - pos;
        if (remaining <= 1) break;
        int n = 0;
        if (i > 0) {
            n = sprintf_s(outBuf + pos, remaining, ", ");
            pos += (n > 0) ? n : 0;
            remaining = outBufSize - pos;
        }
        if (hasValue)
            n = sprintf_s(outBuf + pos, remaining, "%s=0x%llx", pname, (unsigned long long)value);
        else
            n = sprintf_s(outBuf + pos, remaining, "%s=?", pname);
        pos += (n > 0) ? n : 0;
    }
}

static void LoadSymbolsTxt(void) {
    /* Build path: exe directory + \symbols.txt */
    char txtPath[MAX_PATH];
    if (!GetModuleFileNameA(NULL, txtPath, MAX_PATH)) return;
    char* slash = strrchr(txtPath, '\\');
    if (!slash) return;
    strcpy_s(slash + 1, MAX_PATH - (slash + 1 - txtPath), "symbols.txt");

    HANDLE hFile = CreateFileA(txtPath, GENERIC_READ, FILE_SHARE_READ,
                               NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hFile == INVALID_HANDLE_VALUE) {
        InitTrace("symbols.txt not found");
        return;
    }

    DWORD fileSize = GetFileSize(hFile, NULL);
    if (fileSize == 0 || fileSize == INVALID_FILE_SIZE) {
        CloseHandle(hFile);
        return;
    }

    char* rawBuf = (char*)HeapAlloc(GetProcessHeap(), 0, fileSize + 1);
    if (!rawBuf) { CloseHandle(hFile); return; }
    DWORD bytesRead;
    if (!ReadFile(hFile, rawBuf, fileSize, &bytesRead, NULL) || bytesRead == 0) {
        HeapFree(GetProcessHeap(), 0, rawBuf);
        CloseHandle(hFile);
        return;
    }
    CloseHandle(hFile);
    rawBuf[bytesRead] = '\0';

    /* Check TimeDateStamp header */
    DWORD txtTimestamp = 0;
    BOOL hasTimestamp = FALSE;
    if (rawBuf[0] == '#') {
        const char* tsPrefix = "# TimeDateStamp: ";
        if (strncmp(rawBuf, tsPrefix, strlen(tsPrefix)) == 0) {
            txtTimestamp = (DWORD)strtoul(rawBuf + strlen(tsPrefix), NULL, 16);
            hasTimestamp = TRUE;
        }
    }

    if (hasTimestamp) {
        HMODULE hExe = GetModuleHandleA(NULL);
        if (hExe) {
            IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)hExe;
            IMAGE_NT_HEADERS* nt  = (IMAGE_NT_HEADERS*)((BYTE*)hExe + dos->e_lfanew);
            DWORD exeTimestamp = nt->FileHeader.TimeDateStamp;
            if (txtTimestamp != exeTimestamp) {
                char msg[128];
                sprintf_s(msg, sizeof(msg), "symbols.txt timestamp mismatch: txt=%08X exe=%08X",
                          txtTimestamp, exeTimestamp);
                InitTrace(msg);
                HeapFree(GetProcessHeap(), 0, rawBuf);
                return;
            }
        }
    }

    /* Pass 1: count FUNCs, PARAMs, and total string bytes needed */
    DWORD funcCount = 0, paramCount = 0, stringBytes = 0;
    {
        char* p = rawBuf;
        while (*p) {
            char* lineEnd = strchr(p, '\n');
            if (!lineEnd) lineEnd = p + strlen(p);
            if (p[0] == 'F' && strncmp(p, "FUNC\t", 5) == 0) {
                funcCount++;
                /* count func name string */
                char* t1 = p + 5;
                char* t2 = strchr(t1, '\t');
                if (t2) stringBytes += (DWORD)(t2 - t1) + 1;
            } else if (p[0] == 'P' && strncmp(p, "PARAM\t", 6) == 0) {
                paramCount++;
                /* count param name string */
                char* t1 = p + 6;
                char* t2 = strchr(t1, '\t');
                if (t2) stringBytes += (DWORD)(t2 - t1) + 1;
            }
            p = (*lineEnd) ? lineEnd + 1 : lineEnd;
        }
    }

    if (funcCount == 0) {
        InitTrace("symbols.txt has no FUNC lines");
        HeapFree(GetProcessHeap(), 0, rawBuf);
        return;
    }

    {
        char msg[128];
        sprintf_s(msg, sizeof(msg), "symbols.txt: %lu funcs, %lu params, %lu string bytes",
                  funcCount, paramCount, stringBytes);
        InitTrace(msg);
    }

    /* Allocate arrays */
    g_txtFuncs  = (TxtFunc*)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
                                       funcCount * sizeof(TxtFunc));
    g_txtParams = (TxtParam*)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
                                        paramCount * sizeof(TxtParam));
    g_symStrings = (char*)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, stringBytes);
    if (!g_txtFuncs || !g_txtParams || !g_symStrings) {
        InitTrace("symbols.txt: allocation failed");
        HeapFree(GetProcessHeap(), 0, rawBuf);
        if (g_txtFuncs)  { HeapFree(GetProcessHeap(), 0, g_txtFuncs);  g_txtFuncs = NULL; }
        if (g_txtParams) { HeapFree(GetProcessHeap(), 0, g_txtParams); g_txtParams = NULL; }
        if (g_symStrings){ HeapFree(GetProcessHeap(), 0, g_symStrings);g_symStrings = NULL; }
        return;
    }

    /* Pass 2: parse lines and populate arrays */
    DWORD fi = 0, pi = 0, so = 0;
    {
        char* p = rawBuf;
        while (*p) {
            char* lineEnd = strchr(p, '\n');
            if (!lineEnd) lineEnd = p + strlen(p);
            /* Strip \r if present */
            char* lineEndClean = lineEnd;
            if (lineEndClean > p && *(lineEndClean - 1) == '\r')
                lineEndClean--;
            char saved = *lineEndClean;
            *lineEndClean = '\0';

            if (p[0] == 'F' && strncmp(p, "FUNC\t", 5) == 0 && fi < funcCount) {
                /* FUNC\tname\tRVA\tcodeSize\tparamCount */
                char* t1 = p + 5;          /* name start */
                char* t2 = strchr(t1, '\t');
                if (t2) {
                    DWORD nameLen = (DWORD)(t2 - t1);
                    memcpy(g_symStrings + so, t1, nameLen);
                    g_symStrings[so + nameLen] = '\0';
                    g_txtFuncs[fi].nameOff = so;
                    so += nameLen + 1;

                    char* t3 = strchr(t2 + 1, '\t');
                    g_txtFuncs[fi].rva = (DWORD)strtoul(t2 + 1, NULL, 10);
                    if (t3) {
                        char* t4 = strchr(t3 + 1, '\t');
                        g_txtFuncs[fi].codeSize = (DWORD)strtoul(t3 + 1, NULL, 10);
                        if (t4) {
                            g_txtFuncs[fi].paramCount = (WORD)strtoul(t4 + 1, NULL, 10);
                        }
                    }
                    g_txtFuncs[fi].paramStart = (WORD)pi;
                    fi++;
                }
            } else if (p[0] == 'P' && strncmp(p, "PARAM\t", 6) == 0 && pi < paramCount) {
                /* PARAM\tname\ttype\tstorage */
                char* t1 = p + 6;          /* name start */
                char* t2 = strchr(t1, '\t');
                if (t2) {
                    DWORD nameLen = (DWORD)(t2 - t1);
                    memcpy(g_symStrings + so, t1, nameLen);
                    g_symStrings[so + nameLen] = '\0';
                    g_txtParams[pi].nameOff = so;
                    so += nameLen + 1;

                    /* skip type field, go to storage */
                    char* t3 = strchr(t2 + 1, '\t');
                    if (t3) {
                        char* stor = t3 + 1;
                        if (strncmp(stor, "REG:", 4) == 0) {
                            g_txtParams[pi].storage = 0;
                            g_txtParams[pi].regIdx = (WORD)TxtRegNameToCV(stor + 4);
                        } else if (strncmp(stor, "STACK:", 6) == 0) {
                            g_txtParams[pi].storage = 1;
                            g_txtParams[pi].stackOff = (WORD)atoi(stor + 6);
                        } else {
                            g_txtParams[pi].storage = 2; /* UNKNOWN */
                        }
                    }
                    pi++;
                }
            }

            *lineEndClean = saved;
            p = (*lineEnd) ? lineEnd + 1 : lineEnd;
        }
    }

    g_txtFuncCount  = fi;
    g_txtParamCount = pi;

    /* Sort by RVA for binary search */
    qsort(g_txtFuncs, g_txtFuncCount, sizeof(TxtFunc), TxtFuncCmpRva);

    HeapFree(GetProcessHeap(), 0, rawBuf);
    g_hasSymbols = TRUE;

    {
        char msg[128];
        sprintf_s(msg, sizeof(msg), "symbols.txt loaded: %lu funcs, %lu params",
                  g_txtFuncCount, g_txtParamCount);
        InitTrace(msg);
    }
}

/* Collect frame params into outBuf as "name=0xval, name=0xval, ..." */
static void CollectFrameParams(HANDLE hProc, CONTEXT* ctx, STACKFRAME64* frame,
                               char* outBuf, int outBufSize) {
    outBuf[0] = '\0';

    /* Try PDB params first */
    if (g_SymSetContext && g_SymEnumSymbols) {
        IMAGEHLP_STACK_FRAME imgFrame;
        memset(&imgFrame, 0, sizeof(imgFrame));
        imgFrame.InstructionOffset = frame->AddrPC.Offset;
        imgFrame.FrameOffset       = frame->AddrFrame.Offset;
        imgFrame.StackOffset       = frame->AddrStack.Offset;

        if (g_SymSetContext(hProc, &imgFrame, NULL)) {
            EnumParamsCtx ep;
            ep.ctx        = ctx;
            ep.hProc      = hProc;
            ep.paramCount = 0;
            ep.buf[0]     = '\0';
            ep.bufPos     = 0;

            g_SymEnumSymbols(hProc, 0, "*", EnumParamsCallback, &ep);

            if (ep.bufPos > 0 && ep.bufPos < outBufSize) {
                memcpy(outBuf, ep.buf, ep.bufPos + 1);
                return;
            }
        }
    }

    /* Fallback: txt symbols */
    if (g_txtFuncs) {
        HMODULE hExe = GetModuleHandleA(NULL);
        if (hExe) {
            DWORD rva = (DWORD)(frame->AddrPC.Offset - (DWORD64)hExe);
            const TxtFunc* func = TxtFindFunc(rva);
            if (func && func->paramCount > 0)
                TxtCollectFrameParams(func, ctx, hProc, frame->AddrStack.Offset,
                                      outBuf, outBufSize);
        }
    }
}

/* Inner resolve (caller must hold g_dbgHelpLock if using PDB path) */
static const char* ResolveSymbolInner(HANDLE hProc, DWORD64 addr,
                                       char* symBuf, size_t symBufSize) {
    /* Try PDB/dbghelp first */
    if (g_SymFromAddr) {
        PSYMBOL_INFO sym = (PSYMBOL_INFO)symBuf;
        sym->SizeOfStruct = sizeof(SYMBOL_INFO);
        sym->MaxNameLen   = (ULONG)(symBufSize - sizeof(SYMBOL_INFO));
        DWORD64 disp = 0;
        if (g_SymFromAddr(hProc, addr, &disp, sym))
            return sym->Name;
    }
    /* Fallback: txt symbols */
    if (g_txtFuncs) {
        HMODULE hExe = GetModuleHandleA(NULL);
        if (hExe) {
            DWORD rva = (DWORD)(addr - (DWORD64)hExe);
            const TxtFunc* func = TxtFindFunc(rva);
            if (func)
                return g_symStrings + func->nameOff;
        }
    }
    return "???";
}

/* Locking wrapper for use outside the stack trace loop */
static const char* ResolveSymbol(HANDLE hProc, DWORD64 addr,
                                  char* symBuf, size_t symBufSize) {
    EnterCriticalSection(&g_dbgHelpLock);
    const char* name = ResolveSymbolInner(hProc, addr, symBuf, symBufSize);
    LeaveCriticalSection(&g_dbgHelpLock);
    return name;
}

static void LogRegsAndStackTrace(CONTEXT* ctx, HANDLE hThread) {
    /* Registers + stack trace (shared) */
    LogLine("  RAX=%016llX RBX=%016llX RCX=%016llX RDX=%016llX RSI=%016llX RDI=%016llX RBP=%016llX RSP=%016llX R8 =%016llX R9 =%016llX R10=%016llX R11=%016llX R12=%016llX R13=%016llX R14=%016llX R15=%016llX", ctx->Rax, ctx->Rbx, ctx->Rcx, ctx->Rdx, ctx->Rsi, ctx->Rdi, ctx->Rbp, ctx->Rsp, ctx->R8, ctx->R9, ctx->R10, ctx->R11, ctx->R12, ctx->R13, ctx->R14, ctx->R15);

    if (!g_hasSymbols) return;

    HANDLE hProc = GetCurrentProcess();

    CONTEXT ctxCopy = *ctx;  /* StackWalk64 may modify the context */

    STACKFRAME64 frame;
    memset(&frame, 0, sizeof(frame));
    frame.AddrPC.Offset    = ctxCopy.Rip;
    frame.AddrPC.Mode      = AddrModeFlat;
    frame.AddrFrame.Offset = ctxCopy.Rbp;
    frame.AddrFrame.Mode   = AddrModeFlat;
    frame.AddrStack.Offset = ctxCopy.Rsp;
    frame.AddrStack.Mode   = AddrModeFlat;

    LogLine("  --- Stack Trace (Newest first) ---");

    /* TryEnter to avoid deadlock if the watchdog thread holds the lock */
    if (!TryEnterCriticalSection(&g_dbgHelpLock)) {
        LogLine("  (dbghelp lock held by another thread, skipping stack trace)");
        return;
    }

    int frameCount = 0;

    /* Guard against nested exceptions from StackWalk64/dbghelp traversing
       bad unwind tables — a nested AV inside the UEF kills the process. */
    __try {
        for (int i = 0; i < 64; i++) {
            /* Save context BEFORE StackWalk64 modifies it — after the call,
               ctxCopy is unwound to the caller's state, so parameter reads
               from registers (RCX, RDX, R8, R9) would get wrong values. */
            CONTEXT frameCtx = ctxCopy;

            if (!g_StackWalk64(IMAGE_FILE_MACHINE_AMD64, hProc, hThread, &frame,
                               &ctxCopy, NULL, g_SymFunctionTableAccess64,
                               g_SymGetModuleBase64, NULL))
                break;

            if (frame.AddrPC.Offset == 0) break;

            DWORD64 pc = frame.AddrPC.Offset;

            /* Resolve symbol name (uses PDB then txt fallback) */
            char symBuf[sizeof(SYMBOL_INFO) + MAX_SYM_NAME];
            const char* funcName = ResolveSymbolInner(hProc, pc, symBuf, sizeof(symBuf));

            /* Collect function parameters */
            char paramsBuf[400] = "";
            CollectFrameParams(hProc, &frameCtx, &frame, paramsBuf, sizeof(paramsBuf));

            /* Resolve source file + line, output in gdb format */
            IMAGEHLP_LINE64 line;
            line.SizeOfStruct = sizeof(line);
            DWORD lineDisp = 0;
            if (g_SymGetLineFromAddr64 && g_SymGetLineFromAddr64(hProc, pc, &lineDisp, &line))
                LogLine("  #0x%x  0x%llx in %s (%s) at %s:%lu", i, (unsigned long long)pc,
                         funcName, paramsBuf, line.FileName, line.LineNumber);
            else
                LogLine("  #0x%x  0x%llx in %s (%s)", i, (unsigned long long)pc,
                         funcName, paramsBuf);
            frameCount++;
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        LogLine("  (exception 0x%08lX during stack walk, aborting trace)",
                 (unsigned long)GetExceptionCode());
    }

    LeaveCriticalSection(&g_dbgHelpLock);

    if (frameCount == 0) {
        LogLine("StackWalk64 produced no frames");
    }
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
/*  Unhandled Exception Filter                                        */
/* ------------------------------------------------------------------ */

/* Resolve the module containing `rip` and log it.
   Returns TRUE if the address belongs to a known module. */
static BOOL LogRipModule(DWORD64 rip, BOOL isDuplicate) {
    HMODULE hMod = NULL;
    char modName[MAX_PATH] = "???";
    DWORD64 modOffset = 0;
    GetModuleHandleExA(
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        (LPCSTR)(ULONG_PTR)rip, &hMod);
    if (hMod) {
        GetModuleFileNameA(hMod, modName, MAX_PATH);
        modOffset = rip - (DWORD64)hMod;
    }
    char symBuf[sizeof(SYMBOL_INFO) + MAX_SYM_NAME];
    const char* symName = ResolveSymbol(GetCurrentProcess(), rip, symBuf, sizeof(symBuf));
    if (!isDuplicate) {
        LogLine(" Module: %s +0x%llX (%s)", modName, (unsigned long long)modOffset, symName);
    }
    return hMod != NULL;
}

static LPTOP_LEVEL_EXCEPTION_FILTER g_prevFilter = NULL;

/* Returns the first crash # if this RIP was seen before, 0 if new.
   Adds new entries to the table (up to CRASH_DEDUP_SIZE). */
static LONG CrashDedupLookup(DWORD64 rip, LONG crashNum) {
    for (LONG i = 0; i < g_crashDedupCount; i++) {
        if (g_crashDedup[i].rip == rip)
            return g_crashDedup[i].firstCrashNum;
    }
    /* New location — register it */
    if (g_crashDedupCount < CRASH_DEDUP_SIZE) {
        g_crashDedup[g_crashDedupCount].rip = rip;
        g_crashDedup[g_crashDedupCount].firstCrashNum = crashNum;
        g_crashDedupCount++;
    }
    return 0;
}

/* Only reached for access violations that
   no SEH handler caught (i.e., real crashes, not intentional AVs).
   Installed from the watchdog thread after game init is complete. */
static LONG WINAPI UnhandledCrashHandler(PEXCEPTION_POINTERS ep) {
    if (ep->ExceptionRecord->ExceptionCode != EXCEPTION_ACCESS_VIOLATION) {
        LogWithTimeStamp("UNHANDLED_EXCEPTION: code=0x%08lX RIP=0x%016llX (not an AV, cannot fix)",
                 (unsigned long)ep->ExceptionRecord->ExceptionCode,
                 (unsigned long long)ep->ContextRecord->Rip);
        LogRipModule(ep->ContextRecord->Rip, FALSE);
        LogRegsAndStackTrace(ep->ContextRecord, GetCurrentThread());
        return g_prevFilter ? g_prevFilter(ep) : EXCEPTION_CONTINUE_SEARCH;
    }

    ULONG_PTR accessType = ep->ExceptionRecord->ExceptionInformation[0];
    ULONG_PTR addr = ep->ExceptionRecord->ExceptionInformation[1];
    CONTEXT* ctx = ep->ContextRecord;
    const char* accessName = (accessType == 8) ? "EXECUTE" : (accessType == 0) ? "READ" : "WRITE";

    LONG count = InterlockedIncrement(&g_crashesSaved);

    /* Dedup: check if we've seen this RIP before */
    LONG prevCrashNum = CrashDedupLookup(ctx->Rip, count);
    BOOL isDuplicate = (prevCrashNum != 0);

    if (isDuplicate) {
        if (count <= CRASH_VERBOSE_LIMIT) {
            LogWithTimeStamp("ACCESS_VIOLATION #%ld: %s addr=0x%016llX RIP=0x%016llX (same location as crash #%ld)",
                     count, accessName, (unsigned long long)addr, (unsigned long long)ctx->Rip, prevCrashNum);
        } else {
            LONG skipped = InterlockedIncrement(&g_crashDedupSkipped);
            if (skipped == 1)
                LogWithTimeStamp("Crash dedup: future duplicate crashes will be silently suppressed (summary every %d)",
                         CRASH_DEDUP_REPORT_INTERVAL);
            if ((skipped % CRASH_DEDUP_REPORT_INTERVAL) == 0)
                LogWithTimeStamp("Crash dedup: %ld duplicate crashes suppressed so far", skipped);
        }
    } else {
        LogWithTimeStamp("ACCESS_VIOLATION #%ld: %s addr=0x%016llX RIP=0x%016llX",
                 count, accessName, (unsigned long long)addr, (unsigned long long)ctx->Rip);
    }

    /* Recovery analysis (always runs, logging gated on !isDuplicate) */
    BOOL bailEarly = FALSE;
    hde64s hs;
    unsigned int instrLen = 0;
    DWORD64 retAddr = 0;

    if (accessType == 8) {
        /* EXECUTE: simulate ret if return address is inside a known module */
        if (!SafeRead(GetCurrentProcess(), ctx->Rsp, &retAddr, sizeof(retAddr)) || retAddr == 0) {
            if (!isDuplicate) {
                LogLine("  Recovery: no valid return address on stack, cannot recover");
            }
            bailEarly = TRUE;
        } else if (!LogRipModule(retAddr, isDuplicate)) {
            if (!isDuplicate) {
                LogLine("  Recovery: return address 0x%016llX not inside any module, cannot recover", (unsigned long long)retAddr);
            }
            bailEarly = TRUE;
        } else if (!isDuplicate) {
            LogLine("  Recovery: simulating ret to 0x%016llX", (unsigned long long)retAddr);
        }
    } else {
        /* For read/write, decode the faulting instruction first (bail early if we can't) */
        instrLen = hde64_disasm((BYTE*)ctx->Rip, &hs);
        if (instrLen == 0 || (hs.flags & F_ERROR))
        {
            if (!isDuplicate) {
                LogLine("  Failed to decode instruction at RIP, cannot analyze or recover");
            }
            bailEarly = TRUE;
        }

        if (!isDuplicate) {
            LogRipModule(ctx->Rip, FALSE);
        }
    }
    if (!isDuplicate) {
        LogRegsAndStackTrace(ctx, GetCurrentThread());
    }

    if (bailEarly) {
        return g_prevFilter ? g_prevFilter(ep) : EXCEPTION_CONTINUE_SEARCH;
    }

    // Try fixing what is wrong
    if (accessType == 8) {
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
        ctx->Rip += instrLen;
    }

    /* Queue a balloon for the watchdog thread to show (not safe to call Shell_NotifyIconA here) */
    if (count == 1 || count == 20) {
        sprintf_s(g_pendingBalloonMsg, sizeof(g_pendingBalloonMsg),
                  "CrashProtector: Saved from crashing.\n"
                  "See %s for details.",
                  g_logDir);
        strcpy_s(g_pendingBalloonTitle, sizeof(g_pendingBalloonTitle), "WC3 crash protector!");
        InterlockedExchange(&g_pendingBalloon, 1);
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
/*  Hang Detection Watchdog                                           */
/* ------------------------------------------------------------------ */

static HANDLE g_watchdogThread = NULL;
static volatile LONG g_watchdogShutdown = 0;
static DWORD g_mainThreadId = 0;
static DWORD g_watchdogThreadId = 0;
static DWORD g_logWriterThreadId = 0;

#define WATCHDOG_INTERVAL_MS  3000   /* how often to check */
#define WATCHDOG_TIMEOUT_MS   10000   /* how long before we declare a hang */

/* EnumThreadWindows callback — grab the first top-level window */
static BOOL CALLBACK FindThreadWindowCb(HWND hwnd, LPARAM lParam) {
    if (IsWindowVisible(hwnd)) {
        *(HWND*)lParam = hwnd;
        return FALSE; /* stop enumeration */
    }
    return TRUE;
}

static HWND FindMainThreadWindow(void) {
    HWND hwnd = NULL;
    EnumThreadWindows(g_mainThreadId, FindThreadWindowCb, (LPARAM)&hwnd);
    return hwnd;
}

static void LogThreadInfo(DWORD threadId, HANDLE hThread, CONTEXT* ctx) {
    HANDLE hProc = GetCurrentProcess();
    DWORD64 rip = ctx->Rip;

    /* Resolve RIP module + offset */
    HMODULE hMod = NULL;
    char modName[MAX_PATH] = "???";
    DWORD64 modOffset = 0;
    GetModuleHandleExA(
        GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        (LPCSTR)(ULONG_PTR)rip, &hMod);

    BOOL inGameExe = FALSE;
    if (hMod) {
        GetModuleFileNameA(hMod, modName, MAX_PATH);
        modOffset = rip - (DWORD64)hMod;
        /* Check if RIP is in the main game executable */
        inGameExe = (hMod == GetModuleHandleA(NULL));
    }

    /* Resolve RIP symbol name */
    char symBuf[sizeof(SYMBOL_INFO) + MAX_SYM_NAME];
    const char* symName = ResolveSymbol(hProc, rip, symBuf, sizeof(symBuf));

    const char* marker = (threadId == g_mainThreadId) ? " [MAIN]" :
                         inGameExe ? " [GAME CODE]" : "";

    LogLine("  Thread %lu%s: RIP=0x%016llX %s +0x%llX (%s)",
             threadId, marker,
             (unsigned long long)rip, modName,
             (unsigned long long)modOffset, symName);

    /* Only dump registers + stack for interesting threads (not idle system waits) */
    BOOL isNtdll = (strstr(modName, "ntdll.dll") != NULL);
    if (!isNtdll)
        LogRegsAndStackTrace(ctx, hThread);
}

static void DumpAllThreadStacks(void) {
    DWORD pid = GetCurrentProcessId();
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snap == INVALID_HANDLE_VALUE) {
        LogWithTimeStamp("Watchdog: failed to create thread snapshot");
        return;
    }

    LogWithTimeStamp("=== Hang Diagnostic: All Thread Stacks ===");

    THREADENTRY32 te;
    te.dwSize = sizeof(te);

    if (Thread32First(snap, &te)) {
        do {
            if (te.th32OwnerProcessID != pid) continue;

            /* Skip our own threads */
            DWORD tid = te.th32ThreadID;
            if (tid == g_watchdogThreadId || tid == g_logWriterThreadId) continue;

            HANDLE hThread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_QUERY_INFORMATION,
                                        FALSE, tid);
            if (!hThread) continue;

            if (SuspendThread(hThread) != (DWORD)-1) {
                CONTEXT ctx;
                memset(&ctx, 0, sizeof(ctx));
                ctx.ContextFlags = CONTEXT_FULL;

                if (GetThreadContext(hThread, &ctx)) {
                    LogThreadInfo(tid, hThread, &ctx);
                } else {
                    LogLine("  Thread %lu: failed to get context (err=%lu)", tid, GetLastError());
                }

                ResumeThread(hThread);
            }

            CloseHandle(hThread);
        } while (Thread32Next(snap, &te));
    }

    CloseHandle(snap);
    LogLine("=== End Hang Diagnostic ===");
}

/* Sample and log just the main thread's current RIP (module + symbol). */
static void LogMainThreadLocation(void) {
    HANDLE hThread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT,
                                FALSE, g_mainThreadId);
    if (!hThread) return;

    if (SuspendThread(hThread) != (DWORD)-1) {
        CONTEXT ctx;
        memset(&ctx, 0, sizeof(ctx));
        ctx.ContextFlags = CONTEXT_CONTROL;

        if (GetThreadContext(hThread, &ctx)) {
            DWORD64 rip = ctx.Rip;
            HMODULE hMod = NULL;
            char modName[MAX_PATH] = "???";
            DWORD64 modOffset = 0;
            GetModuleHandleExA(
                GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                (LPCSTR)(ULONG_PTR)rip, &hMod);
            if (hMod) {
                GetModuleFileNameA(hMod, modName, MAX_PATH);
                modOffset = rip - (DWORD64)hMod;
            }
            char symBuf[sizeof(SYMBOL_INFO) + MAX_SYM_NAME];
            const char* symName = ResolveSymbol(GetCurrentProcess(), rip, symBuf, sizeof(symBuf));
            LogWithTimeStamp("  Thread %lu [MAIN]: RIP=0x%016llX %s +0x%llX (%s)",
                     g_mainThreadId,
                     (unsigned long long)rip, modName,
                     (unsigned long long)modOffset, symName);
        }
        ResumeThread(hThread);
    }
    CloseHandle(hThread);
}

/* ------------------------------------------------------------------ */
/*  Memory Dumper — dump decrypted .text section to disk - this is just for signature copying, it's unrelated to the crash protection and is not needed for most users               */
/* ------------------------------------------------------------------ */

static void DumpDecryptedExe(void) {
    HMODULE hExe = GetModuleHandleA(NULL);
    if (!hExe) return;

    /* Get the path to the original exe on disk */
    char exePath[MAX_PATH];
    GetModuleFileNameA(hExe, exePath, MAX_PATH);

    /* Read the entire original file */
    HANDLE hSrc = CreateFileA(exePath, GENERIC_READ, FILE_SHARE_READ, NULL,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hSrc == INVALID_HANDLE_VALUE) {
        LogWithTimeStamp("ERROR: Cannot open original exe: %s (err=%lu)", exePath, GetLastError());
        return;
    }
    DWORD fileSize = GetFileSize(hSrc, NULL);
    BYTE* fileBuf = (BYTE*)HeapAlloc(GetProcessHeap(), 0, fileSize);
    if (!fileBuf) { CloseHandle(hSrc); return; }
    DWORD bytesRead;
    ReadFile(hSrc, fileBuf, fileSize, &bytesRead, NULL);
    CloseHandle(hSrc);

    /* Parse the file's PE headers */
    IMAGE_DOS_HEADER* fDos = (IMAGE_DOS_HEADER*)fileBuf;
    IMAGE_NT_HEADERS* fNt  = (IMAGE_NT_HEADERS*)(fileBuf + fDos->e_lfanew);
    IMAGE_SECTION_HEADER* fSec = IMAGE_FIRST_SECTION(fNt);
    WORD numSec = fNt->FileHeader.NumberOfSections;

    /* Only overwrite .text with decrypted in-memory content.
       Other sections (rdata, data, etc.) stay from the original file — they
       weren't encrypted, and in memory they've been relocated by ASLR
       which would break PDB address matching. */
    for (WORD i = 0; i < numSec; i++) {
        if (memcmp(fSec[i].Name, ".text", 5) != 0) continue;
        if (fSec[i].SizeOfRawData == 0) continue;

        BYTE* memData = (BYTE*)hExe + fSec[i].VirtualAddress;
        DWORD copySize = fSec[i].SizeOfRawData;
        if (fSec[i].Misc.VirtualSize < copySize)
            copySize = fSec[i].Misc.VirtualSize;

        memcpy(fileBuf + fSec[i].PointerToRawData, memData, copySize);

        LogLine("  Patched %.8s: FileOff=0x%X Size=0x%X",
                 fSec[i].Name, fSec[i].PointerToRawData, copySize);
    }

    /* Write the patched exe */
    char dumpPath[MAX_PATH];
    sprintf_s(dumpPath, MAX_PATH, "%s\\wc3_decrypted.exe", g_logDir);

    HANDLE hDst = CreateFileA(dumpPath, GENERIC_WRITE, 0, NULL,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (hDst != INVALID_HANDLE_VALUE) {
        DWORD written;
        WriteFile(hDst, fileBuf, fileSize, &written, NULL);
        CloseHandle(hDst);
        LogLine("Dumped decrypted exe: %s (%lu bytes)", dumpPath, written);
    } else {
        LogLine("ERROR: Failed to create dump file (err=%lu)", GetLastError());
    }

    HeapFree(GetProcessHeap(), 0, fileBuf);
}

static DWORD WINAPI WatchdogThread(LPVOID param) {
    (void)param;

    /* Wait for the main thread to create its window */
    HWND hwnd = NULL;
    while (!g_watchdogShutdown) {
        hwnd = FindMainThreadWindow();
        if (hwnd) break;
        Sleep(1000);
    }
    if (!hwnd) return 0;

    LogWithTimeStamp("CrashProtector %s. Found game window (HWND=0x%llX, tid=%lu)",
             VERSION, (unsigned long long)(ULONG_PTR)hwnd, g_mainThreadId);

    /* Install UEF now that game init is complete.
       This captures the game's filter for chaining on non-AV exceptions. */
    g_prevFilter = SetUnhandledExceptionFilter(UnhandledCrashHandler);

    // /* For signature copying - dump the unprotected game exe to file so the data is not encrypted */
    // DumpDecryptedExe();

    BOOL hangDumped = FALSE;
    DWORD lastDumpTime = 0;
    DWORD hangStartTime = 0;
    int hangTickCount = 0;
    #define HANG_DUMP_COOLDOWN_MS 60000
    #define HANG_MONITOR_DURATION_MS 60000  /* sample main thread for 1 min then go quiet */
    #define HANG_GRACE_PERIOD_MS 120000     /* ignore hangs for first 2 min (game loads in a hang) */

    DWORD watchdogStartTime = GetTickCount();
    LogWithTimeStamp("Watchdog: hang detection grace period active (%d seconds)",
             HANG_GRACE_PERIOD_MS / 1000);

    while (!g_watchdogShutdown) {
        Sleep(WATCHDOG_INTERVAL_MS);
        if (g_watchdogShutdown) break;

        /* Show any balloon queued by the crash handler */
        if (InterlockedCompareExchange(&g_pendingBalloon, 0, 1) == 1)
            ShowBalloon(g_pendingBalloonTitle, g_pendingBalloonMsg);

        /* Re-find the window in case it was recreated */
        hwnd = FindMainThreadWindow();
        if (!hwnd) {
            LogWithTimeStamp("Watchdog: game window gone, stopping");
            break;
        }

        DWORD_PTR result = 0;
        LRESULT ok = SendMessageTimeoutA(hwnd, WM_NULL, 0, 0,
                                          SMTO_ABORTIFHUNG, WATCHDOG_TIMEOUT_MS, &result);
        if (ok != 0) {
            /* Genuine response from the message loop */
            if (hangDumped) {
                LogWithTimeStamp("Watchdog: main thread recovered");
                hangDumped = FALSE;
            }
        } else {
            /* SendMessageTimeout failed — treat any failure as hung */
            DWORD now = GetTickCount();

            /* Skip hang detection during the startup grace period */
            if ((now - watchdogStartTime) < HANG_GRACE_PERIOD_MS)
                continue;

            if (!hangDumped) {
                /* First detection of a new hang episode */
                hangStartTime = now;
                hangTickCount = 0;
                LogWithTimeStamp("HANG DETECTED: main thread not responding");
                InterlockedExchange(&g_hangDetected, 1);
                ShowBalloon("WC3 Hang Detected!", "Main thread is not responding. See CrashProtector logs.");

                if ((now - lastDumpTime) >= HANG_DUMP_COOLDOWN_MS) {
                    DumpAllThreadStacks();
                    lastDumpTime = now;
                }
                hangDumped = TRUE;
            } else if ((now - hangStartTime) < HANG_MONITOR_DURATION_MS) {
                /* Ongoing hang — sample main thread location for up to 1 minute */
                hangTickCount++;
                LogMainThreadLocation();
            } else if (hangTickCount > 0) {
                /* Past 1 minute — log once that we're going quiet */
                LogWithTimeStamp("Watchdog: still hung after %lus, stopping periodic samples",
                         (now - hangStartTime) / 1000);
                hangTickCount = -1; /* sentinel: already logged the quiet message */
            }
        }
    }

    return 0;
}

/* ------------------------------------------------------------------ */
/*  DLL Entry Point                                                   */
/* ------------------------------------------------------------------ */

BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID reserved) {
    (void)reserved;

    if (reason == DLL_PROCESS_ATTACH) {
        g_mainThreadId = GetCurrentThreadId();
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
        InitializeCriticalSection(&g_dbgHelpLock);
        g_logThread = CreateThread(NULL, 0, LogWriterThread, NULL, 0, &g_logWriterThreadId);
        InitSymbols();
        LoadSymbolsTxt();
        LogWithTimeStamp("=== CrashProtector loaded (PID %lu, symbols=%s) ===",
                 GetCurrentProcessId(), g_hasSymbols ? "YES" : "NO");

        /* UEF is installed from the watchdog thread after game init,
           so we install after the game's own filter */

        LogWithTimeStamp("Ready - monitoring for invalid pointer access violations");

        /* Start the hang-detection watchdog */
        g_watchdogThread = CreateThread(NULL, 0, WatchdogThread, NULL, 0, &g_watchdogThreadId);
        if (g_watchdogThread)
            LogWithTimeStamp("Watchdog thread started");
    } else if (reason == DLL_PROCESS_DETACH) {
        LogWithTimeStamp("=== CrashProtector unloading. Total crashes reported: %ld ===", g_crashesSaved);

        /* Shut down the watchdog thread */
        InterlockedExchange(&g_watchdogShutdown, 1);
        if (g_watchdogThread) {
            WaitForSingleObject(g_watchdogThread, 2000);
            CloseHandle(g_watchdogThread);
        }

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
        if (g_SymCleanup) g_SymCleanup(GetCurrentProcess());
        if (g_txtFuncs)   HeapFree(GetProcessHeap(), 0, g_txtFuncs);
        if (g_txtParams)  HeapFree(GetProcessHeap(), 0, g_txtParams);
        if (g_symStrings) HeapFree(GetProcessHeap(), 0, g_symStrings);
        DeleteCriticalSection(&g_dbgHelpLock);
        if (g_dbgHelp) FreeLibrary(g_dbgHelp);
        if (g_realVersion) FreeLibrary(g_realVersion);
    }

    return TRUE;
}
