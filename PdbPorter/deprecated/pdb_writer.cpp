/*
 * pdb_writer.cpp - Creates PDB files with function parameter information
 *
 * Reads an extended symbol map (FUNC/PARAM format from MatchFunctions.java)
 * and a target PE binary, then creates a PDB with:
 *   - Public symbols for each function (for SymFromAddr)
 *   - S_GPROC32 procedure records with parameter records (for SymEnumSymbols)
 *
 * Uses mspdb140.dll from Visual Studio (via vtable calls) to write the PDB.
 * Must be compiled with MSVC and run from a Developer Command Prompt.
 *
 * Usage: pdb_writer.exe <target.exe> <symbols.txt> <output.pdb>
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ================================================================ */
/*  CodeView constants                                               */
/* ================================================================ */

/* Symbol record types */
#define S_END           0x0006
#define S_REGISTER_SYM  0x1001
#define S_GPROC32       0x1110
#define S_REGREL32      0x1111

#define CV_SIGNATURE_C13 4

/* Built-in type indices */
#define T_NOTYPE    0x0000
#define T_VOID      0x0003
#define T_CHAR      0x0010
#define T_UCHAR     0x0020
#define T_SHORT     0x0011
#define T_USHORT    0x0021
#define T_INT4      0x0074
#define T_UINT4     0x0075
#define T_LONG      0x0012
#define T_ULONG     0x0022
#define T_INT8      0x0076
#define T_UINT8     0x0077
#define T_REAL32    0x0040
#define T_REAL64    0x0041
#define T_BOOL08    0x0030

/* 64-bit pointer types (base | 0x0600) */
#define T_64PVOID   0x0603
#define T_64PCHAR   0x0610
#define T_64PUCHAR  0x0620
#define T_64PINT4   0x0674
#define T_64PUINT4  0x0675

/* CodeView AMD64 register IDs */
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

/* ================================================================ */
/*  mspdb140.dll vtable interface                                    */
/* ================================================================ */

/*
 * We call virtual methods on PDB/DBI/Mod objects by index through
 * their vtable pointer. On x64, 'this' is the first parameter (rcx).
 * Vtable indices are from microsoft-pdb headers (stable since VS2015).
 */

#define PDB_VT_QUERY_INTV   0
#define PDB_VT_QUERY_IMPV   1
#define PDB_VT_OPENDBI      6
#define PDB_VT_COMMIT       8
#define PDB_VT_CLOSE        9

#define DBI_VT_OPENMOD      2
#define DBI_VT_ADDSEC       7
#define DBI_VT_CLOSE       14
#define DBI_VT_ADDPUBLIC   16

#define MOD_VT_ADDSYMBOLS   3
#define MOD_VT_ADDSECCONTRIB 6
#define MOD_VT_CLOSE       14

static void** vtbl(void* obj) { return *(void***)obj; }

typedef BOOL (__cdecl *PDBOpen2W_fn)(
    const wchar_t* szPDB, const char* szMode,
    long* pec, wchar_t* szError, size_t cchErrMax,
    void** pppdb);

/* Typed vtable call wrappers */

static int PDB_QueryInterfaceVersion(void* pdb) {
    typedef int (*fn)(void*);
    return ((fn)vtbl(pdb)[PDB_VT_QUERY_INTV])(pdb);
}

static BOOL PDB_OpenDBI(void* pdb, const char* target, const char* mode, void** dbi) {
    typedef BOOL (*fn)(void*, const char*, const char*, void**);
    return ((fn)vtbl(pdb)[PDB_VT_OPENDBI])(pdb, target, mode, dbi);
}

static BOOL PDB_Commit(void* pdb) {
    typedef BOOL (*fn)(void*);
    return ((fn)vtbl(pdb)[PDB_VT_COMMIT])(pdb);
}

static BOOL PDB_Close(void* pdb) {
    typedef BOOL (*fn)(void*);
    return ((fn)vtbl(pdb)[PDB_VT_CLOSE])(pdb);
}

static BOOL DBI_OpenMod(void* dbi, const char* szModule, const char* szFile, void** ppmod) {
    typedef BOOL (*fn)(void*, const char*, const char*, void**);
    return ((fn)vtbl(dbi)[DBI_VT_OPENMOD])(dbi, szModule, szFile, ppmod);
}

