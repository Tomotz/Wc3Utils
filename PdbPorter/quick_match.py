#!/usr/bin/env python3
"""
Quick function matcher: search for old binary's function bytes in the new binary.
No Ghidra needed — uses Windows dbghelp.dll to parse the PDB and does
exact + normalized byte matching.

Usage:
    python quick_match.py old.exe new.exe -o symbols.txt
"""

import argparse
import ctypes
import ctypes.wintypes as wt
import hashlib
import os
import pickle
import shutil
import struct
import subprocess
import sys
import tempfile
import bisect
from collections import defaultdict

# ---------------------------------------------------------------------------
# dbghelp PDB parsing
# ---------------------------------------------------------------------------

SYMOPT_UNDNAME        = 0x00000002
SYMOPT_DEFERRED_LOADS = 0x00000004
SYMOPT_LOAD_ANYTHING  = 0x00000040
MAX_SYM_NAME          = 2000
SYM_TAG_FUNCTION      = 5
SYM_TAG_THUNK         = 8
SYMFLAG_REGISTER      = 0x00000008
SYMFLAG_REGREL        = 0x00000010
SYMFLAG_PARAMETER     = 0x00000040

# CV_HREG_e register IDs for AMD64
# other register values can be found here https://fossies.org/linux/llvm-project/llvm/include/llvm/DebugInfo/CodeView/CodeViewRegisters.def
CV_REG_NAMES = {
    328: 'RAX', 329: 'RBX', 330: 'RCX', 331: 'RDX',
    332: 'RSI', 333: 'RDI', 334: 'RBP', 335: 'RSP',
    336: 'R8',  337: 'R9',  338: 'R10', 339: 'R11',
    340: 'R12', 341: 'R13', 342: 'R14', 343: 'R15',
    154: 'XMM0', 155: 'XMM1', 156: 'XMM2', 157: 'XMM3',
}

# SymGetTypeInfo request codes
TI_GET_SYMTAG   = 0
TI_GET_LENGTH   = 2
TI_GET_TYPEID   = 4
TI_GET_BASETYPE = 5
TI_GET_SYMNAME  = 14

# SymTagEnum values
SYMTAG_BASETYPE    = 16
SYMTAG_POINTERTYPE = 14
SYMTAG_UDT         = 11
SYMTAG_ENUM        = 12
SYMTAG_TYPEDEF     = 17

# btXxx base type values -> names (keyed by (baseType, byteSize))
BASE_TYPE_MAP = {
    (0, 0): 'void', (1, 1): 'char', (2, 2): 'wchar_t',
    (6, 1): 'int8_t', (6, 2): 'short', (6, 4): 'int', (6, 8): 'int64_t',
    (7, 1): 'uint8_t', (7, 2): 'unsigned short', (7, 4): 'unsigned int', (7, 8): 'uint64_t',
    (8, 4): 'float', (8, 8): 'double',
    (10, 1): 'bool', (10, 4): 'BOOL',
    (13, 4): 'long', (13, 8): 'int64_t',
    (14, 4): 'unsigned long', (14, 8): 'uint64_t',
    (31, 1): 'char',
}

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
dbghelp.SymUnloadModule64.restype = wt.BOOL
dbghelp.SymCleanup.argtypes = [wt.HANDLE]
dbghelp.SymCleanup.restype = wt.BOOL
dbghelp.UnDecorateSymbolNameW.argtypes = [wt.LPCWSTR, ctypes.c_wchar_p, wt.DWORD, wt.DWORD]
dbghelp.UnDecorateSymbolNameW.restype = wt.DWORD

UNDNAME_COMPLETE = 0x0000

def _undecorate(name):
    """Undecorate a MSVC mangled name. Returns original if not decorated."""
    buf = ctypes.create_unicode_buffer(MAX_SYM_NAME)
    result = dbghelp.UnDecorateSymbolNameW(name, buf, MAX_SYM_NAME, UNDNAME_COMPLETE)
    return buf.value if result else name


def _likely_member_function(name, params):
    """Heuristic: does this function likely have an implicit 'this' in RCX?

    The PDB sometimes lists 'this' as a parameter (e.g. compiler-generated
    funclets like dtor$N), but usually omits it.  We detect member functions by:
      1. Name must contain '::' (scoped).
      2. PDB must not already provide a 'this' parameter.
      3. If there are explicit params, none may use RCX (because 'this' occupies it).
      4. If 0 explicit params, exclude known non-member patterns
         (dynamic initializers, dynamic atexit destructors).
    """
    if '::' not in name:
        return False
    if 'dynamic initializer for' in name or 'dynamic atexit destructor' in name:
        return False
    if params:
        # If PDB already provides 'this', or any param uses RCX → skip.
        if any(pname == 'this' or storage == 'REG:RCX'
               for pname, _, storage in params):
            return False
    return True


def _extract_class_name(display_name):
    """Extract the class/struct name from an undecorated 'Class::Method' name.

    Handles nested templates by tracking angle bracket depth.
    Returns the class portion, or None if no :: found.
    """
    # Find the last '::' that is not inside angle brackets
    depth = 0
    i = len(display_name) - 1
    while i >= 1:
        ch = display_name[i]
        if ch == '>':
            depth += 1
        elif ch == '<':
            depth -= 1
        elif ch == ':' and display_name[i - 1] == ':' and depth == 0:
            return display_name[:i - 1]
        i -= 1
    return None


class SYMBOL_INFOW(ctypes.Structure):
    _fields_ = [
        ("SizeOfStruct", ctypes.c_uint32),
        ("TypeIndex",    ctypes.c_uint32),
        ("Reserved",     ctypes.c_uint64 * 2),
        ("Index",        ctypes.c_uint32),
        ("Size",         ctypes.c_uint32),
        ("ModBase",      ctypes.c_uint64),
        ("Flags",        ctypes.c_uint32),
        ("Value",        ctypes.c_uint64),
        ("Address",      ctypes.c_uint64),
        ("Register",     ctypes.c_uint32),
        ("Scope",        ctypes.c_uint32),
        ("Tag",          ctypes.c_uint32),
        ("NameLen",      ctypes.c_uint32),
        ("MaxNameLen",   ctypes.c_uint32),
        ("Name",         ctypes.c_wchar * MAX_SYM_NAME),
    ]


SYM_ENUM_CALLBACK_W = ctypes.WINFUNCTYPE(
    wt.BOOL, ctypes.POINTER(SYMBOL_INFOW), ctypes.c_ulong, ctypes.c_void_p,
)
dbghelp.SymEnumSymbolsW.argtypes = [
    wt.HANDLE, ctypes.c_uint64, wt.LPCWSTR, SYM_ENUM_CALLBACK_W, ctypes.c_void_p,
]
dbghelp.SymEnumSymbolsW.restype = wt.BOOL


class IMAGEHLP_STACK_FRAME(ctypes.Structure):
    _fields_ = [
        ("InstructionOffset",    ctypes.c_uint64),
        ("ReturnOffset",         ctypes.c_uint64),
        ("FrameOffset",          ctypes.c_uint64),
        ("StackOffset",          ctypes.c_uint64),
        ("BackingStoreOffset",   ctypes.c_uint64),
        ("FuncTableEntry",       ctypes.c_uint64),
        ("Params",               ctypes.c_uint64 * 4),
        ("Reserved",             ctypes.c_uint64 * 5),
        ("Virtual",              wt.BOOL),
        ("Reserved2",            wt.DWORD),
    ]

dbghelp.SymSetContext.argtypes = [wt.HANDLE, ctypes.POINTER(IMAGEHLP_STACK_FRAME), ctypes.c_void_p]
dbghelp.SymSetContext.restype = wt.BOOL

dbghelp.SymGetTypeInfo.argtypes = [wt.HANDLE, ctypes.c_uint64, ctypes.c_ulong, ctypes.c_int, ctypes.c_void_p]
dbghelp.SymGetTypeInfo.restype = wt.BOOL

kernel32.LocalFree.argtypes = [ctypes.c_void_p]
kernel32.LocalFree.restype = ctypes.c_void_p


