#!/usr/bin/env python3
"""
Port debug symbols from an old binary (with PDB) to a new similar binary.

Uses Ghidra headless analysis to match functions between versions, then
outputs a symbol map file compatible with PdbGen (https://github.com/gix/PdbGen).

Requirements:
    - Ghidra installed (set GHIDRA_HOME env var or use --ghidra-home)
    - PDB file for the old binary placed next to it with matching name

Usage:
    python port_pdb.py old.exe new.exe -o symbols.txt
    python port_pdb.py old.exe new.exe -o new.pdb --pdbgen /path/to/PdbGen
"""

import argparse
import os
import platform
import shutil
import subprocess
import sys
import tempfile


def find_analyze_headless(ghidra_home):
    name = "analyzeHeadless.bat" if platform.system() == "Windows" else "analyzeHeadless"
    path = os.path.join(ghidra_home, "support", name)
    if not os.path.isfile(path):
        sys.exit(f"analyzeHeadless not found at: {path}")
    return path


def run_ghidra(cmd, project_dir, project_folder, *extra, timeout=3600):
    args = [cmd, project_dir, project_folder] + list(extra)
    print(f"  $ {' '.join(os.path.basename(a) if os.sep in a else a for a in args)}")
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)

    # Always show Ghidra script output (lines starting with ">")
    for line in result.stdout.splitlines():
        stripped = line.strip()
        # analyzeHeadless prefixes script println with the script name
        if "MatchFunctions.java>" in line or "INFO  SCRIPT" in line:
            print(f"    {stripped}")

    if result.returncode != 0:
        print("\n--- Ghidra stdout (last 3000 chars) ---")
        print(result.stdout[-3000:])
        print("\n--- Ghidra stderr (last 3000 chars) ---")
        print(result.stderr[-3000:])
        sys.exit(f"Ghidra failed (exit code {result.returncode})")

    return result


def find_pdb_next_to(binary_path):
    """Check if a PDB file exists next to the binary."""
    base = os.path.splitext(binary_path)[0]
    for ext in (".pdb", ".PDB"):
        p = base + ext
        if os.path.isfile(p):
            return p
    return None


def main():
    parser = argparse.ArgumentParser(
        description="Port debug symbols between binary versions using Ghidra"
    )
    parser.add_argument("old_binary", help="Old binary (with PDB next to it)")
    parser.add_argument("new_binary", help="New binary (no PDB)")
    parser.add_argument("-o", "--output", required=True,
                        help="Output file (symbol map, or .pdb if --pdbgen is set)")
    parser.add_argument("--ghidra-home", default=os.environ.get("GHIDRA_HOME"),
                        help="Ghidra installation directory (default: $GHIDRA_HOME)")
    parser.add_argument("--pdb-writer", default=None,
                        help="Path to pdb_writer executable (creates PDB with parameter info)")
    parser.add_argument("--pdbgen", default=None,
                        help="Path to PdbGen executable (creates PDB with public symbols only)")
    parser.add_argument("--keep-project", action="store_true",
                        help="Keep the Ghidra project directory for debugging")
    parser.add_argument("--timeout", type=int, default=3600,
                        help="Timeout per Ghidra step in seconds (default: 3600)")
    args = parser.parse_args()

    if not args.ghidra_home:
        sys.exit("GHIDRA_HOME not set. Use --ghidra-home or set the environment variable.")

    analyze = find_analyze_headless(args.ghidra_home)
    script_dir = os.path.dirname(os.path.abspath(__file__))

    old_binary = os.path.abspath(args.old_binary)
    new_binary = os.path.abspath(args.new_binary)
    output = os.path.abspath(args.output)

    for label, path in [("Old binary", old_binary), ("New binary", new_binary)]:
        if not os.path.isfile(path):
            sys.exit(f"{label} not found: {path}")

    # Check for PDB
    old_pdb = find_pdb_next_to(old_binary)
    if old_pdb:
        print(f"Found PDB: {old_pdb}")
    else:
        print(f"WARNING: No PDB found next to {old_binary}")
        print(f"  Ghidra may not be able to load symbols for the old binary.")

    # We import both binaries into separate Ghidra project folders (/old and /new)
    # to avoid name collisions when the filenames are identical.
    tmpdir = tempfile.mkdtemp(prefix="pdb_porter_")
    project_name = "SymbolPort"
    symbols_file = os.path.join(tmpdir, "symbols.txt")
    old_name = os.path.basename(old_binary)
    new_name = os.path.basename(new_binary)

    try:
        # Step 1 – import and auto-analyze old binary (Ghidra loads PDB if found)
        print(f"\n[1/3] Importing old binary: {old_name}")
        run_ghidra(analyze, tmpdir, f"{project_name}/old",
                   "-import", old_binary,
                   timeout=args.timeout)

        # Step 2 – import and auto-analyze new binary
        print(f"\n[2/3] Importing new binary: {new_name}")
        run_ghidra(analyze, tmpdir, f"{project_name}/new",
                   "-import", new_binary,
                   timeout=args.timeout)

        # Step 3 – match functions
        src_project_path = f"/old/{old_name}"
        print(f"\n[3/3] Matching functions (source: {src_project_path})")
        run_ghidra(analyze, tmpdir, f"{project_name}/new",
                   "-process", new_name,
                   "-noanalysis",
                   "-postScript", "MatchFunctions.java", src_project_path, symbols_file,
                   "-scriptPath", script_dir,
                   timeout=args.timeout)

        if not os.path.isfile(symbols_file):
            sys.exit("MatchFunctions.java did not produce output. Check Ghidra logs above.")

        # Count results
        with open(symbols_file) as f:
            data_lines = [l for l in f if l.strip() and not l.startswith("#")]
        print(f"\nResult: {len(data_lines)} named symbols ported to new binary")

        # Output
        if args.pdb_writer:
            print(f"Generating PDB with pdb_writer (with parameter info)...")
            subprocess.run([args.pdb_writer, new_binary, symbols_file, output], check=True)
            print(f"PDB written to: {output}")
        elif args.pdbgen:
            print(f"Generating PDB with PdbGen (public symbols only, no parameter info)...")
            subprocess.run([args.pdbgen, new_binary, symbols_file, output], check=True)
            print(f"PDB written to: {output}")
        else:
            shutil.copy2(symbols_file, output)
            print(f"Symbol map written to: {output}")
            print(f"\nTo generate a PDB with parameter info:")
            print(f"  pdb_writer {os.path.basename(new_binary)} {os.path.basename(output)} output.pdb")
            print(f"\nOr for public symbols only (PdbGen):")
            print(f"  PdbGen {os.path.basename(new_binary)} {os.path.basename(output)} output.pdb")

    finally:
        if args.keep_project:
            print(f"\nGhidra project kept at: {tmpdir}")
        else:
            shutil.rmtree(tmpdir, ignore_errors=True)


if __name__ == "__main__":
    main()
