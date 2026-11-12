#!/bin/bash
# Build the NanoMig (800x600) P96 driver minimig.card with vasm.
#   NDK_INC  directory with the AmigaOS NDK assembler includes (exec/, lvo/, ...), with trailing /
#   P96_INC  directory with Picasso96Develop (PrivateInclude/boardinfo.i, settings.i, Include/libraries/Picasso96.i)
#   VASM     vasmm68k_mot (default: found in PATH)
set -e
cd "$(dirname "$0")"
VASM=${VASM:-vasmm68k_mot}
: "${NDK_INC:?set NDK_INC}"; : "${P96_INC:?set P96_INC}"
# utility/tagitem.i is not pulled in by the other includes of every NDK copy
{ echo '	include utility/tagitem.i'; cat minimig.card.asm; } > .minimig.card.tmp.asm
$VASM .minimig.card.tmp.asm -o minimig.card -L minimig.card.lst -quiet -nowarn=1012 -m68020 -Fhunkexe -kick1hunks -nosym -no-opt \
  -I "$NDK_INC" -I "$P96_INC/PrivateInclude/" -I "$P96_INC/Include/"
rm -f .minimig.card.tmp.asm
ls -l minimig.card
