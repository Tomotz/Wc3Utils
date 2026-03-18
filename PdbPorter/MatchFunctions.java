// Ghidra headless script: match functions between two similar binaries.
//
// Given a source program (old, with PDB symbols) and a destination program
// (new, no symbols), matches functions using byte hashing, mnemonic hashing,
// and call-graph propagation, then exports a symbol map.
//
// Usage (via analyzeHeadless):
//   analyzeHeadless <project_dir> <project_name>/new \
//       -process <new_binary> -noanalysis \
//       -postScript MatchFunctions.java "/old/<old_binary>" "/tmp/symbols.txt" \
//       -scriptPath /path/to/this/dir
//
// Output format (gix/PdbGen compatible):
//   # comment lines
//   FunctionName<TAB>RVA_decimal
//
//@category VersionTracking

import ghidra.app.script.GhidraScript;
import ghidra.framework.model.DomainFile;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.symbol.*;

import java.io.*;
import java.security.*;
import java.util.*;

public class MatchFunctions extends GhidraScript {

    private static final int MIN_FUNC_BYTES = 16;
    private static final int MIN_FUNC_INSTRS = 6;
    private static final int MIN_CALL_GRAPH_EDGES = 2;
    private static final int MAX_CALL_GRAPH_ROUNDS = 20;

