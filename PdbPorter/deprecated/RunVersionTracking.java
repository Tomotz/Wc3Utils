// Headless script: run Auto Version Tracking between old and new binaries,
// then export matched symbols to a file.
//
// Uses "::" as delimiter to avoid Ghidra's whitespace splitting of script args.
// Usage: RunVersionTracking.java "<srcProjectPath>::<outputFile>"
//
//@category Version Tracking

import ghidra.app.script.GhidraScript;
import ghidra.feature.vt.api.db.VTSessionDB;
import ghidra.feature.vt.api.main.*;
import ghidra.feature.vt.api.util.VTOptions;
import ghidra.feature.vt.gui.actions.AutoVersionTrackingTask;
import ghidra.feature.vt.gui.util.VTOptionDefines;
import ghidra.features.base.values.GhidraValuesMap;
import ghidra.framework.model.DomainFile;
import ghidra.framework.model.DomainFolder;
import ghidra.framework.options.ToolOptions;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.pcode.Varnode;
import ghidra.program.model.symbol.*;
import ghidra.util.task.TaskLauncher;

import java.io.*;
import java.util.*;

public class RunVersionTracking extends GhidraScript {

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();

        String srcProjectPath, outputPath;
        if (args.length == 1 && args[0].contains("::")) {
            String[] parts = args[0].split("::", 2);
            srcProjectPath = parts[0];
            outputPath = parts[1];
        } else if (args.length >= 2) {
            srcProjectPath = args[0];
            outputPath = args[1];
        } else {
            printerr("Usage: RunVersionTracking.java <srcProjectPath>::<outputFile>");
            return;
        }

        Program dstProg = currentProgram;
        if (dstProg == null) {
            printerr("No destination program open.");
            return;
        }

        // Open source program
        DomainFile srcFile = state.getProject().getProjectData().getFile(srcProjectPath);
        if (srcFile == null) {
            printerr("Source program not found in project: " + srcProjectPath);
            return;
        }

        Program srcProg = (Program) srcFile.getDomainObject(this, true, false, monitor);

