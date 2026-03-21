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
import ghidra.program.model.lang.Register;
import ghidra.program.model.pcode.Varnode;

import java.io.*;
import java.security.*;
import java.util.*;

public class MatchFunctions extends GhidraScript {

    private static final int MIN_CALL_GRAPH_EDGES = 2;
    private static final int MAX_CALL_GRAPH_ROUNDS = 20;
    private static final double ALIGN_MAX_ERROR = 0.15;
    private static final int ALIGN_REF_BYTES = 2000;

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

        // port_pdb.py passes both args joined with "::" to avoid Ghidra's
        // analyzeHeadless splitting paths that contain spaces.
        // ("|" is unsafe on Windows — cmd.exe interprets it as a pipe.)
        String srcProjectPath, outputPath;
        if (args.length == 1 && args[0].contains("::")) {
            String[] parts = args[0].split("::", 2);
            srcProjectPath = parts[0];
            outputPath = parts[1];
        } else if (args.length >= 2) {
            srcProjectPath = args[0];
            outputPath = args[1];
        } else {
            printerr("Usage: MatchFunctions.java <src_project_path>|<output_file>");
            printerr("  or:  MatchFunctions.java <src_project_path> <output_file>");
            printerr("  src_project_path: e.g. /old/binary.exe");
            return;
        }

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

            // Pre-compute function signatures for alignment matching
            println("Pre-computing function signatures...");
            FuncSig[] srcSigs = buildAllSigs(srcProg, srcFuncs);
            FuncSig[] dstSigs = buildAllSigs(dstProg, dstFuncs);

            // Phase 1 – ordered alignment matching (walks both lists in order,
            // fuzzy byte/mnemonic/opcount scoring, subsumes exact-hash matching)
            int before = matchNames.size();
            matchByAlignment(srcSigs, dstSigs, srcProg, dstProg);
            println(String.format("Phase 1 (alignment):   +%d  (total %d)",
                                  matchNames.size() - before, matchNames.size()));

            // Phase 2 – call-graph propagation (iterate until stable)
            for (int round = 1; round <= MAX_CALL_GRAPH_ROUNDS; round++) {
                before = matchNames.size();
                matchByCallGraph(srcProg, dstProg, srcFuncs, dstFuncs);
                int added = matchNames.size() - before;
                if (added == 0) break;
                println(String.format("Phase 2 round %d (call graph): +%d  (total %d)",
                                      round, added, matchNames.size()));
            }

            // Phase 3 – neighbor propagation (function ordering)
            for (int round = 1; round <= MAX_CALL_GRAPH_ROUNDS; round++) {
                before = matchNames.size();
                matchByNeighbor(srcFuncs, dstFuncs, srcProg, dstProg);
                int added = matchNames.size() - before;
                if (added == 0) break;
                println(String.format("Phase 3 round %d (neighbors): +%d  (total %d)",
                                      round, added, matchNames.size()));
            }

