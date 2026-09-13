#include "../crash_protector.c"
#include <assert.h>
static ULONG testFlags=SYMFLAG_EXPORT;
static const char* testName="Ordinal42";
static BOOL WINAPI FakeSymFromAddr(HANDLE proc,DWORD64 addr,PDWORD64 disp,PSYMBOL_INFO sym) {
    (void)proc;(void)addr;*disp=0x123456; sym->Flags=testFlags;
    strcpy_s(sym->Name,sym->MaxNameLen,testName);
    return TRUE;
}
int main(void) {
    char path[MAX_PATH];GetModuleFileNameA(NULL,path,MAX_PATH);
    strcpy_s(strrchr(path,'\\')+1,MAX_PATH-(strrchr(path,'\\')+1-path),"symbols.txt");
    FILE* file=NULL;assert(fopen_s(&file,path,"wb")==0);
    fputs("FUNC\tunused\t16\t1\t0\n",file);
    for(int i=0;i<70000;i++) fputs("PARAM\twrong\tint\tUNKNOWN\n",file);
    fputs("FUNC\tDetailedGameFunction\t256\t16\t1\nPARAM\texpected\tint\tUNKNOWN\n",file);
    fclose(file);LoadSymbolsTxt();
    assert(g_txtFuncCount==2 && g_txtParamCount==70001);
    const TxtFunc* func=TxtFindFunc(256);assert(func && func->paramStart==70000);
    CONTEXT ctx={0};char params[80];
    TxtCollectFrameParams(func,&ctx,GetCurrentProcess(),TRUE,params,sizeof(params));
    assert(strcmp(params,"expected=?")==0);
    DWORD64 base=(DWORD64)GetModuleHandleA(NULL);
    char buffer[sizeof(SYMBOL_INFO)+MAX_SYM_NAME];g_SymFromAddr=FakeSymFromAddr;
    assert(strcmp(ResolveSymbolInner(GetCurrentProcess(),base+256,buffer,sizeof(buffer)),"DetailedGameFunction")==0);
    testFlags=0;
    /* Real Windows DbgHelp returns Ordinal42 with no export flag for WC3. */
    assert(strcmp(ResolveSymbolInner(GetCurrentProcess(),base+256,buffer,sizeof(buffer)),"DetailedGameFunction")==0);
    assert(strcmp(ResolveSymbolInner(GetCurrentProcess(),base+272,buffer,sizeof(buffer)),"???")==0);
    assert(IsOrdinalSymbolName("Ordinal1") && IsOrdinalSymbolName("Ordinal42"));
    assert(!IsOrdinalSymbolName("Ordinal") && !IsOrdinalSymbolName("Ordinal42Helper"));
    testName="RealPdbFunction";
    assert(strcmp(ResolveSymbolInner(GetCurrentProcess(),base+256,buffer,sizeof(buffer)),"RealPdbFunction")==0);
    testFlags=SYMFLAG_EXPORT;testName="Ordinal42";
    assert(strcmp(ResolveSymbolInner(GetCurrentProcess(),base+272,buffer,sizeof(buffer)),"???")==0);
    testName="Ordinal1";
    assert(strcmp(ResolveSymbolInner(GetCurrentProcess(),base+272,buffer,sizeof(buffer)),"???")==0);
    testName="NamedExport";
    assert(strcmp(ResolveSymbolInner(GetCurrentProcess(),base+272,buffer,sizeof(buffer)),"NamedExport")==0);
    assert(TxtFindFuncForAddress(base-1)==NULL);
    assert(TxtFindFuncForAddress(base+0x100000000ULL+256)==NULL);
    g_SymFromAddr=NULL;
    assert(strcmp(ResolveSymbolInner(GetCurrentProcess(),base+0x100000000ULL+256,buffer,sizeof(buffer)),"???")==0);
    puts("PASS: text symbols outrank flagged exports and unflagged ordinal placeholders; real PDB names win; parameter index 70000 survives parsing; DLL addresses cannot alias main-exe RVAs.");
    return 0;
}