def _resolve_type(process, mod_base, type_index, depth=0):
    """Resolve a dbghelp type index to a human-readable type name."""
    if type_index == 0 or depth > 8:
        return "unknown"

    tag = ctypes.c_ulong()
    if not dbghelp.SymGetTypeInfo(process, mod_base, type_index, TI_GET_SYMTAG, ctypes.byref(tag)):
        return "unknown"

    if tag.value == SYMTAG_BASETYPE:
        base = ctypes.c_ulong()
        length = ctypes.c_uint64()
        dbghelp.SymGetTypeInfo(process, mod_base, type_index, TI_GET_BASETYPE, ctypes.byref(base))
        dbghelp.SymGetTypeInfo(process, mod_base, type_index, TI_GET_LENGTH, ctypes.byref(length))
        return BASE_TYPE_MAP.get((base.value, length.value), f"type{length.value}")

    if tag.value == SYMTAG_POINTERTYPE:
        pointee = ctypes.c_ulong()
        if dbghelp.SymGetTypeInfo(process, mod_base, type_index, TI_GET_TYPEID, ctypes.byref(pointee)):
            return _resolve_type(process, mod_base, pointee.value, depth + 1) + " *"
        return "void *"

    if tag.value in (SYMTAG_UDT, SYMTAG_ENUM, SYMTAG_TYPEDEF):
        name_ptr = ctypes.c_wchar_p()
        if dbghelp.SymGetTypeInfo(process, mod_base, type_index, TI_GET_SYMNAME, ctypes.byref(name_ptr)):
            name = name_ptr.value
            kernel32.LocalFree(name_ptr)
            if tag.value == SYMTAG_TYPEDEF:
                # Resolve the underlying type for the name
                return name if name else "unknown"
            return name
        return "struct" if tag.value == SYMTAG_UDT else "enum"

    return "unknown"


def _get_storage(info):
    """Get parameter storage string from SYMBOL_INFOW.

    Formats:
      REG:<REG>                   - value is in a register
      STACK:<BASE>+<off>          - value is at [BASE + off]; off may be signed
                                    (e.g. STACK:RSP+16, STACK:RBP-8, STACK:RDX+224)
    """
    if info.Flags & SYMFLAG_REGISTER:
        return "REG:" + CV_REG_NAMES.get(info.Register, f"reg{info.Register}")
    if info.Flags & SYMFLAG_REGREL:
        base = CV_REG_NAMES.get(info.Register, f"reg{info.Register}")
        # Address is uint64 but represents a signed offset from the base register.
        off = info.Address
        if off >= (1 << 63):
            off -= (1 << 64)
        sign = "+" if off >= 0 else "-"
        return f"STACK:{base}{sign}{abs(off)}"
    return "UNKNOWN"


def load_function_params(exe_path, pdb_path, func_rvas):
    """Load parameter info for specific functions from the PDB.

    Returns dict: old_rva -> [(name, type, storage), ...]
    """
    if not func_rvas:
        return {}

    process = kernel32.GetCurrentProcess()
    dbghelp.SymSetOptions(SYMOPT_UNDNAME | SYMOPT_LOAD_ANYTHING | SYMOPT_DEFERRED_LOADS)

    # Handle PDB name mismatch (same as load_pdb_functions)
    with open(exe_path, 'rb') as f:
        pe_data = f.read()
    _, pe_sections = parse_pe_sections(pe_data)
    expected, _, _ = parse_pe_debug_info(pe_data, pe_sections)

    tmpdir = None
    search_path = os.path.dirname(os.path.abspath(pdb_path))
    if expected:
        actual = os.path.basename(pdb_path)
        if expected.lower() != actual.lower():
            tmpdir = tempfile.mkdtemp(prefix="quick_match_")
            shutil.copy2(os.path.abspath(pdb_path), os.path.join(tmpdir, expected))
            search_path = tmpdir

    if not dbghelp.SymInitializeW(process, search_path, False):
        return {}

    base = 0x10000000
    mod_base = dbghelp.SymLoadModuleExW(
        process, None, os.path.abspath(exe_path), None, base, 0, None, 0,
    )
    if not mod_base:
        dbghelp.SymCleanup(process)
        return {}

    # Shared list for callback
    params_list = []

    @SYM_ENUM_CALLBACK_W
    def param_cb(sym_ptr, sym_size, ctx):
        info = sym_ptr.contents
        if info.Flags & SYMFLAG_PARAMETER:
            name = info.Name
            type_name = _resolve_type(process, mod_base, info.TypeIndex)
            storage = _get_storage(info)
            params_list.append((name, type_name, storage))
        return True

    result = {}
    frame = IMAGEHLP_STACK_FRAME()

    for i, rva in enumerate(func_rvas):
        if i % 10000 == 0 and i > 0:
            print(f"\r  [{i}/{len(func_rvas)}] params loaded", end="", flush=True)

        frame.InstructionOffset = mod_base + rva
        if not dbghelp.SymSetContext(process, ctypes.byref(frame), None):
            continue

        params_list.clear()
        dbghelp.SymEnumSymbolsW(process, 0, "*", param_cb, None)

        if params_list:
            result[rva] = list(params_list)

    if len(func_rvas) > 10000:
        print()

    dbghelp.SymUnloadModule64(process, mod_base)
    dbghelp.SymCleanup(process)
    if tmpdir:
        shutil.rmtree(tmpdir, ignore_errors=True)

    return result


# ---------------------------------------------------------------------------
# PE helpers
# ---------------------------------------------------------------------------

def parse_pe_sections(data):
    """Parse PE section headers."""
    pe_offset = struct.unpack_from('<I', data, 0x3C)[0]
    coff_hdr = pe_offset + 4
    num_sections = struct.unpack_from('<H', data, coff_hdr + 2)[0]
    opt_size = struct.unpack_from('<H', data, coff_hdr + 16)[0]
    opt_hdr = coff_hdr + 20
    magic = struct.unpack_from('<H', data, opt_hdr)[0]
    image_base = struct.unpack_from('<Q', data, opt_hdr + 24)[0] if magic == 0x20b \
        else struct.unpack_from('<I', data, opt_hdr + 28)[0]

    sections = []
    sec_start = opt_hdr + opt_size
    for i in range(num_sections):
        off = sec_start + i * 40
        sections.append({
            'name': data[off:off+8].rstrip(b'\0').decode('ascii', errors='replace'),
            'va':         struct.unpack_from('<I', data, off + 12)[0],
            'vsize':      struct.unpack_from('<I', data, off +  8)[0],
            'raw_offset': struct.unpack_from('<I', data, off + 20)[0],
            'raw_size':   struct.unpack_from('<I', data, off + 16)[0],
        })
    return image_base, sections


def rva_to_file_offset(rva, sections):
    for s in sections:
        if s['va'] <= rva < s['va'] + s['raw_size']:
            return rva - s['va'] + s['raw_offset']
    return None


def read_bytes_at_rva(data, rva, size, sections):
    off = rva_to_file_offset(rva, sections)
    if off is None or off + size > len(data):
        return None
    return data[off:off+size]