static BOOL DBI_AddSec(void* dbi, USHORT isect, USHORT flags, long off, long cb) {
    typedef BOOL (*fn)(void*, USHORT, USHORT, long, long);
    return ((fn)vtbl(dbi)[DBI_VT_ADDSEC])(dbi, isect, flags, off, cb);
}

static BOOL DBI_Close(void* dbi) {
    typedef BOOL (*fn)(void*);
    return ((fn)vtbl(dbi)[DBI_VT_CLOSE])(dbi);
}

static BOOL DBI_AddPublic(void* dbi, const char* name, USHORT isect, long off) {
    typedef BOOL (*fn)(void*, const char*, USHORT, long);
    return ((fn)vtbl(dbi)[DBI_VT_ADDPUBLIC])(dbi, name, isect, off);
}

static BOOL MOD_AddSymbols(void* mod, BYTE* pbSym, long cb) {
    typedef BOOL (*fn)(void*, BYTE*, long);
    return ((fn)vtbl(mod)[MOD_VT_ADDSYMBOLS])(mod, pbSym, cb);
}

static BOOL MOD_AddSecContrib(void* mod, USHORT isect, long off, long cb, ULONG dwChar) {
    typedef BOOL (*fn)(void*, USHORT, long, long, ULONG);
    return ((fn)vtbl(mod)[MOD_VT_ADDSECCONTRIB])(mod, isect, off, cb, dwChar);
}

static BOOL MOD_Close(void* mod) {
    typedef BOOL (*fn)(void*);
    return ((fn)vtbl(mod)[MOD_VT_CLOSE])(mod);
}

/* ================================================================ */
/*  Data structures                                                  */
/* ================================================================ */

#define MAX_PARAMS 32
#define MAX_NAME   256
#define MAX_TYPE   128
#define MAX_FUNCS  100000

enum StorageKind { STOR_REG, STOR_STACK, STOR_UNKNOWN };

typedef struct {
    char name[MAX_NAME];
    char typeName[MAX_TYPE];
    enum StorageKind kind;
    char regName[32];   /* for REG storage */
    long offset;        /* for STACK storage */
} ParamInfo;

typedef struct {
    char name[MAX_NAME];
    long rva;
    long codeSize;
    int  paramCount;
    ParamInfo params[MAX_PARAMS];
} FuncInfo;

typedef struct {
    DWORD virtualAddress;
    DWORD virtualSize;
    DWORD characteristics;
} SectionInfo;

/* ================================================================ */
/*  Dynamic buffer for building CodeView records                     */
/* ================================================================ */

typedef struct {
    BYTE* data;
    DWORD size;
    DWORD capacity;
} SymBuf;

static void sb_init(SymBuf* sb) {
    sb->capacity = 64 * 1024;
    sb->data = (BYTE*)malloc(sb->capacity);
    sb->size = 0;
    /* Write CV signature */
    DWORD sig = CV_SIGNATURE_C13;
    memcpy(sb->data, &sig, 4);
    sb->size = 4;
}

static void sb_ensure(SymBuf* sb, DWORD need) {
    while (sb->size + need > sb->capacity) {
        sb->capacity *= 2;
        sb->data = (BYTE*)realloc(sb->data, sb->capacity);
    }
}

static void sb_append(SymBuf* sb, const void* data, DWORD len) {
    sb_ensure(sb, len);
    memcpy(sb->data + sb->size, data, len);
    sb->size += len;
}

static void sb_append_u8(SymBuf* sb, BYTE v) { sb_append(sb, &v, 1); }
static void sb_append_u16(SymBuf* sb, WORD v) { sb_append(sb, &v, 2); }
static void sb_append_u32(SymBuf* sb, DWORD v) { sb_append(sb, &v, 4); }

static void sb_append_str(SymBuf* sb, const char* s) {
    sb_append(sb, s, (DWORD)strlen(s) + 1);
}

static void sb_patch_u16(SymBuf* sb, DWORD off, WORD v) {
    memcpy(sb->data + off, &v, 2);
}

static void sb_patch_u32(SymBuf* sb, DWORD off, DWORD v) {
    memcpy(sb->data + off, &v, 4);
}

/* Pad current position to 4-byte alignment */
static void sb_align4(SymBuf* sb) {
    while (sb->size & 3) sb_append_u8(sb, 0xF1 + (BYTE)((sb->size & 3) - 1));
}

static void sb_free(SymBuf* sb) { free(sb->data); }

