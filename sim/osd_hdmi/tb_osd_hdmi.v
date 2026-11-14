// osd_hdmi test: the same MCU data is written to osd_u8g2 (reference, as
// used before in front of the hdmi module) and to osd_hdmi. One frame of
// each is dumped as "x y r g b" (8 bit) for compare.py.
//
// osd_u8g2 runs on clk_a with an Amiga like hs/vs stream, osd_hdmi is
// written on clk_a and read on the unrelated clk_b with hdmi counters.

`timescale 1ns/1ps

module tb_osd_hdmi;

parameter integer FRAME_W  = 908;   // hdmi timing of the native PAL mode
parameter integer FRAME_H  = 626;
parameter integer SCREEN_W = 720;
parameter integer SCREEN_H = 576;
parameter integer RUN_REF  = 1;     // also dump the osd_u8g2 reference

reg clk_a = 0, clk_b = 0;
always #17.6 clk_a = ~clk_a;    // 28.4 MHz
always #15.3 clk_b = ~clk_b;    // unrelated pixel clock

reg reset = 1;
reg strobe = 0, start = 0;
reg [7:0] din = 0;

// picture source: constant colour, 4 bit per channel as delivered by the Amiga
localparam [3:0] R4 = 4'ha, G4 = 4'h5, B4 = 4'hc;

// ---------------- reference: osd_u8g2 with Amiga like sync ---------------
reg [10:0] ax = 0; reg [9:0] ay = 0;
always @(posedge clk_a) begin
   ax <= ax == FRAME_W-1 ? 0 : ax + 1;
   if(ax == FRAME_W-1) ay <= ay == FRAME_H-1 ? 0 : ay + 1;
end
wire hs_n = !(ax >= SCREEN_W+24 && ax < SCREEN_W+24+72);
wire vs_n = !(ay >= SCREEN_H+5  && ay < SCREEN_H+10);

wire [5:0] ro, go, bo;
osd_u8g2 ref_osd (
   .clk(clk_a), .reset(reset),
   .data_in_strobe(strobe), .data_in_start(start), .data_in(din),
   .hs(hs_n), .vs(vs_n),
   .r_in({R4,2'b00}), .g_in({G4,2'b00}), .b_in({B4,2'b00}),
   .r_out(ro), .g_out(go), .b_out(bo)
);

// ---------------- device under test: osd_hdmi -----------------------------
reg [10:0] cx = 0; reg [9:0] cy = 0;
always @(posedge clk_b) begin
   cx <= cx == FRAME_W-1 ? 0 : cx + 1;
   if(cx == FRAME_W-1) cy <= cy == FRAME_H-1 ? 0 : cy + 1;
end

wire [23:0] rgb_out;
osd_hdmi dut (
   .clk_wr(clk_a), .reset(reset),
   .data_in_strobe(strobe), .data_in_start(start), .data_in(din),
   .clk(clk_b), .cx(cx), .cy(cy),
   .screen_width(SCREEN_W[10:0]), .screen_height(SCREEN_H[9:0]),
   .rgb_in({R4,4'h0, G4,4'h0, B4,4'h0}), .rgb_out(rgb_out)
);

// ---------------- MCU writes ----------------------------------------------
task send(input s, input [7:0] d);
   begin
      @(posedge clk_a); strobe <= 1; start <= s; din <= d;
      @(posedge clk_a); strobe <= 0; start <= 0;
      repeat(3) @(posedge clk_a);     // SPI bytes are far apart
   end
endtask

integer t, i, fd, seed;
reg [7:0] mem [0:1023];

initial begin
   seed = 42;
   for(i = 0; i < 1024; i = i + 1) mem[i] = $random(seed);
   fd = $fopen("buffer.txt", "w");
   for(i = 0; i < 1024; i = i + 1) $fdisplay(fd, "%0d", mem[i]);
   $fclose(fd);

   repeat(4) @(posedge clk_a); reset <= 0;

   // first half tile by tile (backwards), second half in one burst
   for(t = 63; t >= 0; t = t - 1) begin
      send(1, 8'd2); send(0, t);
      for(i = 0; i < 8; i = i + 1) send(0, mem[t*8+i]);
   end
   send(1, 8'd2); send(0, 8'd64);
   for(i = 512; i < 1024; i = i + 1) send(0, mem[i]);

   send(1, 8'd1); send(0, 8'd1);     // show OSD
end

// ---------------- frame dumps ---------------------------------------------
integer fr = 0, fn = 0, fdr, fdn;
initial begin fdr = $fopen("ref.txt", "w"); fdn = $fopen("new.txt", "w"); end

// the rgb sampled together with cx/cy is the pixel cx/cy (as in hdmi.sv)
always @(posedge clk_b) begin
   if(cx == 0 && cy == 0) fn = fn + 1;
   if(fn == 3 && cx < SCREEN_W && cy < SCREEN_H)
      $fdisplay(fdn, "%0d %0d %0d %0d %0d", cx, cy, rgb_out[23:16], rgb_out[15:8], rgb_out[7:0]);
end

always @(posedge clk_a) begin
   if(ax == 0 && ay == 0) fr = fr + 1;
   if(RUN_REF && fr == 3)
      $fdisplay(fdr, "%0d %0d %0d %0d %0d", ax, ay, {ro,2'b00}, {go,2'b00}, {bo,2'b00});
   if(fr == 4 && fn >= 4) begin $fclose(fdr); $fclose(fdn); $finish; end
end

endmodule