def parse_pe_debug_info(data, sections):
    """Read RSDS CodeView record from PE debug directory.
    Returns (pdb_name, guid_bytes, age) or (None, None, None)."""
    pe_offset = struct.unpack_from('<I', data, 0x3C)[0]
    coff_hdr = pe_offset + 4
    opt_size = struct.unpack_from('<H', data, coff_hdr + 16)[0]
    opt_hdr = coff_hdr + 20
    magic = struct.unpack_from('<H', data, opt_hdr)[0]
    dd_off = opt_hdr + (112 if magic == 0x20b else 96) + 6 * 8
    debug_rva = struct.unpack_from('<I', data, dd_off)[0]
    debug_size = struct.unpack_from('<I', data, dd_off + 4)[0]
    if debug_rva == 0:
        return None, None, None
    debug_off = rva_to_file_offset(debug_rva, sections)
    if debug_off is None:
        return None, None, None
    for i in range(debug_size // 28):
        entry = debug_off + i * 28
        if struct.unpack_from('<I', data, entry + 12)[0] == 2:  # CODEVIEW
            cv_off = struct.unpack_from('<I', data, entry + 24)[0]
            if data[cv_off:cv_off+4] == b'RSDS':
                guid = data[cv_off+4:cv_off+20]       # 16-byte GUID
                age = struct.unpack_from('<I', data, cv_off+20)[0]
                path_start = cv_off + 24
                path_end = data.index(b'\0', path_start)
                name = os.path.basename(data[path_start:path_end].decode('utf-8', errors='replace'))
                return name, guid, age
    return None, None, None


# ---------------------------------------------------------------------------
# PDB loading via dbghelp
# ---------------------------------------------------------------------------

class PdbSession:
    """Holds an open dbghelp session for both function enumeration and param queries."""

    def __init__(self, exe_path, pdb_path):
        self.process = kernel32.GetCurrentProcess()
        self.mod_base = 0
        self.tmpdir = None
        self.decorated_names = {}  # rva -> decorated name for PDB output

        dbghelp.SymSetOptions(SYMOPT_LOAD_ANYTHING | SYMOPT_DEFERRED_LOADS)

        with open(exe_path, 'rb') as f:
            pe_data = f.read()
        _, pe_sections = parse_pe_sections(pe_data)
        expected, _, _ = parse_pe_debug_info(pe_data, pe_sections)

        search_path = os.path.dirname(os.path.abspath(pdb_path))
        if expected:
            actual = os.path.basename(pdb_path)
            if expected.lower() != actual.lower():
                self.tmpdir = tempfile.mkdtemp(prefix="quick_match_")
                shutil.copy2(os.path.abspath(pdb_path), os.path.join(self.tmpdir, expected))
                search_path = self.tmpdir
                print(f"  (PDB renamed: {actual} -> {expected})")

        if not dbghelp.SymInitializeW(self.process, search_path, False):
            sys.exit(f"SymInitializeW failed: {ctypes.GetLastError()}")

        base = 0x10000000
        self.mod_base = dbghelp.SymLoadModuleExW(
            self.process, None, os.path.abspath(exe_path), None, base, 0, None, 0,
        )
        if not self.mod_base:
            dbghelp.SymCleanup(self.process)
            sys.exit(f"SymLoadModuleExW failed: {ctypes.GetLastError()}")

    def enum_functions(self):
        """Enumerate all functions from the PDB.

        Returns (display_name, rva, size) tuples with undecorated names.
        Decorated (mangled) names are stored in self.decorated_names[rva].
        """
        functions = []

        @SYM_ENUM_CALLBACK_W
        def callback(sym_ptr, sym_size, ctx):
            info = sym_ptr.contents
            if info.Tag in (SYM_TAG_FUNCTION, SYM_TAG_THUNK) and info.Size > 0:
                decorated = info.Name
                rva = info.Address - self.mod_base
                display = _undecorate(decorated)
                self.decorated_names[rva] = decorated
                functions.append((display, rva, info.Size))
            return True

        dbghelp.SymEnumSymbolsW(self.process, self.mod_base, "*", callback, None)
        functions.sort(key=lambda x: x[1])
        return functions

    def get_params(self, func_rvas):
        """Get parameter info for specific functions. Returns dict: rva -> [(name, type, storage)]."""
        result = {}
        params_list = []
        process = self.process
        mod_base = self.mod_base

        @SYM_ENUM_CALLBACK_W
        def param_cb(sym_ptr, sym_size, ctx):
            info = sym_ptr.contents
            if info.Flags & SYMFLAG_PARAMETER:
                name = info.Name
                type_name = _resolve_type(process, mod_base, info.TypeIndex)
                storage = _get_storage(info)
                params_list.append((name, type_name, storage))
            return True

        frame = IMAGEHLP_STACK_FRAME()

        for i, rva in enumerate(func_rvas):
            if i % 10000 == 0 and i > 0:
                print(f"\r  [{i}/{len(func_rvas)}] {len(result)} with params", end="", flush=True)

            frame.InstructionOffset = mod_base + rva
            if not dbghelp.SymSetContext(process, ctypes.byref(frame), None):
                continue

            params_list.clear()
            dbghelp.SymEnumSymbolsW(process, 0, "*", param_cb, None)

            if params_list:
                result[rva] = list(params_list)

        if len(func_rvas) > 10000:
            print(f"\r  [{len(func_rvas)}/{len(func_rvas)}] {len(result)} with params")

        return result

    def close(self):
        if self.mod_base:
            dbghelp.SymUnloadModule64(self.process, self.mod_base)
            self.mod_base = 0
        dbghelp.SymCleanup(self.process)
        if self.tmpdir:
            shutil.rmtree(self.tmpdir, ignore_errors=True)
            self.tmpdir = None


# ---------------------------------------------------------------------------
# Byte normalization (zero out address-dependent bytes, no Capstone needed)
# ---------------------------------------------------------------------------

def normalize_bytes(raw: bytes) -> bytes:
    """Zero out address-dependent bytes in x86-64 code.

    Handles:
      - E8/E9 rel32          CALL/JMP rel32
      - 0F 80-8F rel32       Jcc rel32
      - 70-7F rel8, EB rel8  Jcc/JMP rel8
      - [RIP+disp32]         Any instruction with ModR/M mod=00 R/M=101
    """
    buf = bytearray(raw)
    i = 0
    n = len(buf)
    while i < n:
        start = i

        # --- Skip prefixes ---
        # Legacy prefixes
        while i < n and buf[i] in (0x66, 0x67, 0xF0, 0xF2, 0xF3,
                                    0x2E, 0x3E, 0x26, 0x36, 0x64, 0x65):
            i += 1
        # REX prefix (0x40-0x4F)
        rex = 0
        if i < n and 0x40 <= buf[i] <= 0x4F:
            rex = buf[i]
            i += 1

        if i >= n:
            break
        op = buf[i]
        i += 1

        # --- 1-byte opcodes with no ModR/M, no immediate ---
        # NOP, RET, leave, INT3, HLT, CLC/STC, etc.
        if op in (0x90, 0xC3, 0xCB, 0xC9, 0xCC, 0xF4, 0xF5, 0xF8, 0xF9,
                  0xFC, 0xFD, 0xFA, 0xFB, 0x9C, 0x9D, 0x9E, 0x9F, 0xCE, 0xCF,
                  0x98, 0x99, 0xD6, 0xF1):
            continue
        # PUSH/POP reg (50-5F)
        if 0x50 <= op <= 0x5F:
            continue
        # XCHG eax,reg (91-97)
        if 0x91 <= op <= 0x97:
            continue
        # CDQ/CWD/CBW variants covered by 0x98/0x99 above

        # --- CALL rel32 / JMP rel32 ---
        if op in (0xE8, 0xE9) and i + 3 < n:
            buf[i:i+4] = b'\x00\x00\x00\x00'
            i += 4
            continue

        # --- Jcc rel8 / JMP rel8 ---
        if (0x70 <= op <= 0x7F or op == 0xEB) and i < n:
            buf[i] = 0
            i += 1
            continue

        # --- LOOP/JCXZ rel8 ---
        if op in (0xE0, 0xE1, 0xE2, 0xE3) and i < n:
            buf[i] = 0
            i += 1
            continue

        # --- RET imm16 ---
        if op in (0xC2, 0xCA):
            i += 2
            continue

        # --- MOV reg, imm (B0-BF) ---
        if 0xB0 <= op <= 0xB7:
            i += 1  # imm8
            continue
        if 0xB8 <= op <= 0xBF:
            i += 8 if (rex & 0x08) else 4  # imm64 with REX.W, else imm32
            continue

        # --- AL/AX,imm opcodes: ADD/OR/ADC/SBB/AND/SUB/XOR/CMP (04/0C/14/1C/24/2C/34/3C) ---
        if op in (0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C) and i < n:
            i += 1  # imm8
            continue
        if op in (0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D):
            i += 4  # imm32
            continue

        # --- TEST AL/AX,imm ---
        if op == 0xA8:
            i += 1
            continue
        if op == 0xA9:
            i += 4
            continue

        # --- INT imm8 ---
        if op == 0xCD:
            i += 1
            continue

        # --- I/O opcodes (no modrm) ---
        if op in (0xE4, 0xE5, 0xE6, 0xE7):  # IN/OUT imm8
            i += 1
            continue
        if op in (0xEC, 0xED, 0xEE, 0xEF):  # IN/OUT DX
            continue

        # --- ENTER ---
        if op == 0xC8:
            i += 3
            continue

        # --- MOV moffs (A0-A3) ---
        if op in (0xA0, 0xA1, 0xA2, 0xA3):
            i += 8 if (rex & 0x08) else 4
            continue

        # --- 2-byte opcode escape (0F xx) ---
        if op == 0x0F:
            if i >= n:
                break
            op2 = buf[i]
            i += 1

            # Jcc rel32
            if 0x80 <= op2 <= 0x8F and i + 3 < n:
                buf[i:i+4] = b'\x00\x00\x00\x00'
                i += 4
                continue

            # SETcc, has ModR/M
            if 0x90 <= op2 <= 0x9F:
                pass  # fall through to ModR/M decode below

            # CMOVcc, MOVZX, MOVSX, BSF, BSR, POPCNT, etc — all have ModR/M
            # 2-byte NOPs (0F 1F /0), PREFETCH, etc — have ModR/M

            # 2-byte opcodes WITHOUT ModR/M
            if op2 in (0x05, 0x06, 0x07, 0x08, 0x09, 0x0B,  # SYSCALL/SYSRET/etc
                        0x31, 0x77, 0xA2,  # RDTSC, EMMS, CPUID
                        0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF):  # BSWAP
                continue

            # IMUL r, r/m, imm — 0F AF has ModR/M but no imm (that's the 3-op form in 69/6B)
            # Most 2-byte opcodes have a ModR/M byte — decode it below
            has_modrm = True  # almost all 0F xx opcodes have ModR/M

            if has_modrm and i < n:
                modrm = buf[i]
                i += 1
                mod = (modrm >> 6) & 3
                rm = modrm & 7

                # SIB byte present when mod != 3 and rm == 4
                if mod != 3 and rm == 4 and i < n:
                    sib = buf[i]
                    i += 1
                    sib_base = sib & 7
                    # SIB base=5 with mod=0 means disp32 (no base register)
                    if mod == 0 and sib_base == 5:
                        if i + 3 < n:
                            buf[i:i+4] = b'\x00\x00\x00\x00'
                        i += 4
                        continue

                # RIP-relative: mod=0, rm=5
                if mod == 0 and rm == 5:
                    if i + 3 < n:
                        buf[i:i+4] = b'\x00\x00\x00\x00'
                    i += 4
                elif mod == 1:
                    i += 1  # disp8
                elif mod == 2:
                    i += 4  # disp32

                # Some 2-byte opcodes have an immediate after ModR/M
                # SHLD/SHRD imm8 (0F A4, 0F AC)
                if op2 in (0xA4, 0xAC):
                    i += 1
                # PINSRB/W/D etc, ROUNDSS/SD, etc (0F 3A xx) would be 3-byte opcode
            continue

        # --- 1-byte opcodes WITH ModR/M ---
        # This covers the bulk: arithmetic (00-3F group), MOV (88-8B), LEA (8D),
        # TEST (84/85), XCHG (86/87), shift/rotate (C0/C1/D0-D3),
        # MOVS/IMUL etc (69/6B), FF group, FE group, F6/F7, etc.
        has_modrm = False
        imm_size = 0

        # Arithmetic: 00-05, 08-0D, 10-15, 18-1D, 20-25, 28-2D, 30-35, 38-3D
        # Pattern: for each group of 8, offsets 0-5 have ModR/M (0-3: r/m,r variants; 4-5: AL/AX,imm handled above)
        if op <= 0x3F:
            grp = op & 0x07
            if grp <= 3:
                has_modrm = True
            # 4,5 handled above (AL/AX,imm); 6,7 are PUSH/POP seg (no modrm)

        # 63: MOVSXD
        elif op == 0x63:
            has_modrm = True

        # 69: IMUL r, r/m, imm32
        elif op == 0x69:
            has_modrm = True
            imm_size = 4

        # 6B: IMUL r, r/m, imm8
        elif op == 0x6B:
            has_modrm = True
            imm_size = 1

        # 80: op r/m8, imm8
        elif op == 0x80:
            has_modrm = True
            imm_size = 1

        # 81: op r/m, imm32
        elif op == 0x81:
            has_modrm = True
            imm_size = 4

        # 83: op r/m, imm8
        elif op == 0x83:
            has_modrm = True
            imm_size = 1

        # 84/85: TEST r/m, r
        elif op in (0x84, 0x85):
            has_modrm = True

        # 86/87: XCHG r/m, r
        elif op in (0x86, 0x87):
            has_modrm = True

        # 88-8B: MOV variants
        elif 0x88 <= op <= 0x8B:
            has_modrm = True

        # 8D: LEA
        elif op == 0x8D:
            has_modrm = True

        # 8F: POP r/m
        elif op == 0x8F:
            has_modrm = True

        # C0/C1: shift r/m, imm8
        elif op in (0xC0, 0xC1):
            has_modrm = True
            imm_size = 1

        # C6: MOV r/m8, imm8
        elif op == 0xC6:
            has_modrm = True
            imm_size = 1

        # C7: MOV r/m, imm32
        elif op == 0xC7:
            has_modrm = True
            imm_size = 4

        # D0-D3: shift r/m by 1 or CL
        elif 0xD0 <= op <= 0xD3:
            has_modrm = True

        # F6: TEST/NOT/NEG/MUL/IMUL/DIV/IDIV r/m8
        elif op == 0xF6:
            has_modrm = True
            # /0 and /1 (TEST) have imm8, others don't
            if i < n and ((buf[i] >> 3) & 7) <= 1:
                imm_size = 1

        # F7: TEST/NOT/NEG/MUL/IMUL/DIV/IDIV r/m
        elif op == 0xF7:
            has_modrm = True
            if i < n and ((buf[i] >> 3) & 7) <= 1:
                imm_size = 4

        # FE: INC/DEC r/m8
        elif op == 0xFE:
            has_modrm = True

        # FF: INC/DEC/CALL/JMP/PUSH r/m
        elif op == 0xFF:
            has_modrm = True

        # 8C/8E: MOV seg
        elif op in (0x8C, 0x8E):
            has_modrm = True

        # D8-DF: x87 FPU
        elif 0xD8 <= op <= 0xDF:
            has_modrm = True

        if has_modrm:
            if i >= n:
                break
            modrm = buf[i]
            i += 1
            mod = (modrm >> 6) & 3
            rm = modrm & 7

            # SIB byte
            if mod != 3 and rm == 4 and i < n:
                sib = buf[i]
                i += 1
                sib_base = sib & 7
                if mod == 0 and sib_base == 5:
                    if i + 3 < n:
                        buf[i:i+4] = b'\x00\x00\x00\x00'
                    i += 4 + imm_size
                    continue

            # RIP-relative: mod=0, rm=5
            if mod == 0 and rm == 5:
                if i + 3 < n:
                    buf[i:i+4] = b'\x00\x00\x00\x00'
                i += 4
            elif mod == 1:
                i += 1  # disp8
            elif mod == 2:
                i += 4  # disp32

            i += imm_size
            continue

        # Unknown opcode — advance one byte to avoid getting stuck
        # (This is conservative; we might misparse but won't loop forever)
        if i == start:
            i += 1

    return bytes(buf)


def precompute_fixed_runs(pattern, mask):
    """Return list of (offset, fixed_bytes) for contiguous non-wildcard regions."""
    runs = []
    i = 0
    while i < len(mask):
        if mask[i]:
            start = i
            while i < len(mask) and mask[i]:
                i += 1
            runs.append((start, pattern[start:i]))
        else:
            i += 1
    return runs


# ---------------------------------------------------------------------------
# Raw PDB writer (no mspdb140.dll needed)
# ---------------------------------------------------------------------------


# Reverse lookup: register name -> CV_HREG_e ID
CV_REG_IDS = {v: k for k, v in CV_REG_NAMES.items()}

# Map type name strings to CodeView predefined type indices
CV_TYPE_MAP = {
    'void': 0x0003, 'char': 0x0070, 'wchar_t': 0x0071,
    'bool': 0x0030, 'BOOL': 0x0074,
    'int8_t': 0x0068, 'uint8_t': 0x0069,
    'short': 0x0011, 'unsigned short': 0x0021,
    'int': 0x0074, 'unsigned int': 0x0075,
    'long': 0x0012, 'unsigned long': 0x0022,
    'int64_t': 0x0076, 'uint64_t': 0x0077,
    'float': 0x0040, 'double': 0x0041,
}

def _type_name_to_cv(type_name):
    """Convert a type name string to a CodeView predefined type index."""
    if type_name.endswith(' *'):
        # Pointer — use 64-bit near pointer to the base type
        base = type_name[:-2].strip()
        base_ti = CV_TYPE_MAP.get(base, 0x0003)  # default to void
        return base_ti | 0x0600  # 64-bit near pointer mode
    return CV_TYPE_MAP.get(type_name, 0x0603)  # default to void* for UDTs etc.

def _rva_to_section(rva, sections):
    """Convert an RVA to (segment, offset) using PE section list."""
    for i, s in enumerate(sections):
        if s['va'] <= rva < s['va'] + s['vsize']:
            return i + 1, rva - s['va']
    return 1, rva

# CodeView record size helpers (for computing PtrEnd offsets)
# Record = uint16 RecordLen + uint16 RecordKind + payload, padded to 4 bytes
def _cv_align4(n):
    return (n + 3) & ~3

def _cv_record_size(payload_size):
    """Total bytes consumed by a CodeView record (RecordLen + Kind + payload + padding)."""
    return _cv_align4(4 + payload_size)

def _cv_gproc32_size(name_bytes_len):
    # Parent(4)+End(4)+Next(4)+CodeSize(4)+DbgStart(4)+DbgEnd(4)+FuncType(4)+Offset(4)+Seg(2)+Flags(1)+Name+null
    return _cv_record_size(35 + name_bytes_len + 1)

def _cv_s_local_size(name_bytes_len):
    # Type(4)+Flags(2)+Name+null
    return _cv_record_size(6 + name_bytes_len + 1)

def _cv_s_defrange_register_size():
    # Register(2)+MayHaveNoName(2)+Range(OffsetStart(4)+ISectStart(2)+Range(2)=8), no gaps
    return _cv_record_size(12)

def _cv_s_regrel32_size(name_bytes_len):
    # Offset(4)+Type(4)+Register(2)+Name+null
    return _cv_record_size(10 + name_bytes_len + 1)

def _cv_s_end_size():
    return _cv_record_size(0)  # = 4


def write_pdb(symbols, new_exe_data, new_sections, output_path,
              params_by_rva=None, guid=None, age=None):
    """Generate PDB via llvm-pdbutil yaml2pdb.

    symbols: list of (name, new_rva, old_rva, code_size)
    params_by_rva: dict old_rva -> [(name, type, storage), ...] or None
    guid/age: from the PE's debug directory so the PDB matches the binary.
    """
    import uuid

    if params_by_rva is None:
        params_by_rva = {}
    if guid is None:
        guid = uuid.uuid4().bytes
    if age is None:
        age = 1

    # Format GUID for YAML
    d1 = struct.unpack_from('<I', guid, 0)[0]
    d2 = struct.unpack_from('<H', guid, 4)[0]
    d3 = struct.unpack_from('<H', guid, 6)[0]
    d4 = guid[8:16]
    guid_str = f"{{{d1:08X}-{d2:04X}-{d3:04X}-{d4[0]:02X}{d4[1]:02X}-{d4[2]:02X}{d4[3]:02X}{d4[4]:02X}{d4[5]:02X}{d4[6]:02X}{d4[7]:02X}}}"

    # Parse PE section headers for the YAML
    pe_offset = struct.unpack_from('<I', new_exe_data, 0x3C)[0]
    coff_hdr = pe_offset + 4
    num_pe_sections = struct.unpack_from('<H', new_exe_data, coff_hdr + 2)[0]
    opt_size = struct.unpack_from('<H', new_exe_data, coff_hdr + 16)[0]
    sec_start = coff_hdr + 20 + opt_size

    # Find llvm-pdbutil before generating YAML
    llvm_pdbutil = shutil.which("llvm-pdbutil")
    if not llvm_pdbutil:
        for p in [r"D:\Program Files\LLVM\bin\llvm-pdbutil.exe",
                   r"C:\Program Files\LLVM\bin\llvm-pdbutil.exe"]:
            if os.path.isfile(p):
                llvm_pdbutil = p
                break
    if not llvm_pdbutil:
        sys.exit("llvm-pdbutil not found. Install LLVM: winget install LLVM.LLVM")

    yaml_path = output_path + ".yaml"
    sorted_syms = sorted(symbols, key=lambda x: x[1])

    # Stream YAML directly to file to avoid MemoryError on large symbol sets
    with open(yaml_path, 'w') as f:
        W = f.write
        W("---\n")
        W("MSF:\n")
        W("  SuperBlock:\n")
        W("    BlockSize:       4096\n")
        W("    FreeBlockMap:    2\n")
        W("    NumBlocks:       64\n")
        W("    NumDirectoryBytes: 0\n")
        W("    Unknown1:        0\n")
        W("    BlockMapAddr:    3\n")
        W("  NumDirectoryBlocks: 0\n")
        W("  DirectoryBlocks:   []\n")
        W("  NumStreams:        0\n")
        W("  FileSize:          0\n")
        W("PdbStream:\n")
        W(f"  Age:             {age}\n")
        W(f"  Guid:            '{guid_str}'\n")
        W("  Signature:       0\n")
        W("  Version:         VC70\n")
        W("DbiStream:\n")
        W(f"  Age:            {age}\n")
        W("  BuildNumber:     36363\n")
        W("  Flags:           0\n")
        W("  MachineType:     Amd64\n")
        W("  PdbDllRbld:      0\n")
        W("  PdbDllVersion:   0\n")
        W("  VerHeader:       V70\n")
        W("  SectionHeaders:\n")

        pe_sec_info = []
        for i in range(num_pe_sections):
            off = sec_start + i * 40
            sec_name = new_exe_data[off:off+8].rstrip(b'\0').decode('ascii', errors='replace')
            vsize = struct.unpack_from('<I', new_exe_data, off + 8)[0]
            va = struct.unpack_from('<I', new_exe_data, off + 12)[0]
            raw_size = struct.unpack_from('<I', new_exe_data, off + 16)[0]
            raw_off = struct.unpack_from('<I', new_exe_data, off + 20)[0]
            chars = struct.unpack_from('<I', new_exe_data, off + 36)[0]
            pe_sec_info.append((vsize, chars))
            W(f"    - Name:            {sec_name}\n")
            W(f"      VirtualSize:     {vsize}\n")
            W(f"      VirtualAddress:  {va}\n")
            W(f"      SizeOfRawData:   {raw_size}\n")
            W(f"      PointerToRawData: {raw_off}\n")
            W(f"      PointerToRelocations: 0\n")
            W(f"      PointerToLinenumbers: 0\n")
            W(f"      NumberOfRelocations: 0\n")
            W(f"      NumberOfLinenumbers: 0\n")
            W(f"      Characteristics: {chars}\n")

        # Section contributions (needed for SymSetContext to find our module)
        W("  SectionContribs:\n")
        for i, (vsize, chars) in enumerate(pe_sec_info):
            W(f"    - ISect:           {i + 1}\n")
            W(f"      Off:             0\n")
            W(f"      Size:            {vsize}\n")
            W(f"      Characteristics: {chars}\n")
            W(f"      Module:          0\n")
            W(f"      DataCrc:         0\n")
            W(f"      RelocCrc:        0\n")

        # Module info with S_GPROC32 + params + S_END for ALL functions
        # (publics stream is broken in LLVM 22.x yaml2pdb, so we use module symbols instead)
        # Pre-compute PtrEnd offsets (byte offset of S_END in the module symbol stream)
        mod_funcs = []  # (name, new_rva, old_rva, code_size, params, ptr_end)
        stream_offset = 4  # 4-byte CV signature
        for name, new_rva, old_rva, code_size in sorted_syms:
            params = params_by_rva.get(old_rva, [])
            name_len = len(name.encode('utf-8'))
            stream_offset += _cv_gproc32_size(name_len)
            for pname, ptype, pstorage in params:
                pname_len = len(pname.encode('utf-8'))
                if pstorage.startswith("REG:"):
                    stream_offset += _cv_s_local_size(pname_len)
                    stream_offset += _cv_s_defrange_register_size()
                elif pstorage.startswith("STACK:"):
                    stream_offset += _cv_s_regrel32_size(pname_len)
            ptr_end = stream_offset  # S_END starts here
            stream_offset += _cv_s_end_size()
            mod_funcs.append((name, new_rva, old_rva, code_size, params, ptr_end))

        W("  Modules:\n")
        W("    - Module:          'matched.obj'\n")
        W("      ObjFile:         'matched.obj'\n")
        W("      Modi:\n")
        W("        Signature:       4\n")
        W("        Records:\n")

        for name, new_rva, old_rva, code_size, params, ptr_end in mod_funcs:
            segment, offset = _rva_to_section(new_rva, new_sections)
            escaped = name.replace("'", "''")
            W(f"          - Kind:            S_GPROC32\n")
            W(f"            ProcSym:\n")
            W(f"              PtrParent:       0\n")
            W(f"              PtrEnd:          {ptr_end}\n")
            W(f"              PtrNext:         0\n")
            W(f"              CodeSize:        {code_size}\n")
            W(f"              DbgStart:        0\n")
            W(f"              DbgEnd:          {code_size - 1 if code_size > 0 else 0}\n")
            W(f"              FunctionType:    0\n")
            W(f"              Offset:          {offset}\n")
            W(f"              Segment:         {segment}\n")
            W(f"              Flags:           [  ]\n")
            W(f"              DisplayName:     '{escaped}'\n")

            for pname, ptype, pstorage in params:
                cv_type = _type_name_to_cv(ptype)
                escaped_pname = pname.replace("'", "''")
                if pstorage.startswith("REG:"):
                    reg_name = pstorage[4:]
                    W(f"          - Kind:            S_LOCAL\n")
                    W(f"            LocalSym:\n")
                    W(f"              Type:            {cv_type}\n")
                    W(f"              Flags:           [ IsParameter ]\n")
                    W(f"              VarName:         '{escaped_pname}'\n")
                    cv_reg = CV_REG_IDS.get(reg_name, 0)
                    W(f"          - Kind:            S_DEFRANGE_REGISTER\n")
                    W(f"            DefRangeRegisterSym:\n")
                    W(f"              Register:        {cv_reg}\n")
                    W(f"              MayHaveNoName:   0\n")
                    W(f"              Range:\n")
                    W(f"                OffsetStart:     {offset}\n")
                    W(f"                ISectStart:      {segment}\n")
                    W(f"                Range:           {code_size}\n")
                    W(f"              Gaps:            []\n")
                elif pstorage.startswith("STACK:"):
                    stack_off = int(float(pstorage[6:]))
                    W(f"          - Kind:            S_REGREL32\n")
                    W(f"            RegRelativeSym:\n")
                    W(f"              Offset:          {stack_off}\n")
                    W(f"              Type:            {cv_type}\n")
                    W(f"              Register:        RSP\n")
                    W(f"              VarName:         '{escaped_pname}'\n")

            W(f"          - Kind:            S_END\n")
            W(f"            ScopeEndSym:     {{}}\n")

        W("...\n")

    result = subprocess.run(
        [llvm_pdbutil, "yaml2pdb", yaml_path, "-pdb", output_path],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"llvm-pdbutil stderr: {result.stderr[:500]}")
        sys.exit(f"llvm-pdbutil failed (exit code {result.returncode})")

    # Keep yaml for debugging
    # os.unlink(yaml_path)
    pdb_size = os.path.getsize(output_path)
    funcs_with_params = sum(1 for _, _, old_rva, _ in symbols if params_by_rva.get(old_rva))
    print(f"PDB written: {output_path} ({pdb_size:,} bytes, {len(symbols)} symbols, {funcs_with_params} with params)")


# ---------------------------------------------------------------------------
# Matching engine
# ---------------------------------------------------------------------------

def build_hash_index(data, sections):
    """Build byte-sequence search helper using the raw binary data."""
    # Precompute section ranges for offset→RVA conversion
    ranges = []
    for s in sections:
        if s['raw_size'] > 0:
            ranges.append((s['raw_offset'], s['raw_offset'] + s['raw_size'],
                           s['va'] - s['raw_offset']))
    return data, ranges


def find_bytes_in(index, needle):
    """Find all occurrences of needle in the indexed binary. Returns list of RVAs."""
    data, ranges = index
    results = []
    start = 0
    while True:
        pos = data.find(needle, start)
        if pos == -1:
            break
        for sec_start, sec_end, rva_adj in ranges:
            if sec_start <= pos < sec_end:
                results.append(pos + rva_adj)
                break
        start = pos + 1
    return results


def main():
    parser = argparse.ArgumentParser(description="Quick function matcher — byte search")
    parser.add_argument("old_binary", help="Old binary (with PDB next to it)")
    parser.add_argument("new_binary", help="New binary (no PDB)")
    parser.add_argument("-o", "--output", default=None, help="Output symbol map file")
    parser.add_argument("--pdb", default=None, help="Output PDB file")
    parser.add_argument("--pdb-params", action="store_true",
                        help="Include parameter info in PDB (S_GPROC32 module symbols)")
    parser.add_argument("--idc", default=None, help="Output IDA Python script to apply symbols")
    parser.add_argument("--min-size", type=int, default=6,
                        help="Min function size in bytes (default: 6)")
    args = parser.parse_args()

    # Find PDB
    old_base_name = os.path.splitext(args.old_binary)[0]
    pdb_path = None
    for ext in ('.pdb', '.PDB'):
        p = old_base_name + ext
        if os.path.isfile(p):
            pdb_path = p
            break
    if not pdb_path:
        sys.exit(f"No PDB found next to {args.old_binary}")

    print(f"Old: {args.old_binary}")
    print(f"New: {args.new_binary}")
    print(f"PDB: {pdb_path}")

    # Load binaries
    with open(args.old_binary, 'rb') as f:
        old_data = f.read()
    with open(args.new_binary, 'rb') as f:
        new_data = f.read()

    _, old_sections = parse_pe_sections(old_data)
    _, new_sections = parse_pe_sections(new_data)

    # Parse PDB (keep session open for parameter queries later)
    print("\nParsing PDB...")
    pdb_session = PdbSession(args.old_binary, pdb_path)
    pdb_funcs = pdb_session.enum_functions()
    print(f"  {len(pdb_funcs)} functions")

    # Extract bytes from old binary
    print("Extracting function bytes...")
    functions = []  # (name, rva, size, raw_bytes)
    skipped = 0
    for name, rva, size in pdb_funcs:
        if size < args.min_size:
            skipped += 1
            continue
        raw = read_bytes_at_rva(old_data, rva, size, old_sections)
        if raw is None:
            skipped += 1
            continue
        functions.append((name, rva, size, raw))
    print(f"  {len(functions)} extracted, {skipped} skipped (< {args.min_size}B)")

    if not functions:
        print("No functions to match.")
        return

    # Build search index for new binary
    idx = build_hash_index(new_data, new_sections)

    # --- Cache helpers ---
    cache_dir = os.path.join(os.path.dirname(os.path.abspath(args.old_binary)), ".quick_match_cache")
    os.makedirs(cache_dir, exist_ok=True)
    # Cache key based on both binary sizes
    cache_key = f"{os.path.getsize(args.old_binary)}_{os.path.getsize(args.new_binary)}"

    def save_cache(name, data):
        with open(os.path.join(cache_dir, f"{cache_key}_{name}.pkl"), 'wb') as f:
            pickle.dump(data, f)

    def load_cache(name):
        path = os.path.join(cache_dir, f"{cache_key}_{name}.pkl")
        if os.path.isfile(path):
            with open(path, 'rb') as f:
                return pickle.load(f)
        return None

    # --- Pass 1: exact byte match (single-pass prefix scan) ---
    cached = load_cache("pass1")
    if cached:
        matched, unmatched, multi_exact = cached
        print(f"\nPass 1: exact byte match... (cached)")
        print(f"  exact={len([m for m in matched.values() if m[4]=='exact'])} multi={len(multi_exact)} none={len(unmatched)}")
    else:
        print("\nPass 1: exact byte match (prefix scan)...")
        matched = {}        # old_rva -> (name, old_rva, new_rva, size, strategy)
        unmatched = []       # functions not yet matched
        multi_exact = []     # (name, old_rva, size, raw, [new_rvas])

        PREFIX_LEN = 8
        uint64_unpack = struct.Struct('<Q').unpack_from

        # Group functions by 8-byte prefix for O(1) lookup during scan
        func_by_prefix = defaultdict(list)
        small_functions = []
        for name, old_rva, size, raw in functions:
            if size >= PREFIX_LEN:
                key = uint64_unpack(raw, 0)[0]
                func_by_prefix[key].append((name, old_rva, size, raw))
            else:
                small_functions.append((name, old_rva, size, raw))

        # Build section ranges for offset -> RVA conversion
        new_ranges = []
        for s in new_sections:
            if s['raw_size'] > 0:
                new_ranges.append((s['raw_offset'], s['raw_offset'] + s['raw_size'],
                                   s['va'] - s['raw_offset']))

        # Single-pass scan: check every position in new binary against prefix dict
        hits_by_func = defaultdict(list)  # old_rva -> [new_rva, ...]
        for sec_start, sec_end, rva_adj in new_ranges:
            sec_name = next((s['name'] for s in new_sections
                            if s['raw_offset'] == sec_start), '?')
            print(f"  scanning {sec_name} ({sec_end - sec_start:,} bytes)...",
                  end="", flush=True)
            end = sec_end - PREFIX_LEN + 1
            for offset in range(sec_start, end):
                key = uint64_unpack(new_data, offset)[0]
                candidates = func_by_prefix.get(key)
                if candidates is None:
                    continue
                for name, old_rva, size, raw in candidates:
                    if offset + size <= sec_end and new_data[offset:offset+size] == raw:
                        hits_by_func[old_rva].append(offset + rva_adj)
            unique = sum(1 for v in hits_by_func.values() if len(v) == 1)
            multi = sum(1 for v in hits_by_func.values() if len(v) > 1)
            print(f" matched={unique} multi={multi}")

        # Handle small functions (< PREFIX_LEN) with linear search fallback
        for name, old_rva, size, raw in small_functions:
            hits = find_bytes_in(idx, raw)
            if hits:
                hits_by_func[old_rva] = hits

        # Classify results
        exact_unique = 0
        for name, old_rva, size, raw in functions:
            hits = hits_by_func.get(old_rva, [])
            if len(hits) == 1:
                matched[old_rva] = (name, old_rva, hits[0], size, "exact")
                exact_unique += 1
            elif len(hits) > 1:
                multi_exact.append((name, old_rva, size, raw, hits))
            else:
                unmatched.append((name, old_rva, size, raw))

        print(f"  exact={exact_unique} multi={len(multi_exact)} none={len(unmatched)}")
        save_cache("pass1", (matched, unmatched, multi_exact))

    # --- Pass 2: normalized byte match (single-pass prefix scan on normalized data) ---
    cached2 = load_cache("pass2")
    if cached2:
        matched_p2, multi_norm, still_unmatched = cached2
        matched.update(matched_p2)
        print(f"\nPass 2: normalized byte match... (cached)")
        print(f"  normalized={len(matched_p2)} multi={len(multi_norm)} none={len(still_unmatched)}")
    else:
        print("\nPass 2: normalized byte match (prefix scan)...")

        PREFIX_LEN = 8
        uint64_unpack = struct.Struct('<Q').unpack_from

        # Normalize the entire new binary once
        print("  normalizing new binary...", end="", flush=True)
        new_norm = normalize_bytes(new_data)
        print(" done")

        # Group unmatched functions by normalized 8-byte prefix
        norm_by_prefix = defaultdict(list)
        small_norm = []
        skipped_same = 0
        for name, old_rva, size, raw in unmatched:
            norm_raw = normalize_bytes(raw)
            if norm_raw == raw:
                skipped_same += 1
                continue  # no call/jmp offsets to normalize — already tried in pass 1
            if size >= PREFIX_LEN:
                key = uint64_unpack(norm_raw, 0)[0]
                norm_by_prefix[key].append((name, old_rva, size, norm_raw))
            else:
                small_norm.append((name, old_rva, size, norm_raw))

        print(f"  {len(norm_by_prefix)} prefix groups, {len(small_norm)} small, {skipped_same} skipped (no normalization)")

        # Build section ranges
        new_ranges = []
        for s in new_sections:
            if s['raw_size'] > 0:
                new_ranges.append((s['raw_offset'], s['raw_offset'] + s['raw_size'],
                                   s['va'] - s['raw_offset']))

        # Single-pass scan over normalized new binary
        norm_hits = defaultdict(list)  # old_rva -> [new_rva, ...]
        for sec_start, sec_end, rva_adj in new_ranges:
            sec_name = next((s['name'] for s in new_sections
                            if s['raw_offset'] == sec_start), '?')
            sec_size = sec_end - sec_start
            if sec_size < PREFIX_LEN:
                continue
            print(f"  scanning {sec_name} ({sec_size:,} bytes)...", end="", flush=True)
            end = sec_end - PREFIX_LEN + 1
            for offset in range(sec_start, end):
                key = uint64_unpack(new_norm, offset)[0]
                candidates = norm_by_prefix.get(key)
                if candidates is None:
                    continue
                for name, old_rva, size, norm_raw in candidates:
                    if offset + size <= sec_end and new_norm[offset:offset+size] == norm_raw:
                        norm_hits[old_rva].append(offset + rva_adj)
            unique = sum(1 for v in norm_hits.values() if len(v) == 1)
            multi = sum(1 for v in norm_hits.values() if len(v) > 1)
            print(f" matched={unique} multi={multi}")

        # Handle small functions with linear search fallback
        if small_norm:
            print(f"  searching {len(small_norm)} small functions...", end="", flush=True)
            for name, old_rva, size, norm_raw in small_norm:
                start = 0
                hits = []
                while True:
                    pos = new_norm.find(norm_raw, start)
                    if pos == -1:
                        break
                    for sec_start, sec_end, rva_adj in new_ranges:
                        if sec_start <= pos < sec_end:
                            hits.append(pos + rva_adj)
                            break
                    start = pos + 1
                if hits:
                    norm_hits[old_rva] = hits
            print(" done")

        # Classify results
        norm_unique = 0
        multi_norm = []
        still_unmatched = []
        for name, old_rva, size, raw in unmatched:
            if old_rva in matched:
                continue
            norm_raw = normalize_bytes(raw)
            if norm_raw == raw:
                still_unmatched.append((name, old_rva, size, raw))
                continue
            hits = norm_hits.get(old_rva, [])
            if len(hits) == 1:
                matched[old_rva] = (name, old_rva, hits[0], size, "normalized")
                norm_unique += 1
            elif len(hits) > 1:
                multi_norm.append((name, old_rva, size, raw, hits))
            else:
                still_unmatched.append((name, old_rva, size, raw))

        print(f"  normalized={norm_unique} multi={len(multi_norm)} none={len(still_unmatched)}")
        p2_matched = {k: v for k, v in matched.items() if v[4] == "normalized"}
        save_cache("pass2", (p2_matched, multi_norm, still_unmatched))

    # --- Pass 2.5: resolve multi-matches where #old == #new by address order ---
    def resolve_multi_by_count(multi_list, strategy, use_norm=False):
        """When N old functions share identical bytes and have exactly N hits in
        the new binary, match them 1:1 by address order."""
        groups = defaultdict(list)
        for entry in multi_list:
            key = normalize_bytes(entry[3]) if use_norm else entry[3]
            groups[key].append(entry)

        resolved = 0
        remaining = []
        for key, entries in groups.items():
            new_rvas = sorted(entries[0][4])
            if len(entries) == len(new_rvas):
                for entry, new_rva in zip(sorted(entries, key=lambda e: e[1]), new_rvas):
                    name, old_rva, size, raw, hits = entry
                    matched[old_rva] = (name, old_rva, new_rva, size, strategy)
                    resolved += 1
            else:
                remaining.extend(entries)
        return remaining, resolved

    exact_remaining, exact_resolved = resolve_multi_by_count(multi_exact, "multi_counted")
    norm_remaining, norm_resolved = resolve_multi_by_count(multi_norm, "multi_counted_norm", use_norm=True)
    total_counted = exact_resolved + norm_resolved
    if total_counted > 0 or (multi_exact or multi_norm):
        print(f"\nPass 2.5: multi-match count resolution...")
        print(f"  exact: {exact_resolved}/{len(multi_exact)} resolved, norm: {norm_resolved}/{len(multi_norm)} resolved")
    multi_exact = exact_remaining
    multi_norm = norm_remaining

    # --- Pass 3: resolve multi-matches using function ordering ---
    all_multi = multi_exact + multi_norm
    if all_multi:
        print(f"\nPass 3: resolving {len(all_multi)} multi-matches by ordering...")
        resolved = 0
        # Build sorted (old_rva, new_rva) pairs for O(log n) neighbor lookup
        sorted_pairs = sorted((m[1], m[2]) for m in matched.values())

        for i, (name, old_rva, size, raw, hits) in enumerate(all_multi):
            if i % 5000 == 0:
                print(f"\r  [{i}/{len(all_multi)}] resolved={resolved}", end="", flush=True)
            # Binary search for nearest predecessor and successor
            pos = bisect.bisect_left(sorted_pairs, (old_rva,))
            pred_new = sorted_pairs[pos - 1][1] if pos > 0 else None
            succ_new = sorted_pairs[pos][1] if pos < len(sorted_pairs) else None
            valid = [r for r in hits
                     if (pred_new is None or r > pred_new)
                     and (succ_new is None or r < succ_new)]
            if len(valid) == 1:
                matched[old_rva] = (name, old_rva, valid[0], size, "order")
                bisect.insort(sorted_pairs, (old_rva, valid[0]))
                resolved += 1
        print(f"\r  [{len(all_multi)}/{len(all_multi)}] resolved={resolved}")

    # --- Pass 4: gap filling using matched neighbors ---
    # name, rva, size, raw
    remaining = [(n, r, s, b) for n, r, s, b in functions if r not in matched]
    if remaining:
        print(f"\nPass 4: gap filling ({len(remaining)} unmatched)...")
        sorted_pairs = sorted((m[1], m[2]) for m in matched.values())
        old_rvas_arr = [p[0] for p in sorted_pairs]

        PROLOGUE_LEN = 16
        SEARCH_WINDOW = 256
        NGRAM_N = 4
        MIN_SIM = 0.5

        gap_resolved = 0
        for i, (name, old_rva, size, raw) in enumerate(remaining):
            if i % 10000 == 0 and i > 0:
                print(f"\r  [{i}/{len(remaining)}] gap={gap_resolved}", end="", flush=True)
            if size < PROLOGUE_LEN:
                continue
            idx = bisect.bisect_left(old_rvas_arr, old_rva)
            if idx == 0 or idx >= len(old_rvas_arr):
                continue

            pred_old, pred_new = sorted_pairs[idx - 1]
            succ_old, succ_new = sorted_pairs[idx]
            if succ_new <= pred_new:
                continue

            # Expected position by offset from predecessor
            expected = pred_new + (old_rva - pred_old)

            # Search a window around expected position, clamped to the gap
            search_start = max(expected - SEARCH_WINDOW, pred_new)
            search_end = min(expected + SEARCH_WINDOW, succ_new)
            search_size = search_end - search_start
            if search_size < PROLOGUE_LEN:
                continue

            search_bytes = read_bytes_at_rva(new_data, search_start, search_size, new_sections)
            if search_bytes is None:
                continue

            # Search for raw prologue bytes (prologues rarely have relocations)
            prologue = raw[:PROLOGUE_LEN]
            pos = search_bytes.find(prologue)
            if pos == -1:
                continue
            if search_bytes.find(prologue, pos + 1) != -1:
                continue  # ambiguous — skip

            new_rva = search_start + pos

            # Verify via n-gram similarity (handles byte shifts from instruction size changes)
            new_func = read_bytes_at_rva(new_data, new_rva, size, new_sections)
            if new_func is None:
                continue
            old_n = normalize_bytes(raw)
            new_n = normalize_bytes(new_func)
            if len(old_n) >= NGRAM_N and len(new_n) >= NGRAM_N:
                grams_old = set(old_n[j:j+NGRAM_N] for j in range(len(old_n) - NGRAM_N + 1))
                grams_new = set(new_n[j:j+NGRAM_N] for j in range(len(new_n) - NGRAM_N + 1))
                sim = len(grams_old & grams_new) / len(grams_old)
            else:
                sim = sum(1 for a, b in zip(old_n, new_n) if a == b) / len(old_n)
            if sim >= MIN_SIM:
                matched[old_rva] = (name, old_rva, new_rva, size, "gap")
                gap_resolved += 1

        print(f"\r  [{len(remaining)}/{len(remaining)}] gap={gap_resolved}")

    # --- Summary ---
    total = len(matched)
    total_pdb = len(pdb_funcs)
    pct = 100.0 * total / len(functions) if functions else 0
    print(f"\n{'='*50}")
    print(f"PDB functions:   {total_pdb}")
    print(f"  Too small (<{args.min_size}B): {skipped}")
    print(f"  Matchable:     {len(functions)}")
    print(f"Matched: {total} / {len(functions)} ({pct:.1f}%)")

    # Strategy breakdown
    strats = defaultdict(int)
    for m in matched.values():
        strats[m[4]] += 1
    for s, c in sorted(strats.items(), key=lambda x: -x[1]):
        print(f"  {s}: {c}")

    print(f"Unmatched: {len(functions) - total}")

    # --- Deduplicate results ---
    results = sorted(matched.values(), key=lambda m: m[2])  # sort by new_rva
    seen_rvas = set()
    deduped = []
    for r in results:
        if r[2] not in seen_rvas:
            seen_rvas.add(r[2])
            deduped.append(r)
    if len(results) != len(deduped):
        print(f"  Deduplicated: {len(results)} -> {len(deduped)} (removed {len(results)-len(deduped)} duplicate RVAs)")
    results = deduped

    # --- Load parameter info (needed for both -o and --pdb) ---
    params_by_rva = {}
    if args.output or args.pdb:
        print("\nLoading parameter info from PDB...")
        matched_old_rvas = [m[1] for m in results]
        params_by_rva = pdb_session.get_params(matched_old_rvas)
        funcs_with_params = sum(1 for v in params_by_rva.values() if v)
        total_params = sum(len(v) for v in params_by_rva.values())
        print(f"  {funcs_with_params} functions with params, {total_params} params total")

        # Synthesize implicit 'this' parameter for non-static member functions.
        # The PDB never lists 'this' as a parameter, but x64 calling convention
        # always passes it in RCX.
        this_count = 0
        for name, old_rva, new_rva, size, strategy in results:
            existing = params_by_rva.get(old_rva, [])
            if _likely_member_function(name, existing):
                class_name = _extract_class_name(name) or 'void'
                this_param = ('this', f'{class_name} *', 'REG:RCX')
                params_by_rva[old_rva] = [this_param] + existing
                this_count += 1
        if this_count:
            print(f"  Synthesized 'this' for {this_count} member functions")

    # --- Write symbol map ---
    if args.output:
        with open(args.output, 'w') as f:
            pe_offset = struct.unpack_from('<I', new_data, 0x3C)[0]
            timestamp = struct.unpack_from('<I', new_data, pe_offset + 8)[0]
            f.write(f"# TimeDateStamp: {timestamp:08X}\n")
            f.write(f"# quick_match — {len(results)} functions matched\n")
            f.write(f"# Format: FUNC\\tname\\tRVA\\tcodeSize\\tparamCount\n")
            f.write(f"#         PARAM\\tname\\ttype\\tstorage\n")
            for name, old_rva, new_rva, size, strategy in results:
                params = params_by_rva.get(old_rva, [])
                f.write(f"FUNC\t{name}\t{new_rva}\t{size}\t{len(params)}\n")
                for pname, ptype, pstorage in params:
                    f.write(f"PARAM\t{pname}\t{ptype}\t{pstorage}\n")
                f.write("\n")
        print(f"Written to {args.output}")

    # --- Generate PDB ---
    if args.pdb:
        print(f"\nGenerating PDB...")
        # (decorated_name, new_rva, old_rva, code_size)
        pdb_symbols = [
            (pdb_session.decorated_names.get(m[1], m[0]), m[2], m[1], m[3])
            for m in results
        ]
        _, pe_guid, pe_age = parse_pe_debug_info(new_data, new_sections)
        write_pdb(pdb_symbols, new_data, new_sections, args.pdb,
                  params_by_rva=params_by_rva if args.pdb_params else None,
                  guid=pe_guid, age=pe_age)

    # --- Generate IDA script ---
    if args.idc:
        print(f"\nGenerating IDA script...")
        with open(args.idc, 'w') as f:
            f.write("# IDA Python script — apply matched symbols\n")
            f.write("# Run in IDA: File > Script File\n")
            f.write("import ida_name, idc\n\n")
            f.write(f"# {len(results)} symbols from quick_match.py\n")
            f.write("symbols = [\n")
            for name, old_rva, new_rva, size, strategy in results:
                escaped = name.replace("\\", "\\\\").replace("'", "\\'")
                f.write(f"    (0x{new_rva:X}, '{escaped}'),\n")
            f.write("]\n\n")
            f.write("base = ida_nalt.get_imagebase()\n")
            f.write("count = 0\n")
            f.write("for rva, name in symbols:\n")
            f.write("    if ida_name.set_name(base + rva, name, ida_name.SN_NOWARN | ida_name.SN_NOCHECK):\n")
            f.write("        count += 1\n")
            f.write(f'print(f"Applied {{count}} / {len(results)} symbols")\n')
        print(f"Written to {args.idc} ({len(results)} symbols)")

    pdb_session.close()


if __name__ == "__main__":
    main()