/* ================================================================ */
/*  CodeView record emitters                                         */
/* ================================================================ */

/*
 * Emit S_GPROC32 record. Returns the buffer offset of the pEnd field
 * (so it can be patched after emitting S_END).
 */
static DWORD emit_gproc32(SymBuf* sb, const char* name, WORD section,
                           DWORD offset, DWORD codeSize) {
    DWORD recStart = sb->size;
    sb_append_u16(sb, 0);           /* reclen placeholder */
    sb_append_u16(sb, S_GPROC32);   /* rectyp */
    sb_append_u32(sb, 0);           /* pParent */
    DWORD pEndPos = sb->size;
    sb_append_u32(sb, 0);           /* pEnd (patched later) */
    sb_append_u32(sb, 0);           /* pNext */
    sb_append_u32(sb, codeSize);    /* len */
    sb_append_u32(sb, 0);           /* DbgStart */
    sb_append_u32(sb, codeSize > 0 ? codeSize - 1 : 0); /* DbgEnd */
    sb_append_u32(sb, T_NOTYPE);    /* typind (function type) */
    sb_append_u32(sb, offset);      /* off (offset in section) */
    sb_append_u16(sb, section);     /* seg (1-based section) */
    sb_append_u8(sb, 0);           /* flags */
    sb_append_str(sb, name);
    sb_align4(sb);
    /* Patch reclen: total bytes after reclen field */
    sb_patch_u16(sb, recStart, (WORD)(sb->size - recStart - 2));
    return pEndPos;
}

static void emit_regrel32(SymBuf* sb, const char* name, DWORD typeIdx,
                           WORD reg, long offset) {
    DWORD recStart = sb->size;
    sb_append_u16(sb, 0);
    sb_append_u16(sb, S_REGREL32);
    sb_append_u32(sb, (DWORD)offset);   /* offset from register */
    sb_append_u32(sb, typeIdx);
    sb_append_u16(sb, reg);
    sb_append_str(sb, name);
    sb_align4(sb);
    sb_patch_u16(sb, recStart, (WORD)(sb->size - recStart - 2));
}

static void emit_register(SymBuf* sb, const char* name, DWORD typeIdx, WORD reg) {
    DWORD recStart = sb->size;
    sb_append_u16(sb, 0);
    sb_append_u16(sb, S_REGISTER_SYM);
    sb_append_u32(sb, typeIdx);
    sb_append_u16(sb, reg);
    sb_append_str(sb, name);
    sb_align4(sb);
    sb_patch_u16(sb, recStart, (WORD)(sb->size - recStart - 2));
}

static void emit_end(SymBuf* sb) {
    sb_append_u16(sb, 2);      /* reclen = 2 (just rectyp) */
    sb_append_u16(sb, S_END);
}

/* ================================================================ */
/*  PE section parser                                                */
/* ================================================================ */

static int ParsePE(const char* path, SectionInfo** outSections, int* outCount) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "Cannot open PE: %s\n", path); return 0; }

    /* DOS header */
    IMAGE_DOS_HEADER dos;
    fread(&dos, sizeof(dos), 1, f);
    if (dos.e_magic != IMAGE_DOS_SIGNATURE) { fclose(f); return 0; }

    /* NT headers */
    fseek(f, dos.e_lfanew, SEEK_SET);
    IMAGE_NT_HEADERS64 nt;
    fread(&nt, sizeof(nt), 1, f);
    if (nt.Signature != IMAGE_NT_SIGNATURE) { fclose(f); return 0; }

    int numSections = nt.FileHeader.NumberOfSections;
    *outSections = (SectionInfo*)calloc(numSections, sizeof(SectionInfo));
    *outCount = numSections;

    /* Section headers follow immediately after optional header */
    long secOffset = dos.e_lfanew + 4 + sizeof(IMAGE_FILE_HEADER)
                     + nt.FileHeader.SizeOfOptionalHeader;
    fseek(f, secOffset, SEEK_SET);

    for (int i = 0; i < numSections; i++) {
        IMAGE_SECTION_HEADER sec;
        fread(&sec, sizeof(sec), 1, f);
        (*outSections)[i].virtualAddress = sec.VirtualAddress;
        (*outSections)[i].virtualSize = sec.Misc.VirtualSize;
        (*outSections)[i].characteristics = sec.Characteristics;
    }

    fclose(f);
    return 1;
}

