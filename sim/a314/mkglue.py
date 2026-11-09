# extracts the A314 wiring block verbatim from minimig.v (no re-implementation)
import sys
s = open(sys.argv[1]).read()
a = s.index("`ifdef ENABLE_A314\n// ---- A314 clockport interface")
b = s.index("// ---- end of A314")
open(sys.argv[2], "w").write(s[a:b] + "\n")
