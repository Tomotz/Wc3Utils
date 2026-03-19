// Pre-script to disable expensive analyzers for fast function-boundary-only analysis.
// Run as -preScript before import to speed up headless analysis.
//@category Configuration

import ghidra.app.script.GhidraScript;
import ghidra.framework.options.Options;

public class ConfigureAnalysis extends GhidraScript {

    // Analyzers to disable. We keep: PDB Universal (loads symbols/params from PDB),
    // Disassemble Entry Points, Create Function, Subroutine References,
    // Call-Fixup Installer, Call Convention ID, Non-Returning Functions (both),
    // and External Entry References.
    private static final String[] DISABLE = {
        "ASCII Strings",
        "Apply Data Archives",
        "Create Address Tables",
        "Data Reference",
        "Decompiler Parameter ID",
        "Decompiler Switch Analysis",
        "Demangler Microsoft",
        "Embedded Media",
        "Function ID",
        "Function Start Search",
        "Reference",
        "Scalar Operand References",
        "Shared Return Calls",
        "Stack",
        "Windows x86 PE Exception Handling",
        "Windows x86 PE RTTI Analyzer",
        "Windows x86 Thread Environment Block (TEB) Analyzer",
        "WindowsResourceReference",
        "x86 Constant Reference Analyzer",
    };

    @Override
    public void run() throws Exception {
        Options options = currentProgram.getOptions("Analyzers");
        for (String name : DISABLE) {
            try {
                options.setBoolean(name, false);
                println("Disabled: " + name);
            } catch (Exception e) {
                // Analyzer may not exist for this processor
            }
        }
    }
}