/* Convert RVA to section:offset pair (section is 1-based) */
static int RvaToSection(DWORD rva, SectionInfo* sections, int numSections,
                         WORD* outSection, DWORD* outOffset) {
    for (int i = 0; i < numSections; i++) {
        if (rva >= sections[i].virtualAddress &&
            rva < sections[i].virtualAddress + sections[i].virtualSize) {
            *outSection = (WORD)(i + 1);
            *outOffset = rva - sections[i].virtualAddress;
            return 1;
        }
    }
    return 0;
}

/* ================================================================ */
/*  Type name -> CodeView type index                                 */
/* ================================================================ */

static DWORD MapTypeIndex(const char* typeName) {
    if (!typeName || !*typeName) return T_NOTYPE;

    /* Check for pointer types first */
    size_t len = strlen(typeName);
    if (len > 1 && typeName[len - 1] == '*') {
        /* Specific pointer types */
        if (strstr(typeName, "char") && !strstr(typeName, "unsigned"))
            return T_64PCHAR;
        if (strstr(typeName, "uchar") || strstr(typeName, "unsigned char"))
            return T_64PUCHAR;
        if (strstr(typeName, "int") && !strstr(typeName, "unsigned"))
            return T_64PINT4;
        if (strstr(typeName, "uint") || strstr(typeName, "unsigned int"))
            return T_64PUINT4;
        return T_64PVOID;  /* generic pointer */
    }

    /* Scalar types */
    if (strcmp(typeName, "void") == 0)      return T_VOID;
    if (strcmp(typeName, "char") == 0)      return T_CHAR;
    if (strcmp(typeName, "uchar") == 0)     return T_UCHAR;
    if (strcmp(typeName, "unsigned char") == 0) return T_UCHAR;
    if (strcmp(typeName, "short") == 0)     return T_SHORT;
    if (strcmp(typeName, "ushort") == 0)    return T_USHORT;
    if (strcmp(typeName, "unsigned short") == 0) return T_USHORT;
    if (strcmp(typeName, "int") == 0)       return T_INT4;
    if (strcmp(typeName, "uint") == 0)      return T_UINT4;
    if (strcmp(typeName, "unsigned int") == 0)  return T_UINT4;
    if (strcmp(typeName, "long") == 0)      return T_LONG;
    if (strcmp(typeName, "ulong") == 0)     return T_ULONG;
    if (strcmp(typeName, "unsigned long") == 0) return T_ULONG;
    if (strcmp(typeName, "longlong") == 0)  return T_INT8;
    if (strcmp(typeName, "long long") == 0) return T_INT8;
    if (strcmp(typeName, "__int64") == 0)   return T_INT8;
    if (strcmp(typeName, "ulonglong") == 0) return T_UINT8;
    if (strcmp(typeName, "unsigned long long") == 0) return T_UINT8;
    if (strcmp(typeName, "float") == 0)     return T_REAL32;
    if (strcmp(typeName, "double") == 0)    return T_REAL64;
    if (strcmp(typeName, "bool") == 0)      return T_BOOL08;
    if (strcmp(typeName, "BOOL") == 0)      return T_INT4;
    if (strcmp(typeName, "DWORD") == 0)     return T_UINT4;
    if (strcmp(typeName, "WORD") == 0)      return T_USHORT;
    if (strcmp(typeName, "BYTE") == 0)      return T_UCHAR;

    /* Size-based fallbacks for Ghidra's undefined types */
    if (strcmp(typeName, "undefined1") == 0) return T_UCHAR;
    if (strcmp(typeName, "undefined2") == 0) return T_USHORT;
    if (strcmp(typeName, "undefined4") == 0) return T_UINT4;
    if (strcmp(typeName, "undefined8") == 0) return T_UINT8;

    return T_NOTYPE;
}

/* ================================================================ */
/*  Register name -> CodeView register ID                            */
/* ================================================================ */

