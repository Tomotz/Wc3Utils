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
    python port_pdb.py old.exe new.exe -o symbols.txt --step 3
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
    print(f"  $ {' '.join(os.path.basename(a) if os.sep in a else a for a in args)}", flush=True)

    # Disable MSYS/Git-Bash path conversion — it mangles Ghidra project paths
    # like "/old/binary.exe" into "D:/Program Files/Git/old/binary.exe".
    env = os.environ.copy()
    env["MSYS_NO_PATHCONV"] = "1"
    env["MSYS2_ARG_CONV_EXCL"] = "*"

    # Stream output so the user can see Ghidra's progress in real time.
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, bufsize=1, env=env)
    stdout_lines = []
    try:
        for line in proc.stdout:
            stdout_lines.append(line)
            stripped = line.strip()
            if not stripped:
                continue
            # Show progress-relevant lines, skip noisy warnings/diagnostics
            if "ERROR" in line:
                print(f"    {stripped}", flush=True)
            elif "MatchFunctions.java>" in line or "RunVersionTracking.java>" in line:
                print(f"    {stripped}", flush=True)
            elif any(k in line for k in (
                "INFO  ANALYZING", "INFO  IMPORTING", "INFO  REPORT",
                "INFO  SCRIPT", "PDB analyzer pars", "Using Loader",
                "Using Language", "% of", "resolveCount",
                "conflictCount", "Headless startup complete",
                "HEADLESS: execution", "AutoAnalysis",
            )):
                print(f"    {stripped}", flush=True)
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
        sys.exit(f"Ghidra timed out after {timeout}s")

    if proc.returncode != 0:
        stderr = proc.stderr.read()
        stdout_tail = "".join(stdout_lines[-100:])
        print("\n--- Ghidra stdout (last lines) ---")
        print(stdout_tail[-3000:])
        print("\n--- Ghidra stderr (last 3000 chars) ---")
        print(stderr[-3000:])
        sys.exit(f"Ghidra failed (exit code {proc.returncode})")

    return proc


def find_pdb_next_to(binary_path):
    """Check if a PDB file exists next to the binary."""
    base = os.path.splitext(binary_path)[0]
    for ext in (".pdb", ".PDB"):
        p = base + ext
        if os.path.isfile(p):
            return p
    return None


def get_project_dir(work_dir):
    """Get or create a stable project directory under work_dir."""
    os.makedirs(work_dir, exist_ok=True)
    return work_dir


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
    parser.add_argument("--work-dir", default=None,
                        help="Directory for Ghidra project files (default: auto in script dir). "
                             "Reuse to skip already-completed import steps.")
    parser.add_argument("--step", type=int, choices=[1, 2, 3], default=None,
                        help="Run only this step: 1=import old, 2=import new, 3=match. "
                             "Requires --work-dir for steps 2 and 3.")
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

    # Project directory — reusable across runs.
    if args.work_dir:
        work_dir = os.path.abspath(args.work_dir)
    else:
        # Default: ghidra_project/ next to the script
        work_dir = os.path.join(script_dir, "ghidra_project")
    os.makedirs(work_dir, exist_ok=True)

    project_name = "SymbolPort"
    symbols_file = os.path.join(work_dir, "symbols.txt")
    old_name = os.path.basename(old_binary)
    new_name = os.path.basename(new_binary)

    steps = [args.step] if args.step else [1, 2, 3]

    # Check that the Ghidra project exists if skipping earlier steps
    ghidra_project_file = os.path.join(work_dir, f"{project_name}.gpr")
    if args.step and args.step > 1 and not os.path.isfile(ghidra_project_file):
        sys.exit(f"Ghidra project not found: {ghidra_project_file}\n"
                 f"Run earlier steps first (or run without --step for all steps).")

    if 1 in steps:
        # Step 1 – import and auto-analyze old binary (Ghidra loads PDB if found)
        # A preScript disables expensive analyzers (decompiler, strings, etc.)
        # so only function boundaries + PDB symbols are processed.
        print(f"\n[1/3] Importing old binary: {old_name}")
        run_ghidra(analyze, work_dir, f"{project_name}/old",
                   "-import", old_binary,
                   "-preScript", "ConfigureAnalysis.java",
                   "-scriptPath", script_dir,
                   "-analysisTimeoutPerFile", str(args.timeout),
                   timeout=args.timeout)
        print(f"  Step 1 complete. Project saved in: {work_dir}")

    if 2 in steps:
        # Step 2 – import and auto-analyze new binary.
        print(f"\n[2/3] Importing new binary: {new_name}")
        run_ghidra(analyze, work_dir, f"{project_name}/new",
                   "-import", new_binary,
                   "-preScript", "ConfigureAnalysis.java",
                   "-scriptPath", script_dir,
                   "-analysisTimeoutPerFile", str(args.timeout),
                   timeout=args.timeout)
        print(f"  Step 2 complete. Project saved in: {work_dir}")

    if 3 in steps:
        # Step 3 – match functions between old and new binaries.
        # Uses byte hashing, mnemonic hashing, and call-graph propagation.
        src_project_path = f"/old/{old_name}"
        script_args = f"{src_project_path}::{symbols_file}"

        print(f"\n[3/3] Matching functions")
        run_ghidra(analyze, work_dir, f"{project_name}/new",
                   "-process", new_name,
                   "-noanalysis",
                   "-postScript", "MatchFunctions.java", script_args,
                   "-scriptPath", script_dir,
                   timeout=args.timeout)

        if not os.path.isfile(symbols_file):
            sys.exit("MatchFunctions did not produce output. Check Ghidra logs above.")

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

    print(f"\nGhidra project kept at: {work_dir}")


if __name__ == "__main__":
    main()
