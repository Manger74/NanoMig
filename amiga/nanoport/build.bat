@echo off
rem Builds nanoport.device with VBCC (vc, vasm, vlink) and the Amiga NDK.
rem vc must be in the PATH and VBCC must point to "targets\m68k-amigaos"
rem (Windows package: https://github.com/kusma/amiga-dev).
rem nanoport_asm.s must come first: it holds the resident tag.
vc +aos68k -cpu=68000 -O2 -nostdlib -o nanoport.device nanoport_asm.s nanoport.c -lvc -lamiga
if errorlevel 1 (echo FEHLER & exit /b 1)
echo Fertig: nanoport.device