static WORD MapRegister(const char* name) {
    if (!name) return 0;
    if (_stricmp(name, "RAX") == 0) return CV_AMD64_RAX;
    if (_stricmp(name, "RBX") == 0) return CV_AMD64_RBX;
    if (_stricmp(name, "RCX") == 0) return CV_AMD64_RCX;
    if (_stricmp(name, "RDX") == 0) return CV_AMD64_RDX;
    if (_stricmp(name, "RSI") == 0) return CV_AMD64_RSI;
    if (_stricmp(name, "RDI") == 0) return CV_AMD64_RDI;
    if (_stricmp(name, "RBP") == 0) return CV_AMD64_RBP;
    if (_stricmp(name, "RSP") == 0) return CV_AMD64_RSP;
    if (_stricmp(name, "R8")  == 0) return CV_AMD64_R8;
    if (_stricmp(name, "R9")  == 0) return CV_AMD64_R9;
    if (_stricmp(name, "R10") == 0) return CV_AMD64_R10;
    if (_stricmp(name, "R11") == 0) return CV_AMD64_R11;
    if (_stricmp(name, "R12") == 0) return CV_AMD64_R12;
    if (_stricmp(name, "R13") == 0) return CV_AMD64_R13;
    if (_stricmp(name, "R14") == 0) return CV_AMD64_R14;
    if (_stricmp(name, "R15") == 0) return CV_AMD64_R15;
    return 0;
}

/* ================================================================ */
/*  Symbol map parser                                                */
/* ================================================================ */

static FuncInfo* ParseSymbolMap(const char* path, int* outCount) {
    FILE* f = fopen(path, "r");
    if (!f) { fprintf(stderr, "Cannot open symbol map: %s\n", path); return NULL; }

    FuncInfo* funcs = (FuncInfo*)calloc(MAX_FUNCS, sizeof(FuncInfo));
    int count = 0;
    char line[1024];

    while (fgets(line, sizeof(line), f) && count < MAX_FUNCS) {
        /* Strip newline */
        size_t len = strlen(line);
        while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = 0;

        if (line[0] == '#' || line[0] == 0) continue;

        if (strncmp(line, "FUNC\t", 5) == 0) {
            /* FUNC<TAB>name<TAB>RVA<TAB>codeSize<TAB>paramCount */
            FuncInfo* fn = &funcs[count];
            char* p = line + 5;
            char* tab;

            /* name */
            tab = strchr(p, '\t');
            if (!tab) continue;
            *tab = 0;
            strncpy(fn->name, p, MAX_NAME - 1);
            p = tab + 1;

            /* RVA */
            tab = strchr(p, '\t');
            if (!tab) continue;
            *tab = 0;
            fn->rva = atol(p);
            p = tab + 1;

            /* codeSize */
            tab = strchr(p, '\t');
            if (!tab) continue;
            *tab = 0;
            fn->codeSize = atol(p);
            p = tab + 1;

            /* paramCount */
            fn->paramCount = atoi(p);
            if (fn->paramCount > MAX_PARAMS) fn->paramCount = MAX_PARAMS;

            /* Read PARAM lines */
            for (int i = 0; i < fn->paramCount; i++) {
                if (!fgets(line, sizeof(line), f)) break;
                len = strlen(line);
                while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = 0;

                if (strncmp(line, "PARAM\t", 6) != 0) { i--; continue; }

                ParamInfo* pm = &fn->params[i];
                p = line + 6;

                /* name */
                tab = strchr(p, '\t');
                if (!tab) continue;
                *tab = 0;
                strncpy(pm->name, p, MAX_NAME - 1);
                p = tab + 1;

                /* type */
                tab = strchr(p, '\t');
                if (!tab) continue;
                *tab = 0;
                strncpy(pm->typeName, p, MAX_TYPE - 1);
                p = tab + 1;

                /* storage: REG:name or STACK:offset */
                if (strncmp(p, "REG:", 4) == 0) {
                    pm->kind = STOR_REG;
                    strncpy(pm->regName, p + 4, sizeof(pm->regName) - 1);
                } else if (strncmp(p, "STACK:", 6) == 0) {
                    pm->kind = STOR_STACK;
                    pm->offset = atol(p + 6);
                } else {
                    pm->kind = STOR_UNKNOWN;
                }
            }
            count++;
        } else {
            /* Legacy format: name<TAB>RVA (no params) */
            char* tab = strchr(line, '\t');
            if (tab) {
                *tab = 0;
                FuncInfo* fn = &funcs[count];
                strncpy(fn->name, line, MAX_NAME - 1);
                fn->rva = atol(tab + 1);
                fn->codeSize = 0;
                fn->paramCount = 0;
                count++;
            }
        }
    }

    fclose(f);
    *outCount = count;
    return funcs;
}

/* ================================================================ */
/*  Find mspdb140.dll                                                */
/* ================================================================ */

