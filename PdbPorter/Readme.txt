PDB Porter v1.0.1
==========

Ports debug symbols (function names + parameter info) from an old WC3 binary
that has a PDB to a new patched binary that doesn't.

When WC3 gets a patch, the binary changes and the old PDB no longer applies.
This tool matches functions between the two versions by searching for their
raw bytes in the new binary, then creates a new PDB so CrashProtector can
resolve function names in stack traces.


Quick start
-----------

Prerequisites:
  - Windows (uses dbghelp.dll for PDB parsing)
  - Python 3.10+ (tested with 3.12 and 3.14, no extra packages needed)
  - LLVM (for PDB generation): winget install LLVM.LLVM
  - The old binary + its PDB, and the new binary

One command does everything:
  cd D:\Tom\scripts\wc3\Wc3Utils\PdbPorter
  python quick_match.py "Warcraft III_symboled.exe" "Warcraft III.exe" -o symbols.txt

  Then copy the result next to the game exe:
  copy symbols.txt "D:\Program Files (x86)\Warcraft III\_retail_\x86_64\symbols.txt"

CrashProtector loads symbols.txt at startup and validates the TimeDateStamp
header against the running exe — a stale file from a different build is
automatically rejected.

Cache is saved in .quick_match_cache/ and keyed by SHA-256 of both executables, the reference PDB, matcher source, cache format, and --min-size. Same-size input changes invalidate it automatically. Legacy size-only entries are ignored. Use --no-cache to disable reads/writes, or --cache-dir to use an isolated directory.

Output:
  - symbols.txt — human-readable symbol map with TimeDateStamp header
    and parameter info. CrashProtector loads this directly.
  - Warcraft III.pdb (optional, via --pdb) — PDB file with 54K+ public
    symbols. Note: llvm-pdbutil yaml2pdb has a corrupted publics stream
    bug in LLVM 22.x that makes SymFromAddr fail, so symbols.txt is the
    preferred method.

If using the PDB, place it next to the game executable. CrashProtector
loads it via SYMOPT_LOAD_ANYTHING (bypasses GUID mismatch). The PDB GUID
is set to match the new binary's debug directory, so other tools
(dbghelp, WinDbg) also accept it.

Coverage depends on the input snapshot and game build. The verified 3.0.0.24268 table contains 54,250 functions (125,213 parameter records), improved from 39,017 in the startup-only table, versus roughly 105K in archived 2.0.4 tables. The inspected 3.0 startup dump contains repeated replacement code at missing pathfinding routines; it must not be treated as a complete decrypted executable. The first-crash capture restored ComputePath, SearchOnMap, AddToOpenSet, and their pathfinding callers. The final table excludes 152 candidates crossing unreadable pages and retains 1,610 nonconflicting prior records only after full normalized-body comparison with the reference executable. See the runtime snapshot workflow below for future symbol updates.


Installation
------------

1. Python (if not already installed):

    winget install Python.Python.3.12

   Or download from python.org. Any version 3.10+ works.

2. LLVM (provides llvm-pdbutil for PDB generation):

    winget install LLVM.LLVM

   This installs to "D:\Program Files\LLVM" or "C:\Program Files\LLVM".
   quick_match.py finds it automatically.

   Without LLVM, the -o flag still works (text symbol map), but --pdb
   won't be available.

3. No Python packages needed — quick_match.py uses only:
   - ctypes (stdlib) for dbghelp.dll and PE parsing
   - struct (stdlib) for binary format parsing


Step by step
------------

1. Prepare files. Place in the PdbPorter directory:
   - Old binary: e.g. "Warcraft III.bak.exe"
   - Old PDB: must match the old binary's base name (e.g. "Warcraft III.bak.pdb")
   - New binary: e.g. "Warcraft III.exe"

   The PDB MUST sit next to the old binary with a matching base name. If the
   PE internally references a different PDB name (e.g. "Warcraft III.pdb" but
   you renamed it to .bak.pdb), the script handles this automatically by
   creating a temp copy with the expected name.

2. Run quick_match.py:

    python quick_match.py "Warcraft III.bak.exe" "Warcraft III.exe" ^
        -o symbols.txt --pdb "Warcraft III.pdb"

   Progress is printed for each pass. The first run takes 5-15 minutes
   (depending on binary size). Subsequent runs are faster because pass 1
   and pass 2 results are cached in .quick_match_cache/.

3. Verify the output:
   - Check symbols.txt — should show FUNC lines with names and RVAs,
     and PARAM lines with parameter names, types, and registers.
   - Check that the PDB loads:

         python test_pdb_load.py

     Should show "Total symbols enumerated: 54634" and SymFromAddr
     resolving addresses to function names.

4. Deploy: copy symbols.txt (and optionally the .pdb) next to the game
   executable:

    copy symbols.txt "D:\Program Files (x86)\Warcraft III\_retail_\x86_64\"

5. To regenerate after tweaking settings (e.g. --min-size), delete
   .quick_match_cache/ and re-run.


