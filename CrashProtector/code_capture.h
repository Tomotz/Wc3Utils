/* Runtime code snapshots. Included after logging and SafeRead definitions.
 * One preallocated PE buffer; the exception path performs reads only.
 * State: 0 unavailable/idle, 1 filling, 2 ready to write, 3 writing.
 * g_captureReady distinguishes initialized idle from unavailable.
 */
#define CAPTURE_MAX_FILE (256u * 1024u * 1024u)
#define CAPTURE_PAGE 4096u
#define CAPTURE_MAX_PAGES (CAPTURE_MAX_FILE / CAPTURE_PAGE)
static BYTE* g_captureImage;
static DWORD g_captureFileSize, g_captureRva, g_captureOffset, g_captureSize;
static BYTE* g_captureBase;
static volatile LONG g_captureState, g_captureReady, g_capturedCrash;
static DWORD g_captureSequence, g_captureFailures, g_captureMillis;
static DWORD g_captureGuarded, g_captureNoAccess, g_captureReadErrors;
static DWORD64 g_captureFault, g_captureTick;
static const char* g_captureKind;
static BYTE g_captureValid[CAPTURE_MAX_PAGES];
static DWORD64 g_captureBaseline[CAPTURE_MAX_PAGES];
static BYTE g_captureBaselineValid[CAPTURE_MAX_PAGES];
static BOOL g_captureHasBaseline;

static DWORD64 CaptureHash(const BYTE* data, DWORD size) {
    DWORD64 hash = 14695981039346656037ULL;
    for (DWORD i = 0; i < size; ++i) { hash ^= data[i]; hash *= 1099511628211ULL; }
    return hash;
}

/* Skip guarded/uncommitted regions without changing their protection. */
static BOOL CaptureReadPage(const BYTE* source, BYTE* dest, DWORD size) {
    MEMORY_BASIC_INFORMATION info;
    if (!VirtualQuery(source, &info, sizeof(info))) { ++g_captureReadErrors; return FALSE; }
    if (info.Protect & PAGE_GUARD) { ++g_captureGuarded; return FALSE; }
    if (info.State != MEM_COMMIT || (info.Protect & PAGE_NOACCESS)) { ++g_captureNoAccess; return FALSE; }
    if ((SIZE_T)(source - (BYTE*)info.BaseAddress) + size > info.RegionSize ||
        !SafeRead(GetCurrentProcess(), (DWORD64)source, dest, size)) {
        ++g_captureReadErrors; return FALSE;
    }
    return TRUE;
}

static void CaptureOnePage(DWORD page) {
    DWORD offset = page * CAPTURE_PAGE;
    DWORD size = g_captureSize - offset;
    if (size > CAPTURE_PAGE) size = CAPTURE_PAGE;
    BYTE* dest = g_captureImage + g_captureOffset + offset;
    BOOL ok = CaptureReadPage(g_captureBase + g_captureRva + offset, dest, size);
    g_captureValid[page] = (BYTE)ok;
    if (!ok) { memset(dest, 0, size); ++g_captureFailures; }
}

static void FillCodeCapture(const char* kind, DWORD64 fault) {
    DWORD started = GetTickCount();
    g_captureTick = GetTickCount64();
    g_captureKind = kind;
    g_captureFault = fault;
    g_captureFailures = 0;
    g_captureGuarded = g_captureNoAccess = g_captureReadErrors = 0;
    DWORD pages = (g_captureSize + CAPTURE_PAGE - 1) / CAPTURE_PAGE;
    DWORD first = 0;
    DWORD64 textBase = (DWORD64)g_captureBase + g_captureRva;
    if (fault >= textBase && fault - textBase < g_captureSize)
        first = (DWORD)((fault - textBase) / CAPTURE_PAGE);
    /* Preserve the fault page first, before the recovery handler changes RIP. */
    CaptureOnePage(first);
    for (DWORD page = 0; page < pages; ++page)
        if (page != first) CaptureOnePage(page);
    g_captureMillis = GetTickCount() - started;
    ++g_captureSequence;
    InterlockedExchange(&g_captureState, 2);
    if (g_logEvent) SetEvent(g_logEvent);
}

