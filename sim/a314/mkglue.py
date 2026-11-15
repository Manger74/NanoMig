# extracts the A314 wiring block verbatim from minimig.v (no re-implementation)
import sys
s = open(sys.argv[1]).read()
# (both variants; the testbench is compiled without A314_FAST, so the chip bus glue is used)
a = s.index("`ifdef ENABLE_A314\n`ifdef A314_FAST")
b = s.index("// ---- end of A314")
open(sys.argv[2], "w").write(s[a:b] + "\n")