            // Phase 4 – call-graph propagation again (picks up matches enabled by neighbors)
            before = matchNames.size();
            matchByCallGraph(srcProg, dstProg, srcFuncs, dstFuncs);
            if (matchNames.size() > before) {
                println(String.format("Phase 4 (call graph):  +%d  (total %d)",
                                      matchNames.size() - before, matchNames.size()));
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
    /*  Alignment-based matching (phase 1)                                     */
    /* ---------------------------------------------------------------------- */

    /** Pre-computed signature for a single function. */
    private static class FuncSig {
        final long offset;
        final byte[] bytes;
        final String[] mnemonics;
        final int[] opCounts;

        FuncSig(long offset, byte[] bytes, String[] mnemonics, int[] opCounts) {
            this.offset = offset;
            this.bytes = bytes;
            this.mnemonics = mnemonics;
            this.opCounts = opCounts;
        }
    }

    /** Pre-compute signatures for all functions in a program. */
    private FuncSig[] buildAllSigs(Program prog, List<Function> funcs) {
        FuncSig[] sigs = new FuncSig[funcs.size()];
        Memory mem = prog.getMemory();
        Listing listing = prog.getListing();
        for (int i = 0; i < funcs.size(); i++) {
            Function f = funcs.get(i);
            long offset = f.getEntryPoint().getOffset();
            AddressSetView body = f.getBody();

            // Get bytes
            byte[] bytes;
            try {
                long size = Math.min(body.getNumAddresses(), 0x100000);
                if (size == 0) {
                    sigs[i] = new FuncSig(offset, new byte[0], new String[0], new int[0]);
                    continue;
                }
                ByteArrayOutputStream bos = new ByteArrayOutputStream((int) size);
                for (AddressRange range : body) {
                    byte[] buf = new byte[(int) range.getLength()];
                    mem.getBytes(range.getMinAddress(), buf);
                    bos.write(buf);
                }
                bytes = bos.toByteArray();
            } catch (Exception e) {
                bytes = new byte[0];
            }

            // Get mnemonics and operand counts
            InstructionIterator it = listing.getInstructions(body, true);
            List<String> mnems = new ArrayList<>();
            List<Integer> ops = new ArrayList<>();
            while (it.hasNext()) {
                Instruction ins = it.next();
                mnems.add(ins.getMnemonicString());
                ops.add(ins.getNumOperands());
            }

            String[] mnemArr = mnems.toArray(new String[0]);
            int[] opArr = new int[ops.size()];
            for (int j = 0; j < ops.size(); j++) opArr[j] = ops.get(j);

            sigs[i] = new FuncSig(offset, bytes, mnemArr, opArr);
        }
        return sigs;
    }

    /**
     * Score how similar two functions are.
     * Each byte counts as 1 unit, each mnemonic as 1 unit, each operand count as 1 unit.
     * Total score = total matches / total possible units.
     * Instruction-count differences are penalized as mismatches.
     */
    private double scorePair(FuncSig a, FuncSig b) {
        int maxBytes = Math.max(a.bytes.length, b.bytes.length);
        int maxInstrs = Math.max(a.mnemonics.length, b.mnemonics.length);
        int totalUnits = maxBytes + maxInstrs + maxInstrs; // bytes + mnemonics + opCounts
        if (totalUnits == 0) return 0;

        int matches = 0;

        // Byte matches (position by position)
        int minBytes = Math.min(a.bytes.length, b.bytes.length);
        for (int i = 0; i < minBytes; i++) {
            if (a.bytes[i] == b.bytes[i]) matches++;
        }
        // Extra bytes in the longer function count as mismatches (already in totalUnits)

        // Mnemonic matches (position by position)
        int minInstrs = Math.min(a.mnemonics.length, b.mnemonics.length);
        for (int i = 0; i < minInstrs; i++) {
            if (a.mnemonics[i].equals(b.mnemonics[i])) matches++;
        }
        // Extra instructions in the longer function count as mismatches

        // Operand count matches (position by position)
        for (int i = 0; i < minInstrs; i++) {
            if (a.opCounts[i] == b.opCounts[i]) matches++;
        }

        return (double) matches / totalUnits;
    }

    /**
     * Logarithmic threshold: 100% for tiny functions, up to 15% error at 2000 bytes.
     * Larger functions continue to scale logarithmically beyond that.
     */
    private double alignThreshold(int byteCount) {
        if (byteCount == 0) return 1.0;
        double error = ALIGN_MAX_ERROR * Math.log(1 + byteCount) / Math.log(1 + ALIGN_REF_BYTES);
        return 1.0 - error;
    }

    /**
     * Walk both function lists in address order, matching by similarity score.
     * Uses expanding diagonal search to handle insertions/deletions.
     * First match above threshold wins — everything before it is skipped.
     */
    private void matchByAlignment(FuncSig[] srcSigs, FuncSig[] dstSigs,
                                   Program srcProg, Program dstProg) {
        AddressSpace srcAS = srcProg.getAddressFactory().getDefaultAddressSpace();
        AddressSpace dstAS = dstProg.getAddressFactory().getDefaultAddressSpace();

        int si = 0, di = 0;

        while (si < srcSigs.length && di < dstSigs.length) {
            // Skip already matched or empty
            while (si < srcSigs.length &&
                   (srcSigs[si].mnemonics.length == 0 || matchedSrc.contains(srcSigs[si].offset)))
                si++;
            while (di < dstSigs.length &&
                   (dstSigs[di].mnemonics.length == 0 || matchedDst.contains(dstSigs[di].offset)))
                di++;
            if (si >= srcSigs.length || di >= dstSigs.length) break;

            // Expanding diagonal search — no limit, stop at first match
            boolean found = false;
            for (int dist = 0; !found; dist++) {
                boolean anyInBounds = false;
                for (int ds = 0; ds <= dist && !found; ds++) {
                    int dd = dist - ds;
                    int tsi = si + ds, tdi = di + dd;
                    if (tsi >= srcSigs.length || tdi >= dstSigs.length) continue;
                    anyInBounds = true;
                    if (srcSigs[tsi].mnemonics.length == 0 ||
                        matchedSrc.contains(srcSigs[tsi].offset)) continue;
                    if (dstSigs[tdi].mnemonics.length == 0 ||
                        matchedDst.contains(dstSigs[tdi].offset)) continue;

                    int byteCount = Math.max(srcSigs[tsi].bytes.length,
                                             dstSigs[tdi].bytes.length);
                    double score = scorePair(srcSigs[tsi], dstSigs[tdi]);
                    if (score >= alignThreshold(byteCount)) {
                        Function sf = srcProg.getFunctionManager().getFunctionAt(
                            srcAS.getAddress(srcSigs[tsi].offset));
                        Function df = dstProg.getFunctionManager().getFunctionAt(
                            dstAS.getAddress(dstSigs[tdi].offset));
                        if (sf != null && df != null) {
                            recordMatch(df, sf);
                        }
                        si = tsi + 1;
                        di = tdi + 1;
                        found = true;
                    }
                }
                if (!anyInBounds) break; // exhausted both lists
            }

            if (!found) break; // no more matches possible
        }
    }

    /* ---------------------------------------------------------------------- */
    /*  Call-graph propagation (phase 2)                                       */
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
    /*  Neighbor propagation (phase 3)                                         */
    /* ---------------------------------------------------------------------- */

    /**
     * Match unmatched functions by address ordering: if a function's neighbor
     * (predecessor or successor by address) is already matched, the corresponding
     * neighbor in the source program is a candidate match.
     */
    private void matchByNeighbor(List<Function> srcFuncs, List<Function> dstFuncs,
                                  Program srcProg, Program dstProg) {
        // srcFuncs/dstFuncs are in address order (from getFunctions(true))
        Map<Long, Integer> srcIdx = new HashMap<>();
        for (int i = 0; i < srcFuncs.size(); i++) {
            srcIdx.put(srcFuncs.get(i).getEntryPoint().getOffset(), i);
        }

        List<long[]> pending = new ArrayList<>();

        for (int i = 0; i < dstFuncs.size(); i++) {
            long dstOff = dstFuncs.get(i).getEntryPoint().getOffset();
            if (matchedDst.contains(dstOff)) continue;

            Long candFromPred = null, candFromSucc = null;

            // Predecessor: if dst[i-1] matched to src[k], candidate is src[k+1]
            if (i > 0) {
                Long predSrc = dstToSrc.get(dstFuncs.get(i - 1).getEntryPoint().getOffset());
                if (predSrc != null) {
                    Integer si = srcIdx.get(predSrc);
                    if (si != null && si + 1 < srcFuncs.size()) {
                        long next = srcFuncs.get(si + 1).getEntryPoint().getOffset();
                        if (!matchedSrc.contains(next)) candFromPred = next;
                    }
                }
            }

            // Successor: if dst[i+1] matched to src[k], candidate is src[k-1]
            if (i + 1 < dstFuncs.size()) {
                Long succSrc = dstToSrc.get(dstFuncs.get(i + 1).getEntryPoint().getOffset());
                if (succSrc != null) {
                    Integer si = srcIdx.get(succSrc);
                    if (si != null && si - 1 >= 0) {
                        long prev = srcFuncs.get(si - 1).getEntryPoint().getOffset();
                        if (!matchedSrc.contains(prev)) candFromSucc = prev;
                    }
                }
            }

            Long candidate = null;
            boolean bothAgree = false;
            if (candFromPred != null && candFromSucc != null) {
                if (candFromPred.equals(candFromSucc)) {
                    candidate = candFromPred;
                    bothAgree = true;
                }
                // disagree → skip
            } else if (candFromPred != null) {
                candidate = candFromPred;
            } else if (candFromSucc != null) {
                candidate = candFromSucc;
            }

            if (candidate != null) {
                if (bothAgree) {
                    // Both neighbors agree — match without further checks
                    pending.add(new long[]{dstOff, candidate});
                } else {
                    // Single neighbor — require matching bytes or mnemonics
                    Function df = dstFuncs.get(i);
                    Function sf = srcProg.getFunctionManager().getFunctionAt(
                        srcProg.getAddressFactory().getDefaultAddressSpace().getAddress(candidate));
                    if (sf != null && hashesMatch(srcProg, sf, dstProg, df)) {
                        pending.add(new long[]{dstOff, candidate});
                    }
                }
            }
        }

        // Apply batched matches (re-check for conflicts within the batch)
        AddressSpace srcAS = srcProg.getAddressFactory().getDefaultAddressSpace();
        AddressSpace dstAS = dstProg.getAddressFactory().getDefaultAddressSpace();
        for (long[] pair : pending) {
            if (matchedDst.contains(pair[0]) || matchedSrc.contains(pair[1])) continue;
            Function df = dstProg.getFunctionManager().getFunctionAt(dstAS.getAddress(pair[0]));
            Function sf = srcProg.getFunctionManager().getFunctionAt(srcAS.getAddress(pair[1]));
            if (df != null && sf != null) recordMatch(df, sf);
        }
    }

    /** Check if two functions have matching byte hash or mnemonic hash (no size threshold). */
    private boolean hashesMatch(Program srcProg, Function srcFunc,
                                Program dstProg, Function dstFunc) {
        // Try exact bytes first
        String srcBytes = hashBytesNoMin(srcProg, srcFunc);
        String dstBytes = hashBytesNoMin(dstProg, dstFunc);
        if (srcBytes != null && srcBytes.equals(dstBytes)) return true;

        // Fall back to mnemonic hash
        String srcMnem = hashMnemonicsNoMin(srcProg, srcFunc);
        String dstMnem = hashMnemonicsNoMin(dstProg, dstFunc);
        return srcMnem != null && srcMnem.equals(dstMnem);
    }

    private String hashBytesNoMin(Program prog, Function func) {
        AddressSetView body = func.getBody();
        long size = body.getNumAddresses();
        if (size == 0 || size > 0x100000) return null;
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

    private String hashMnemonicsNoMin(Program prog, Function func) {
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
        if (count == 0) return null;
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            md.update(sb.toString().getBytes("UTF-8"));
            return hexDigest(md);
        } catch (Exception e) {
            return null;
        }
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

        FunctionManager srcFM = srcProg.getFunctionManager();
        FunctionManager dstFM = dstProg.getFunctionManager();
        AddressSpace srcAS = srcProg.getAddressFactory().getDefaultAddressSpace();
        AddressSpace dstAS = dstProg.getAddressFactory().getDefaultAddressSpace();

        int count = 0;
        try (PrintWriter pw = new PrintWriter(new FileWriter(path))) {
            pw.println("# Extended symbol map v2 – generated by MatchFunctions.java");
            pw.println("# Source:      " + srcProg.getName() + "  (" + srcCount + " functions)");
            pw.println("# Destination: " + dstProg.getName() + "  (" + dstCount + " functions)");
            pw.println("# Matched:     " + matchNames.size());
            pw.println("# Image base:  0x" + Long.toHexString(imageBase));
            pw.println("# Format: FUNC<TAB>name<TAB>RVA<TAB>codeSize<TAB>paramCount");
            pw.println("#         PARAM<TAB>name<TAB>type<TAB>storage");

            for (Map.Entry<Long, String> e : sorted) {
                String name = e.getValue();
                if (name.startsWith("FUN_") || name.startsWith("thunk_FUN_")) continue;
                long rva = e.getKey() - imageBase;

                // Get code size from destination function
                Function dstFunc = dstFM.getFunctionAt(dstAS.getAddress(e.getKey()));
                long codeSize = (dstFunc != null) ? dstFunc.getBody().getNumAddresses() : 0;

                // Get parameter info from source function
                Long srcOffset = dstToSrc.get(e.getKey());
                Function srcFunc = null;
                if (srcOffset != null) {
                    srcFunc = srcFM.getFunctionAt(srcAS.getAddress(srcOffset));
                }

                Parameter[] params = (srcFunc != null) ? srcFunc.getParameters() : new Parameter[0];
                pw.println("FUNC\t" + name + "\t" + rva + "\t" + codeSize + "\t" + params.length);

                for (Parameter p : params) {
                    String pName = p.getName();
                    String pType = p.getDataType().getDisplayName();
                    String storage = formatStorage(p);
                    pw.println("PARAM\t" + pName + "\t" + pType + "\t" + storage);
                }

                pw.println(); // blank separator
                count++;
            }
        }
        return count;
    }

    private String formatStorage(Parameter p) {
        if (p.isRegisterVariable()) {
            Register reg = p.getRegister();
            return "REG:" + (reg != null ? reg.getName() : "???");
        }
        if (p.isStackVariable()) {
            return "STACK:" + p.getStackOffset();
        }
        // Complex storage — try to extract from varnodes
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

    private static String hexDigest(MessageDigest md) {
        byte[] d = md.digest();
        StringBuilder sb = new StringBuilder(d.length * 2);
        for (byte b : d) sb.append(String.format("%02x", b & 0xff));
        return sb.toString();
    }
}