Options
-------

    --min-size N    Minimum function size in bytes to match (default: 6).
                    Smaller functions produce too many false byte matches.
    -o FILE         Write a text symbol map (with parameter info).
    --pdb FILE      Write a PDB file via llvm-pdbutil (public symbols only).
    --idc FILE      Write an IDA Python script to apply symbols.


How it works
------------

PDB parsing:
  Uses Windows dbghelp.dll (SymEnumSymbolsW) to enumerate all functions
  from the old PDB — names, addresses, and sizes. For matched functions,
  uses SymSetContext + scoped enumeration to read parameter names, types
  (resolved from PDB type indices), and storage locations (register or
  stack offset).

Matching (three passes):

  Pass 1 — Exact byte match:
    Pre-computes 8-byte prefix hashes for all old functions, then scans
    the new binary in a single pass. At each position, checks the prefix
    hash against the dictionary; on hit, verifies the full function bytes.
    This is O(binary_size), not O(functions * binary_size).

  Pass 2 — Normalized byte match:
    Same single-pass prefix scan but on normalized bytes. Normalization
    zeros out address-dependent instruction operands:
      - CALL rel32 (E8) and JMP rel32 (E9): zero bytes 1-4
      - Conditional jumps Jcc rel32 (0F 80-8F): zero bytes 2-5
      - Conditional jumps Jcc rel8 (70-7F): zero byte 1
      - Short JMP (EB): zero byte 1
    This catches functions that are byte-identical except for changed
    call/jump targets between versions — the most common difference.

  Pass 3 — Order resolution:
    Functions with multiple matches from passes 1-2 are disambiguated
    using address ordering. If a function's nearest matched predecessor
    and successor in the old binary constrain it to exactly one candidate
    in the new binary, that candidate is accepted. Uses binary search for
    O(n log n) neighbor lookup.

PDB generation:
  Generates a YAML description of the PDB (public symbols + PE section
  headers) and feeds it to llvm-pdbutil yaml2pdb, which produces a
  spec-compliant PDB 7.0 file. The GUID and age are read from the new
  binary's PE debug directory so the PDB matches. Section headers are
  copied from the PE so dbghelp can map segment:offset to virtual
  addresses.


Symbol map format
-----------------

    # TimeDateStamp: 6789ABCD
    # quick_match — 97524 functions matched
    # Format: FUNC	name	RVA	codeSize	paramCount
    #         PARAM	name	type	storage
    FUNC	FunctionName	12345	200	3
    PARAM	this	SomeClass *	REG:RCX
    PARAM	count	int	REG:RDX
    PARAM	buffer	char *	STACK:40

    FUNC	AnotherFunction	67890	150	0

The TimeDateStamp header (hex, from the new binary's PE COFF header) lets
CrashProtector reject stale symbol files that don't match the running exe.

FUNC fields: name, RVA (decimal), code size (bytes), parameter count.
PARAM fields: name, type, storage (REG:register or STACK:offset).


Files
-----

quick_match.py           Main tool — matches functions + generates PDB
test_pdb_load.py         Verifies generated PDB works with dbghelp
port_pdb.py              Ghidra-based alternative (slower, more matches)
MatchFunctions.java      Ghidra headless script for function matching
ConfigureAnalysis.java   Ghidra pre-script — disables expensive analyzers
pdb_writer.cpp           PDB writer via mspdb140.dll (currently broken on VS2022)
build_pdb_writer.bat     Compiles pdb_writer.cpp


Known issues
------------

- pdb_writer.exe crashes on VS2022 (MSVC 14.41) due to a vtable layout
  change in mspdb140.dll. The PDB::OpenDBI virtual method at index 6
  causes an access violation. Use --pdb with llvm-pdbutil instead.

- IDA's PDB loader (DIA SDK) may not load the generated PDB's symbols
  even though dbghelp loads them fine. Use --idc to generate an IDA
  Python script as a workaround.

- Functions smaller than --min-size (default 6 bytes) are skipped because
  they produce too many false positives in byte search. These are mostly
  thunks (JMP instructions) and tiny stubs.

- The ~67% unmatched rate is expected: most unmatched functions either
  changed structurally between versions, are too small to uniquely match,
  or are compiler-generated functions that don't exist in both binaries.


Runtime snapshot validation (current workflow)
----------------------------------------------
CrashProtector now captures startup code, freezes the first unhandled crash snapshot before recovery, and supports manual capture after gameplay begins. See ../CrashProtector/README.md. Keep each .exe together with its .exe.json metadata.

Before matching:
  python inspect_snapshot.py "gameplay.exe" --compare "startup.exe"

Exit code 2 means review is required: the file has unreadable pages or substantial long repeated non-padding code blocks (at least 64 KiB and 1% of .text). --json prints full details. A clean report does not prove all code is present; compare the specific functions involved in the crash. Captures are sequential reads, not an atomic snapshot of all threads.

quick_match.py performs this check before parsing the PDB or matching. It stops on flagged inputs unless --allow-suspect-input is explicitly supplied after review. This override does not recover missing bytes. Do not replace a working symbol table with guessed matches just to increase the count.

Run cache and snapshot-check regressions:
  python -m unittest discover -s tests -v