        try {
            // Need to end the script transaction for VT to work
            end(true);

            // Create VT session
            String sessionName = "AutoVT_" + System.currentTimeMillis();
            VTSession session = new VTSessionDB(sessionName, srcProg, dstProg, this);

            DomainFolder rootFolder = state.getProject().getProjectData().getRootFolder();
            rootFolder.createFile(sessionName, session, monitor);

            // Configure VT options
            ToolOptions vtOptions = createOptions();

            // Run Auto Version Tracking
            println("Running Auto Version Tracking...");
            AutoVersionTrackingTask autoVtTask = new AutoVersionTrackingTask(session, vtOptions);
            TaskLauncher.launch(autoVtTask);

            println(autoVtTask.getStatusMsg());

            // Save
            dstProg.save("Updated with Auto Version Tracking", monitor);
            session.save();

            // Export matches
            exportMatches(session, srcProg, dstProg, outputPath);

            session.release(this);

        } finally {
            srcProg.release(this);
        }
    }

    private ToolOptions createOptions() {
        ToolOptions options = new VTOptions("Dummy");

        options.setBoolean(VTOptionDefines.CREATE_IMPLIED_MATCHES_OPTION, true);
        options.setBoolean(VTOptionDefines.RUN_EXACT_SYMBOL_OPTION, true);
        options.setBoolean(VTOptionDefines.RUN_EXACT_DATA_OPTION, true);
        options.setBoolean(VTOptionDefines.RUN_EXACT_FUNCTION_BYTES_OPTION, true);
        options.setBoolean(VTOptionDefines.RUN_EXACT_FUNCTION_INST_OPTION, true);
        options.setBoolean(VTOptionDefines.RUN_DUPE_FUNCTION_OPTION, true);
        options.setBoolean(VTOptionDefines.RUN_REF_CORRELATORS_OPTION, true);
        options.setInt(VTOptionDefines.DATA_CORRELATOR_MIN_LEN_OPTION, 5);
        options.setInt(VTOptionDefines.SYMBOL_CORRELATOR_MIN_LEN_OPTION, 3);
        options.setInt(VTOptionDefines.FUNCTION_CORRELATOR_MIN_LEN_OPTION, 10);
        options.setInt(VTOptionDefines.DUPE_FUNCTION_CORRELATOR_MIN_LEN_OPTION, 10);
        options.setBoolean(VTOptionDefines.APPLY_IMPLIED_MATCHES_OPTION, true);
        options.setInt(VTOptionDefines.MIN_VOTES_OPTION, 2);
        options.setInt(VTOptionDefines.MAX_CONFLICTS_OPTION, 0);
        options.setDouble(VTOptionDefines.REF_CORRELATOR_MIN_SCORE_OPTION, 0.95);
        options.setDouble(VTOptionDefines.REF_CORRELATOR_MIN_CONF_OPTION, 10.0);

        return options;
    }

    private void exportMatches(VTSession session, Program srcProg, Program dstProg,
                               String outputPath) throws Exception {

        long imageBase = dstProg.getImageBase().getOffset();
        FunctionManager srcFM = srcProg.getFunctionManager();
        FunctionManager dstFM = dstProg.getFunctionManager();
        AddressSpace srcAS = srcProg.getAddressFactory().getDefaultAddressSpace();
        AddressSpace dstAS = dstProg.getAddressFactory().getDefaultAddressSpace();

        // Collect accepted matches
        Map<Long, VTAssociation> dstToAssoc = new LinkedHashMap<>();
        int totalMatches = 0, acceptedMatches = 0;

        for (VTMatchSet ms : session.getMatchSets()) {
            for (VTMatch match : ms.getMatches()) {
                totalMatches++;
                VTAssociation assoc = match.getAssociation();
                VTAssociationStatus status = assoc.getStatus();
                if (status == VTAssociationStatus.ACCEPTED ||
                    status == VTAssociationStatus.ACCEPTED_FULLY_APPLIED) {
                    long dstAddr = assoc.getDestinationAddress().getOffset();
                    if (!dstToAssoc.containsKey(dstAddr)) {
                        dstToAssoc.put(dstAddr, assoc);
                        acceptedMatches++;
                    }
                }
            }
        }

        println(String.format("VT: %d total matches, %d accepted", totalMatches, acceptedMatches));

        // Sort by destination address
        List<Map.Entry<Long, VTAssociation>> sorted = new ArrayList<>(dstToAssoc.entrySet());
        sorted.sort(Comparator.comparingLong(Map.Entry::getKey));

        int srcFuncCount = 0, dstFuncCount = 0;
        FunctionIterator fi = srcFM.getFunctions(true);
        while (fi.hasNext()) { fi.next(); srcFuncCount++; }
        fi = dstFM.getFunctions(true);
        while (fi.hasNext()) { fi.next(); dstFuncCount++; }

        int outputCount = 0;
        try (PrintWriter pw = new PrintWriter(new FileWriter(outputPath))) {
            pw.println("# Extended symbol map v2 – generated by RunVersionTracking.java");
            pw.println("# Source:      " + srcProg.getName() + "  (" + srcFuncCount + " functions)");
            pw.println("# Destination: " + dstProg.getName() + "  (" + dstFuncCount + " functions)");
            pw.println("# Accepted:    " + acceptedMatches);
            pw.println("# Image base:  0x" + Long.toHexString(imageBase));
            pw.println("# Format: FUNC<TAB>name<TAB>RVA<TAB>codeSize<TAB>paramCount");
            pw.println("#         PARAM<TAB>name<TAB>type<TAB>storage");

            for (Map.Entry<Long, VTAssociation> entry : sorted) {
                VTAssociation assoc = entry.getValue();
                long dstOffset = assoc.getDestinationAddress().getOffset();
                long srcOffset = assoc.getSourceAddress().getOffset();

                Function srcFunc = srcFM.getFunctionAt(srcAS.getAddress(srcOffset));
                Function dstFunc = dstFM.getFunctionAt(dstAS.getAddress(dstOffset));
                if (srcFunc == null || dstFunc == null) continue;

                String name = srcFunc.getName();
                if (name.startsWith("FUN_") || name.startsWith("thunk_FUN_")) continue;

                long rva = dstOffset - imageBase;
                long codeSize = dstFunc.getBody().getNumAddresses();
                Parameter[] params = srcFunc.getParameters();

                pw.println("FUNC\t" + name + "\t" + rva + "\t" + codeSize + "\t" + params.length);
                for (Parameter p : params) {
                    pw.println("PARAM\t" + p.getName() + "\t" +
                               p.getDataType().getDisplayName() + "\t" +
                               formatStorage(p));
                }
                pw.println();
                outputCount++;
            }
        }

        println(String.format("Wrote %d named symbols to %s", outputCount, outputPath));
        println(String.format("Match rate: %d / %d destination functions (%.1f%%)",
                              acceptedMatches, dstFuncCount,
                              100.0 * acceptedMatches / Math.max(dstFuncCount, 1)));
    }

    private String formatStorage(Parameter p) {
        if (p.isRegisterVariable()) {
            Register reg = p.getRegister();
            return "REG:" + (reg != null ? reg.getName() : "???");
        }
        if (p.isStackVariable()) {
            return "STACK:" + p.getStackOffset();
        }
        VariableStorage vs = p.getVariableStorage();
        if (vs != null && vs.getVarnodeCount() > 0) {
            Varnode v = vs.getVarnodes()[0];
            Address addr = v.getAddress();
            if (addr.isRegisterAddress()) {
                Register reg = p.getProgram().getRegister(addr, v.getSize());
                if (reg != null) return "REG:" + reg.getName();
            }
            if (addr.isStackAddress()) {
                return "STACK:" + addr.getOffset();
            }
        }
        return "UNKNOWN";
    }
}