static void CaptureCrashCode(DWORD64 fault) {
    if (!g_captureReady || g_capturedCrash ||
        InterlockedCompareExchange(&g_captureState, 1, 0) != 0) return;
    if (InterlockedCompareExchange(&g_capturedCrash, 1, 0) != 0) {
        InterlockedExchange(&g_captureState, 0); return;
    }
    FillCodeCapture("crash", fault);
}

static void FlushCodeCapture(void) {
    if (InterlockedCompareExchange(&g_captureState, 3, 2) != 2) return;
    BOOL startup = strcmp(g_captureKind, "startup") == 0;
    DWORD changed = 0, comparable = 0, newlyReadable = 0, newlyUnreadable = 0;
    DWORD pages = (g_captureSize + CAPTURE_PAGE - 1) / CAPTURE_PAGE;
    for (DWORD page = 0; page < pages; ++page) {
        DWORD offset = page * CAPTURE_PAGE, size = g_captureSize - offset;
        if (size > CAPTURE_PAGE) size = CAPTURE_PAGE;
        DWORD64 hash = CaptureHash(g_captureImage + g_captureOffset + offset, size);
        if (startup) {
            g_captureBaseline[page] = hash;
            g_captureBaselineValid[page] = g_captureValid[page];
        } else if (g_captureHasBaseline && g_captureValid[page] && !g_captureBaselineValid[page]) {
            ++newlyReadable;
        } else if (g_captureHasBaseline && !g_captureValid[page] && g_captureBaselineValid[page]) {
            ++newlyUnreadable;
        } else if (g_captureHasBaseline && g_captureValid[page] && g_captureBaselineValid[page]) {
            ++comparable;
            if (hash != g_captureBaseline[page]) ++changed;
        }
    }
    if (startup) g_captureHasBaseline = TRUE;
    char path[MAX_PATH], metadata[MAX_PATH];
    if (startup) sprintf_s(path, MAX_PATH, "%s\\wc3_decrypted.exe", g_logDir);
    else sprintf_s(path, MAX_PATH, "%s\\wc3_capture_%lu_%s_%lu_%llu.exe", g_logDir,
                   GetCurrentProcessId(), g_captureKind, g_captureSequence, (unsigned long long)g_captureTick);
    sprintf_s(metadata, MAX_PATH, "%s.json", path);
    HANDLE file = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL,
                              startup ? CREATE_ALWAYS : CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    DWORD written = 0;
    BOOL ok = file != INVALID_HANDLE_VALUE;
    if (ok) {
        ok = WriteFile(file, g_captureImage, g_captureFileSize, &written, NULL) && written == g_captureFileSize;
        FlushFileBuffers(file);
        CloseHandle(file);
    }
    if (ok) {
        FILE* out = NULL;
        if (fopen_s(&out, metadata, "wb") == 0) {
            fprintf(out, "{\n  \"format\": 1, \"kind\": \"%s\", \"pid\": %lu,\n", g_captureKind, GetCurrentProcessId());
            fprintf(out, "  \"image_base\": %llu, \"fault_address\": %llu,\n", (unsigned long long)g_captureBase, (unsigned long long)g_captureFault);
            fprintf(out, "  \"text_rva\": %lu, \"text_size\": %lu, \"read_duration_ms\": %lu,\n", g_captureRva, g_captureSize, g_captureMillis);
            fprintf(out, "  \"unreadable_pages\": %lu, \"changed_pages\": %lu, \"comparable_pages\": %lu,\n", g_captureFailures, changed, comparable);
            fprintf(out, "  \"guarded_pages\": %lu, \"noaccess_pages\": %lu, \"read_error_pages\": %lu,\n", g_captureGuarded, g_captureNoAccess, g_captureReadErrors);
            fprintf(out, "  \"newly_readable_pages\": %lu, \"newly_unreadable_pages\": %lu,\n", newlyReadable, newlyUnreadable);
            fprintf(out, "  \"unreadable_page_rvas\": [");
            BOOL comma = FALSE;
            for (DWORD page = 0; page < pages; ++page) if (!g_captureValid[page]) {
                fprintf(out, "%s%lu", comma ? ", " : "", g_captureRva + page * CAPTURE_PAGE); comma = TRUE;
            }
            fprintf(out, "]\n}\n");
            if (fclose(out) != 0) LogWithTimeStamp("Code capture metadata write failed: %s", metadata);
        } else LogWithTimeStamp("Code capture metadata open failed: %s", metadata);
        LogWithTimeStamp("Code capture: %s; unreadable=%lu pages (guarded=%lu); changed=%lu/%lu pages; newly-readable=%lu; copy=%lu ms", path, g_captureFailures, g_captureGuarded, changed, comparable, newlyReadable, g_captureMillis);
    } else LogWithTimeStamp("Code capture write failed: %s (bytes=%lu)", path, written);
    InterlockedExchange(&g_captureState, 0);
}