static HMODULE LoadMsPdb(void) {
    /* Try PATH first (works from Developer Command Prompt) */
    HMODULE h = LoadLibraryA("mspdb140.dll");
    if (h) return h;

    /* Try via VCToolsInstallDir environment variable */
    char path[MAX_PATH];
    DWORD len = GetEnvironmentVariableA("VCToolsInstallDir", path, MAX_PATH);
    if (len > 0 && len < MAX_PATH - 50) {
        strcat(path, "bin\\Hostx64\\x64\\mspdb140.dll");
        h = LoadLibraryA(path);
        if (h) return h;
    }

    fprintf(stderr, "ERROR: Cannot find mspdb140.dll\n");
    fprintf(stderr, "Run from a Developer Command Prompt for Visual Studio,\n");
    fprintf(stderr, "or set VCToolsInstallDir to your MSVC tools directory.\n");
    return NULL;
}

/* ================================================================ */
/*  Main PDB creation logic                                          */
/* ================================================================ */

static int CreatePDB(const char* exePath, const char* mapPath, const char* pdbPath) {
    /* Load mspdb140.dll */
    HMODULE hMsPdb = LoadMsPdb();
    if (!hMsPdb) return 0;

    PDBOpen2W_fn pfnOpen = (PDBOpen2W_fn)GetProcAddress(hMsPdb, "PDBOpen2W");
    if (!pfnOpen) {
        fprintf(stderr, "ERROR: PDBOpen2W not found in mspdb140.dll\n");
        return 0;
    }

    /* Parse PE sections */
    SectionInfo* sections = NULL;
    int numSections = 0;
    if (!ParsePE(exePath, &sections, &numSections)) {
        fprintf(stderr, "ERROR: Failed to parse PE: %s\n", exePath);
        return 0;
    }
    printf("PE: %d sections\n", numSections);

    /* Parse symbol map */
    int numFuncs = 0;
    FuncInfo* funcs = ParseSymbolMap(mapPath, &numFuncs);
    if (!funcs || numFuncs == 0) {
        fprintf(stderr, "ERROR: No functions in symbol map: %s\n", mapPath);
        free(sections);
        return 0;
    }

    int totalParams = 0;
    for (int i = 0; i < numFuncs; i++) totalParams += funcs[i].paramCount;
    printf("Symbol map: %d functions, %d parameters\n", numFuncs, totalParams);

    /* Convert PDB path to wide string */
    wchar_t wPdbPath[MAX_PATH];
    MultiByteToWideChar(CP_ACP, 0, pdbPath, -1, wPdbPath, MAX_PATH);

    /* Create PDB */
    void* pdb = NULL;
    long ec = 0;
    wchar_t errBuf[1024] = {0};

    printf("Calling PDBOpen2W...\n"); fflush(stdout);
    if (!pfnOpen(wPdbPath, "w", &ec, errBuf, sizeof(errBuf)/sizeof(wchar_t), &pdb) || !pdb) {
        fprintf(stderr, "ERROR: PDBOpen2W failed (ec=%ld): %ls\n", ec, errBuf);
        free(sections); free(funcs);
        return 0;
    }
    printf("PDBOpen2W ok, pdb=%p\n", pdb); fflush(stdout);

    /* Verify interface version */
    printf("Querying interface version...\n"); fflush(stdout);
    int intv = PDB_QueryInterfaceVersion(pdb);
    printf("PDB interface version: %d\n", intv); fflush(stdout);

    /* Probe every vtable index 4..12 with OpenDBI signature */
    printf("Probing vtable for OpenDBI...\n"); fflush(stdout);
    void* dbi = NULL;
    BOOL dbiOk = FALSE;
    for (int idx = 4; idx <= 12 && !dbiOk; idx++) {
        dbi = NULL;
        __try {
            typedef BOOL (*fn)(void*, const char*, const char*, void**);
            BOOL r = ((fn)vtbl(pdb)[idx])(pdb, NULL, "w", &dbi);
            printf("  vtable[%d]: returned %d, dbi=%p\n", idx, r, dbi); fflush(stdout);
            if (r && dbi) {
                dbiOk = TRUE;
                printf("  >>> OpenDBI is at vtable[%d]!\n", idx); fflush(stdout);
            }
        } __except(EXCEPTION_EXECUTE_HANDLER) {
            printf("  vtable[%d]: CRASH 0x%08lX\n", idx, GetExceptionCode()); fflush(stdout);
        }
    }

    if (!dbiOk || !dbi) {
        fprintf(stderr, "ERROR: PDB::OpenDBI not found in vtable\n");
        PDB_Close(pdb);
        free(sections); free(funcs);
        return 0;
    }

    /* Add PE sections to DBI */
    for (int i = 0; i < numSections; i++) {
        DBI_AddSec(dbi, (USHORT)(i + 1),
                   (USHORT)(sections[i].characteristics >> 16),
                   0, sections[i].virtualSize);
    }

    /* Open a module */
    void* mod = NULL;
    if (!DBI_OpenMod(dbi, exePath, exePath, &mod) || !mod) {
        fprintf(stderr, "ERROR: DBI::OpenMod failed\n");
        DBI_Close(dbi); PDB_Close(pdb);
        free(sections); free(funcs);
        return 0;
    }

    /* Build CodeView symbol buffer */
    SymBuf sb;
    sb_init(&sb);

    int addedFuncs = 0;
    int addedParams = 0;

    for (int i = 0; i < numFuncs; i++) {
        FuncInfo* fn = &funcs[i];

        /* Convert RVA to section:offset */
        WORD section; DWORD secOffset;
        if (!RvaToSection((DWORD)fn->rva, sections, numSections, &section, &secOffset))
            continue;

        /* Emit S_GPROC32 */
        DWORD pEndPatch = emit_gproc32(&sb, fn->name, section, secOffset,
                                        (DWORD)fn->codeSize);

        /* Emit parameter records */
        for (int j = 0; j < fn->paramCount; j++) {
            ParamInfo* pm = &fn->params[j];
            DWORD typeIdx = MapTypeIndex(pm->typeName);

            if (pm->kind == STOR_REG) {
                WORD cvReg = MapRegister(pm->regName);
                if (cvReg) {
                    emit_register(&sb, pm->name, typeIdx, cvReg);
                    addedParams++;
                }
            } else if (pm->kind == STOR_STACK) {
                /* Stack params are RSP-relative */
                emit_regrel32(&sb, pm->name, typeIdx, CV_AMD64_RSP, pm->offset);
                addedParams++;
            }
            /* STOR_UNKNOWN: skip */
        }

        /* Emit S_END and patch pEnd in S_GPROC32 */
        DWORD endPos = sb.size;
        emit_end(&sb);
        sb_patch_u32(&sb, pEndPatch, endPos);

        /* Add public symbol */
        DBI_AddPublic(dbi, fn->name, section, secOffset);

        /* Add section contribution for this function */
        if (fn->codeSize > 0) {
            MOD_AddSecContrib(mod, section, secOffset, (long)fn->codeSize,
                              sections[section - 1].characteristics);
        }

        addedFuncs++;
    }

    printf("Built %d function records with %d parameter records\n", addedFuncs, addedParams);

    /* Submit symbols to module */
    if (!MOD_AddSymbols(mod, sb.data, (long)sb.size)) {
        fprintf(stderr, "WARNING: Mod::AddSymbols failed\n");
    }

    sb_free(&sb);

    /* Close module, DBI, PDB */
    MOD_Close(mod);
    DBI_Close(dbi);

    if (!PDB_Commit(pdb)) {
        fprintf(stderr, "ERROR: PDB::Commit failed\n");
        PDB_Close(pdb);
        free(sections); free(funcs);
        return 0;
    }

    PDB_Close(pdb);
    free(sections);
    free(funcs);

    printf("PDB written to: %s\n", pdbPath);
    return 1;
}

/* ================================================================ */
/*  Entry point                                                      */
/* ================================================================ */

int main(int argc, char** argv) {
    if (argc != 4) {
        fprintf(stderr, "Usage: pdb_writer.exe <target.exe> <symbols.txt> <output.pdb>\n");
        fprintf(stderr, "\nCreates a PDB with function and parameter symbols.\n");
        fprintf(stderr, "The symbol map should be in extended v2 format (FUNC/PARAM lines)\n");
        fprintf(stderr, "generated by MatchFunctions.java.\n");
        fprintf(stderr, "\nMust be run from a Developer Command Prompt for Visual Studio.\n");
        return 1;
    }

    return CreatePDB(argv[1], argv[2], argv[3]) ? 0 : 1;
}
