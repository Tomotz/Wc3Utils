// Pre-script to disable only the most expensive analyzer (Decompiler Parameter ID)
// which runs full decompilation on every function. We don't need it — parameter info
// comes from the PDB, and Version Tracking doesn't use decompiler output.
//@category Configuration

import ghidra.app.script.GhidraScript;
import ghidra.framework.options.Options;

public class ConfigureAnalysis extends GhidraScript {

    private static final String[] DISABLE = {
        "Decompiler Parameter ID",
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