static void ServiceCodeCaptureRequest(void) {
    if (!g_captureReady || InterlockedCompareExchange(&g_captureState, 1, 0) != 0) return;
    char request[MAX_PATH];
    sprintf_s(request, MAX_PATH, "%s\\capture-%lu.request", g_logDir, GetCurrentProcessId());
    if (GetFileAttributesA(request) == INVALID_FILE_ATTRIBUTES || !DeleteFileA(request)) {
        InterlockedExchange(&g_captureState, 0); return;
    }
    FillCodeCapture("manual", 0);
}

static void InitCodeCapture(void) {
    char exePath[MAX_PATH];
    if (!GetModuleFileNameA(NULL, exePath, MAX_PATH)) return;
    HANDLE file = CreateFileA(exePath, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD size = GetFileSize(file, NULL), read = 0;
    BYTE* image = size >= sizeof(IMAGE_DOS_HEADER) && size <= CAPTURE_MAX_FILE ?
        (BYTE*)HeapAlloc(GetProcessHeap(), 0, size) : NULL;
    BOOL ok = image && ReadFile(file, image, size, &read, NULL) && read == size;
    CloseHandle(file);
    if (!ok) { if (image) HeapFree(GetProcessHeap(), 0, image); return; }
    IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)image;
    if (size < sizeof(IMAGE_NT_HEADERS) || dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0 ||
        (DWORD)dos->e_lfanew > size - sizeof(IMAGE_NT_HEADERS)) goto invalid;
    IMAGE_NT_HEADERS* nt = (IMAGE_NT_HEADERS*)(image + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC) goto invalid;
    IMAGE_SECTION_HEADER* sections = IMAGE_FIRST_SECTION(nt);
    if ((BYTE*)sections - image + (SIZE_T)nt->FileHeader.NumberOfSections * sizeof(*sections) > size) goto invalid;
    for (WORD i = 0; i < nt->FileHeader.NumberOfSections; ++i) {
        IMAGE_SECTION_HEADER* section = sections + i;
        if (memcmp(section->Name, ".text\0\0\0", 8) != 0) continue;
        DWORD bytes = section->SizeOfRawData;
        if (section->Misc.VirtualSize < bytes) bytes = section->Misc.VirtualSize;
        if (!bytes || bytes > CAPTURE_MAX_FILE || section->PointerToRawData > size ||
            bytes > size - section->PointerToRawData || section->VirtualAddress % CAPTURE_PAGE ||
            section->VirtualAddress > nt->OptionalHeader.SizeOfImage ||
            bytes > nt->OptionalHeader.SizeOfImage - section->VirtualAddress) goto invalid;
        g_captureBase = (BYTE*)GetModuleHandleA(NULL);
        g_captureImage = image; g_captureFileSize = size;
        g_captureRva = section->VirtualAddress; g_captureOffset = section->PointerToRawData; g_captureSize = bytes;
        InterlockedExchange(&g_captureState, 1);
        FillCodeCapture("startup", 0);
        InterlockedExchange(&g_captureReady, 1);
        LogWithTimeStamp("Code capture armed: first unhandled crash and manual requests; buffer=%lu bytes", size);
        return;
    }
invalid:
    HeapFree(GetProcessHeap(), 0, image);
    LogWithTimeStamp("Code capture unavailable: unsupported executable layout");
}
