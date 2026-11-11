// DENISE_SPRITE_BRAM equivalence test: denise_sprites with all sprite buffers
// in RAM16 (SPRITE_BRAM=0) and all in block ram (SPRITE_BRAM=8) get the same
// stimulus, sprdata and nsprite are compared every 28MHz clock.
// The chip bus side is modelled like denise.v (64 bit word serialized to
// chip16_r/chip16_idx), sprite registers are written at random times, with
// random fetch modes and resolutions, hpos runs like the beam counter.
// Known difference (+midline_data): a DATA/DATB write to the bank a wide
// sprite reloads in the very next 28MHz clock shows the old word in the
// block ram version (read before write), the RAM16 version the new one.
`timescale 1ns/1ps
module tb;
reg clk = 0; always #17.5 clk = ~clk;
reg [1:0] ph = 0;                      // 28MHz phase within a 7MHz cycle
wire clk7_en = (ph == 2'd3);
wire c1 = ph[0] ^ ph[1], c3 = ph[1];
reg reset = 1, aga = 1, sprena = 1;
reg [8:1] reg_address_in = 0;
reg [8:0] hpos = 0;
reg [15:0] data_in = 0;
reg [47:0] chip48 = 0;
reg [3:0] esprm = 0, osprm = 0;
reg [1:0] spres = 0;

// chip16 serializer as in denise.v (DENISE_EBR)
reg [63:0] data64_in_r = 0;
reg  [1:0] chip16_idx = 0;
reg [15:0] chip16_r;
always @(posedge clk) begin
  chip16_idx <= chip16_idx + 1'd1;
  if (clk7_en) begin data64_in_r <= {data_in, chip48}; chip16_idx <= 0; end
end
always @(*) case (chip16_idx)
  0: chip16_r = data64_in_r[63:48];  1: chip16_r = data64_in_r[47:32];
  2: chip16_r = data64_in_r[31:16];  3: chip16_r = data64_in_r[15:0];
endcase

wire [7:0] ns0, ns1, sd0, sd1;
denise_sprites #(.SPRITE_BRAM(0)) u_dist (.clk(clk), .clk7_en(clk7_en), .reset(reset), .c1(c1), .c3(c3),
  .aga(aga), .reg_address_in(reg_address_in), .hpos(hpos), .data_in(data_in), .chip16_r(chip16_r),
  .chip16_idx(chip16_idx), .sprena(sprena), .esprm(esprm), .osprm(osprm), .spres(spres),
  .nsprite(ns0), .sprdata(sd0));
denise_sprites #(.SPRITE_BRAM(8)) u_bram (.clk(clk), .clk7_en(clk7_en), .reset(reset), .c1(c1), .c3(c3),
  .aga(aga), .reg_address_in(reg_address_in), .hpos(hpos), .data_in(data_in), .chip16_r(chip16_r),
  .chip16_idx(chip16_idx), .sprena(sprena), .esprm(esprm), .osprm(osprm), .spres(spres),
  .nsprite(ns1), .sprdata(sd1));

integer seed = 1, cycles = 0, errors = 0, events = 0, last_err = -10, pixels = 0, writes = 0, loads = 0;
always @(posedge clk) ph <= ph + 1'd1;

// compare every clock (both versions must give identical video)
always @(posedge clk) if (!reset) begin
  cycles = cycles + 1;
  if (ns0 != 0) pixels = pixels + 1;
  if ({ns0, sd0} !== {ns1, sd1}) begin
    errors = errors + 1;
    if (cycles - last_err > 64) events = events + 1;
    last_err = cycles;
    if (errors <= 10) $display("MISMATCH t=%0t hpos=%0d nsprite %b/%b sprdata %h/%h", $time, hpos, ns0, ns1, sd0, sd1);
  end
end
always @(posedge clk) if (u_dist.sps0.ram_wea && clk7_en) writes = writes + 1;
always @(posedge clk) if (u_dist.sps0.load && clk7_en) loads = loads + 1;

// bus: one register access per 7MHz cycle, mostly sprite registers
task cck; begin
  @(negedge clk); while (ph != 2'd3) @(negedge clk);   // set up before the clk7_en edge
end endtask

integer line, i, r;
integer midline_data = 0;   // +midline_data: CPU/copper also write DATA/DATB during the line
reg [2:0] spr;
initial begin
  if ($test$plusargs("midline_data")) midline_data = 1;
  repeat (8) @(negedge clk); reset = 0;
  for (line = 0; line < 600; line = line + 1) begin
    // per line: random fetch mode, resolution, aga, sprite colour banks
    if ((line % 7) == 0) begin
      cck; reg_address_in = 9'h1fc >> 1; data_in = {12'h000, 2'(($random(seed)) & 3), 2'b00};
      spres = $random(seed); aga = ($random(seed) & 7) != 0;
      esprm = $random(seed); osprm = $random(seed);
    end
    for (i = 0; i < 228; i = i + 1) begin      // 228 colour clocks = 456 lores pixels
      cck;
      hpos = (hpos >= 9'h1c7) ? 9'd2 : hpos + 9'd2;
      r = $random(seed) & 255;
      spr = $random(seed);
      chip48 = {$random(seed), $random(seed)};
      data_in = $random(seed);
      if (i < 24)                              // sprite DMA slots at line start: POS, CTL, DATA, DATB
        reg_address_in = {3'b101, spr, 2'($random(seed) & 3)};   // $140 + spr*8 + reg*2
      else if (r < 40)                         // CPU/copper writes during the line
        reg_address_in = {3'b101, spr, midline_data ? 2'($random(seed) & 3) : 2'($random(seed) & 1)};
      else
        reg_address_in = 8'h00;
      if (r == 255) begin                      // occasionally rewrite POS to a visible start
        reg_address_in = {3'b101, spr, 2'b00};
        data_in = {8'h20, 8'(20 + ($random(seed) & 127))};
      end
    end
  end
  $display("%0d clocks, %0d sprite pixels, %0d sprite 0 writes, %0d sprite 0 loads", cycles, pixels, writes, loads);
  if (errors == 0 && pixels > 1000) $display("PASS");
  else $display("FAIL (%0d mismatching clocks in %0d events)", errors, events);
  $finish;
end
endmodule
