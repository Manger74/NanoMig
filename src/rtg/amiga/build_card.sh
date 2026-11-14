#!/bin/bash
# Build the NanoMig P96 drivers with vasm:
#   minimig.card          800x600 core (rtg)
#   minimig_1024rb.card   1024x768 reduced blanking core (VMODE_1024_RB)
#   minimig_1024.card     1024x768 VESA core (VMODE_1024_VESA)
# Picasso96 loads LIBS:Picasso96/minimig.card: copy the file of your core under that name.
#   NDK_INC  directory with the AmigaOS NDK assembler includes (exec/, lvo/, ...), with trailing /
#   P96_INC  directory with Picasso96Develop (PrivateInclude/boardinfo.i, settings.i, Include/libraries/Picasso96.i)
#   VASM     vasmm68k_mot (default: found in PATH)
set -e
cd "$(dirname "$0")"
VASM=${VASM:-vasmm68k_mot}
: "${NDK_INC:?set NDK_INC}"; : "${P96_INC:?set P96_INC}"
# utility/tagitem.i is not pulled in by the other includes of every NDK copy
{ echo '	include utility/tagitem.i'; cat minimig.card.asm; } > .minimig.card.tmp.asm
build() {   # output, extra options
  $VASM .minimig.card.tmp.asm -o $1 -quiet -nowarn=1012 -m68020 -Fhunkexe -kick1hunks -nosym -no-opt $2 \
    -I "$NDK_INC" -I "$P96_INC/PrivateInclude/" -I "$P96_INC/Include/"
}
build minimig.card
build minimig_1024rb.card -DNANOMIG_1024_RB
build minimig_1024.card -DNANOMIG_1024_VESA
rm -f .minimig.card.tmp.asm
ls -l minimig*.card
