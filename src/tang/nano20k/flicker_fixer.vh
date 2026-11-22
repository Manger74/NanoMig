// Flicker fixer variant (nanomig_ff.gprj, nanomig_020_ff.gprj), must be the
// first file of the project so the define is seen by all files including top
//
// Weave deinterlacer in Amber, field buffer at sdram $700000-$77FFFF. FastRAM
// is reduced to 5MB and SlowRAM to max 1MB. See minimig/flickerfix.v
`define ENABLE_FLICKER_FIXER