    // dst entry offset -> src function name
    private final Map<Long, String> matchNames = new LinkedHashMap<>();
    // bidirectional offset tracking for call-graph phase
    private final Map<Long, Long> dstToSrc = new HashMap<>();
    private final Map<Long, Long> srcToDst = new HashMap<>();
    private final Set<Long> matchedSrc = new HashSet<>();
    private final Set<Long> matchedDst = new HashSet<>();

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) {
            printerr("Usage: MatchFunctions.java <src_project_path> <output_file>");
            printerr("  src_project_path: e.g. /old/binary.exe");
            return;
        }

        String srcProjectPath = args[0];
        String outputPath = args[1];

        DomainFile srcFile = state.getProject().getProjectData().getFile(srcProjectPath);
        if (srcFile == null) {
            printerr("Source program not found in project: " + srcProjectPath);
            return;
        }

        Program srcProg = (Program) srcFile.getDomainObject(this, true, false, monitor);
        Program dstProg = currentProgram;

        try {
            List<Function> srcFuncs = collectFunctions(srcProg);
            List<Function> dstFuncs = collectFunctions(dstProg);

            long namedCount = 0;
            for (Function f : srcFuncs) {
                if (f.getSymbol().getSource() != SourceType.DEFAULT) namedCount++;
            }
            println(String.format("Source: %d functions (%d named), Destination: %d functions",
                                  srcFuncs.size(), namedCount, dstFuncs.size()));

            // Phase 1 – exact byte match
            int before = matchNames.size();
            matchByHash(srcProg, dstProg, srcFuncs, dstFuncs, true);
            println(String.format("Phase 1 (exact bytes):  +%d  (total %d)",
                                  matchNames.size() - before, matchNames.size()));

            // Phase 2 – mnemonic + operand-count match
            before = matchNames.size();
            matchByHash(srcProg, dstProg, srcFuncs, dstFuncs, false);
            println(String.format("Phase 2 (mnemonics):    +%d  (total %d)",
                                  matchNames.size() - before, matchNames.size()));

            // Phase 3 – call-graph propagation (iterate until stable)
            for (int round = 1; round <= MAX_CALL_GRAPH_ROUNDS; round++) {
                before = matchNames.size();
                matchByCallGraph(srcProg, dstProg, srcFuncs, dstFuncs);
                int added = matchNames.size() - before;
                if (added == 0) break;
                println(String.format("Phase 3 round %d (call graph): +%d  (total %d)",
                                      round, added, matchNames.size()));
            }

            // Write output
            long imageBase = dstProg.getImageBase().getOffset();
            int outputCount = writeSymbolMap(outputPath, imageBase, srcProg, dstProg,
                                             srcFuncs.size(), dstFuncs.size());

            println(String.format("Wrote %d named symbols to %s", outputCount, outputPath));
            println(String.format("Total matched: %d / %d destination functions (%.1f%%)",
                                  matchNames.size(), dstFuncs.size(),
                                  100.0 * matchNames.size() / dstFuncs.size()));
        } finally {
            srcProg.release(this);
        }
    }

    /* ---------------------------------------------------------------------- */
    /*  Function collection                                                    */
    /* ---------------------------------------------------------------------- */

    private List<Function> collectFunctions(Program prog) {
        List<Function> list = new ArrayList<>();
        FunctionIterator it = prog.getFunctionManager().getFunctions(true);
        while (it.hasNext()) list.add(it.next());
        return list;
    }

    /* ---------------------------------------------------------------------- */
    /*  Hash-based matching (phases 1 & 2)                                     */
    /* ---------------------------------------------------------------------- */

    private void matchByHash(Program srcProg, Program dstProg,
                             List<Function> srcFuncs, List<Function> dstFuncs,
                             boolean useBytes) {

        Map<String, List<Function>> srcMap = buildHashMap(srcProg, srcFuncs, matchedSrc, useBytes);
        Map<String, List<Function>> dstMap = buildHashMap(dstProg, dstFuncs, matchedDst, useBytes);

        for (Map.Entry<String, List<Function>> entry : dstMap.entrySet()) {
            List<Function> srcList = srcMap.get(entry.getKey());
            if (srcList == null) continue;

            List<Function> dstList = entry.getValue();
            // only accept 1-to-1 unique matches
            if (dstList.size() == 1 && srcList.size() == 1) {
                recordMatch(dstList.get(0), srcList.get(0));
            }
        }
    }

    private Map<String, List<Function>> buildHashMap(Program prog,
                                                     List<Function> funcs,
                                                     Set<Long> alreadyMatched,
                                                     boolean useBytes) {
        Map<String, List<Function>> map = new HashMap<>();
        for (Function f : funcs) {
            if (alreadyMatched.contains(f.getEntryPoint().getOffset())) continue;
            String h = useBytes ? hashBytes(prog, f) : hashMnemonics(prog, f);
            if (h != null) map.computeIfAbsent(h, k -> new ArrayList<>()).add(f);
        }
        return map;
    }

    private String hashBytes(Program prog, Function func) {
        AddressSetView body = func.getBody();
        long size = body.getNumAddresses();
        if (size < MIN_FUNC_BYTES || size > 0x100000) return null;
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            Memory mem = prog.getMemory();
            for (AddressRange range : body) {
                byte[] buf = new byte[(int) range.getLength()];
                mem.getBytes(range.getMinAddress(), buf);
                md.update(buf);
            }
            return hexDigest(md);
        } catch (Exception e) {
            return null;
        }
    }

    private String hashMnemonics(Program prog, Function func) {
        InstructionIterator it = prog.getListing().getInstructions(func.getBody(), true);
        StringBuilder sb = new StringBuilder();
        int count = 0;
        while (it.hasNext()) {
            Instruction ins = it.next();
            sb.append(ins.getMnemonicString());
            sb.append((char) ('0' + ins.getNumOperands()));
            sb.append(' ');
            count++;
        }
        if (count < MIN_FUNC_INSTRS) return null;
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            md.update(sb.toString().getBytes("UTF-8"));
            return hexDigest(md);
        } catch (Exception e) {
            return null;
        }
    }

    /* ---------------------------------------------------------------------- */
    /*  Call-graph propagation (phase 3)                                       */
    /* ---------------------------------------------------------------------- */

    private void matchByCallGraph(Program srcProg, Program dstProg,
                                  List<Function> srcFuncs, List<Function> dstFuncs) {

        // Build signatures for unmatched dst functions
        Map<String, List<Function>> dstBySig = new HashMap<>();
        for (Function f : dstFuncs) {
            if (matchedDst.contains(f.getEntryPoint().getOffset())) continue;
            String sig = callSigDst(f);
            if (!sig.isEmpty()) dstBySig.computeIfAbsent(sig, k -> new ArrayList<>()).add(f);
        }

        // Build signatures for unmatched src functions
        Map<String, List<Function>> srcBySig = new HashMap<>();
        for (Function f : srcFuncs) {
            if (matchedSrc.contains(f.getEntryPoint().getOffset())) continue;
            String sig = callSigSrc(f);
            if (!sig.isEmpty()) srcBySig.computeIfAbsent(sig, k -> new ArrayList<>()).add(f);
        }

        for (Map.Entry<String, List<Function>> entry : dstBySig.entrySet()) {
            List<Function> srcList = srcBySig.get(entry.getKey());
            if (srcList == null) continue;
            List<Function> dstList = entry.getValue();
            if (dstList.size() == 1 && srcList.size() == 1) {
                recordMatch(dstList.get(0), srcList.get(0));
            }
        }
    }

    /** Signature for a dst function: sorted matched-callee/caller src names. */
    private String callSigDst(Function func) {
        TreeSet<String> edges = new TreeSet<>();
        try {
            for (Function callee : func.getCalledFunctions(monitor)) {
                String n = matchNames.get(callee.getEntryPoint().getOffset());
                if (n != null) edges.add(">" + n);
            }
            for (Function caller : func.getCallingFunctions(monitor)) {
                String n = matchNames.get(caller.getEntryPoint().getOffset());
                if (n != null) edges.add("<" + n);
            }
        } catch (Exception ignored) { }
        if (edges.size() < MIN_CALL_GRAPH_EDGES) return "";
        return String.join(",", edges);
    }

    /** Signature for a src function: sorted matched-callee/caller names. */
    private String callSigSrc(Function func) {
        TreeSet<String> edges = new TreeSet<>();
        try {
            for (Function callee : func.getCalledFunctions(monitor)) {
                if (matchedSrc.contains(callee.getEntryPoint().getOffset()))
                    edges.add(">" + callee.getName());
            }
            for (Function caller : func.getCallingFunctions(monitor)) {
                if (matchedSrc.contains(caller.getEntryPoint().getOffset()))
                    edges.add("<" + caller.getName());
            }
        } catch (Exception ignored) { }
        if (edges.size() < MIN_CALL_GRAPH_EDGES) return "";
        return String.join(",", edges);
    }

    /* ---------------------------------------------------------------------- */
    /*  Bookkeeping                                                            */
    /* ---------------------------------------------------------------------- */

    private void recordMatch(Function dstFunc, Function srcFunc) {
        long d = dstFunc.getEntryPoint().getOffset();
        long s = srcFunc.getEntryPoint().getOffset();
        if (matchedDst.contains(d) || matchedSrc.contains(s)) return;

        matchedDst.add(d);
        matchedSrc.add(s);
        matchNames.put(d, srcFunc.getName());
        dstToSrc.put(d, s);
        srcToDst.put(s, d);
    }

    /* ---------------------------------------------------------------------- */
    /*  Output                                                                 */
    /* ---------------------------------------------------------------------- */

    private int writeSymbolMap(String path, long imageBase,
                               Program srcProg, Program dstProg,
                               int srcCount, int dstCount) throws IOException {
        List<Map.Entry<Long, String>> sorted = new ArrayList<>(matchNames.entrySet());
        sorted.sort(Comparator.comparingLong(Map.Entry::getKey));

        int count = 0;
        try (PrintWriter pw = new PrintWriter(new FileWriter(path))) {
            pw.println("# Symbol map – generated by MatchFunctions.java");
            pw.println("# Source:      " + srcProg.getName() + "  (" + srcCount + " functions)");
            pw.println("# Destination: " + dstProg.getName() + "  (" + dstCount + " functions)");
            pw.println("# Matched:     " + matchNames.size());
            pw.println("# Image base:  0x" + Long.toHexString(imageBase));
            pw.println("# Format:      name<TAB>RVA  (decimal, compatible with PdbGen)");

            for (Map.Entry<Long, String> e : sorted) {
                String name = e.getValue();
                if (name.startsWith("FUN_") || name.startsWith("thunk_FUN_")) continue;
                long rva = e.getKey() - imageBase;
                pw.println(name + "\t" + rva);
                count++;
            }
        }
        return count;
    }

    private static String hexDigest(MessageDigest md) {
        byte[] d = md.digest();
        StringBuilder sb = new StringBuilder(d.length * 2);
        for (byte b : d) sb.append(String.format("%02x", b & 0xff));
        return sb.toString();
    }
}
