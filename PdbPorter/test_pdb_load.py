"""Test if dbghelp can load symbols from our generated PDB."""
import ctypes
import ctypes.wintypes as wt
import struct
import os

SYMOPT_UNDNAME = 0x00000002
SYMOPT_LOAD_ANYTHING = 0x00000040
SYMOPT_DEFERRED_LOADS = 0x00000004
MAX_SYM_NAME = 2000

dbghelp = ctypes.WinDLL("dbghelp.dll")
kernel32 = ctypes.WinDLL("kernel32.dll")
kernel32.GetCurrentProcess.restype = wt.HANDLE
dbghelp.SymSetOptions.argtypes = [wt.DWORD]
dbghelp.SymSetOptions.restype = wt.DWORD
dbghelp.SymInitializeW.argtypes = [wt.HANDLE, wt.LPCWSTR, wt.BOOL]
dbghelp.SymInitializeW.restype = wt.BOOL
dbghelp.SymLoadModuleExW.argtypes = [
    wt.HANDLE, wt.HANDLE, wt.LPCWSTR, wt.LPCWSTR,
    ctypes.c_uint64, wt.DWORD, ctypes.c_void_p, wt.DWORD,
]
dbghelp.SymLoadModuleExW.restype = ctypes.c_uint64
dbghelp.SymUnloadModule64.argtypes = [wt.HANDLE, ctypes.c_uint64]
dbghelp.SymCleanup.argtypes = [wt.HANDLE]

class SYMBOL_INFOW(ctypes.Structure):
    _fields_ = [
        ("SizeOfStruct", ctypes.c_uint32),
        ("TypeIndex", ctypes.c_uint32),
        ("Reserved", ctypes.c_uint64 * 2),
        ("Index", ctypes.c_uint32),
        ("Size", ctypes.c_uint32),
        ("ModBase", ctypes.c_uint64),
        ("Flags", ctypes.c_uint32),
        ("Value", ctypes.c_uint64),
        ("Address", ctypes.c_uint64),
        ("Register", ctypes.c_uint32),
        ("Scope", ctypes.c_uint32),
        ("Tag", ctypes.c_uint32),
        ("NameLen", ctypes.c_uint32),
        ("MaxNameLen", ctypes.c_uint32),
        ("Name", ctypes.c_wchar * MAX_SYM_NAME),
    ]

dbghelp.SymFromAddrW.argtypes = [
    wt.HANDLE, ctypes.c_uint64, ctypes.POINTER(ctypes.c_uint64),
    ctypes.POINTER(SYMBOL_INFOW),
]
dbghelp.SymFromAddrW.restype = wt.BOOL

SYM_ENUM_CALLBACK_W = ctypes.WINFUNCTYPE(
    wt.BOOL, ctypes.POINTER(SYMBOL_INFOW), ctypes.c_ulong, ctypes.c_void_p,
)
dbghelp.SymEnumSymbolsW.argtypes = [
    wt.HANDLE, ctypes.c_uint64, wt.LPCWSTR, SYM_ENUM_CALLBACK_W, ctypes.c_void_p,
]
dbghelp.SymEnumSymbolsW.restype = wt.BOOL

exe_path = os.path.abspath("Warcraft III.exe")
pdb_dir = os.path.dirname(os.path.abspath("Warcraft III.new.pdb"))

process = kernel32.GetCurrentProcess()
dbghelp.SymSetOptions(SYMOPT_UNDNAME | SYMOPT_LOAD_ANYTHING | SYMOPT_DEFERRED_LOADS)

if not dbghelp.SymInitializeW(process, pdb_dir, False):
    print(f"SymInitializeW failed: {ctypes.GetLastError()}")
    exit(1)

base = 0x140000000
mod = dbghelp.SymLoadModuleExW(process, None, exe_path, None, base, 0, None, 0)
print(f"SymLoadModuleExW: mod=0x{mod:x} err={ctypes.GetLastError()}")

if not mod:
    dbghelp.SymCleanup(process)
    exit(1)

# Count total symbols
count = [0]
@SYM_ENUM_CALLBACK_W
def count_cb(sym_ptr, sym_size, ctx):
    count[0] += 1
    return True

dbghelp.SymEnumSymbolsW(process, mod, "*", count_cb, None)
print(f"Total symbols enumerated: {count[0]}")

# Test SymFromAddr with a few known RVAs from quick_symbols.txt
test_rvas = []
with open("quick_symbols.txt") as f:
    for line in f:
        if line.startswith("FUNC\t"):
            parts = line.strip().split("\t")
            test_rvas.append(int(parts[2]))
            if len(test_rvas) >= 10:
                break

print(f"\nTesting SymFromAddr with {len(test_rvas)} addresses:")
sym_info = SYMBOL_INFOW()
sym_info.SizeOfStruct = 88  # sizeof(SYMBOL_INFOW) without the Name field
sym_info.MaxNameLen = MAX_SYM_NAME

for rva in test_rvas:
    addr = base + rva
    disp = ctypes.c_uint64(0)
    ok = dbghelp.SymFromAddrW(process, addr, ctypes.byref(disp), ctypes.byref(sym_info))
    if ok:
        print(f"  0x{rva:x} -> {sym_info.Name} (+{disp.value})")
    else:
        print(f"  0x{rva:x} -> FAILED (err={ctypes.GetLastError()})")

dbghelp.SymUnloadModule64(process, mod)
dbghelp.SymCleanup(process)
