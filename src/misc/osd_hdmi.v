/*
    osd_hdmi.v

    on-screen-display inside the hdmi output. Same MCU interface and
    128x64 u8g2 (SSD1306 page) memory layout as osd_u8g2.v, but the OSD is
    placed by the pixel counters of the hdmi module. It is thus mixed into
    every picture source (native Amiga video and the rtg modes) and always
    centered in the active area of the current hdmi video mode.

    The MCU writes in the clk_wr domain, the overlay is read in the pixel
    clock domain. The buffer is a dual clock block ram, the enable flag is
    synchronized.
*/

module osd_hdmi (
  // MCU side
  input         clk_wr,
  input         reset,
  input         data_in_strobe,
  input         data_in_start,
  input  [7:0]  data_in,

  // hdmi side, cx/cy is the pixel that is generated in this clock
  input         clk,
  input  [10:0] cx,
  input   [9:0] cy,
  input  [10:0] screen_width,
  input   [9:0] screen_height,
  input  [23:0] rgb_in,
  output [23:0] rgb_out
);

localparam integer W = 128*2;     // OSD size on screen (scale 2)
localparam integer H = 64*2;
localparam integer B = 2*2;       // border
localparam integer S = 4*2;       // shadow offset

// ------------------------- MCU write side --------------------------------

reg       enabled;
reg [7:0] command;
reg       addr_state;
reg [9:0] wr_addr;

wire wr_data = data_in_strobe && !data_in_start && command == 8'd2 && !addr_state;

always @(posedge clk_wr) begin
   if(reset)
      enabled <= 1'b0;
   else if(data_in_strobe) begin
      if(data_in_start) begin
         command <= data_in;
         addr_state <= 1'b1;
      end else begin
         addr_state <= 1'b0;

         // OSD command 1: enable (show) or disable (hide) OSD
         if(command == 8'd1 && addr_state)
            enabled <= data_in[0];

         // OSD command 2: tile index followed by display data
         if(command == 8'd2)
            wr_addr <= addr_state ? { data_in[6:0], 3'b000 } : wr_addr + 10'd1;
      end
   end
end

// 1024 bytes = 128 x 64 pixels
reg [7:0] buffer [0:1023];

always @(posedge clk_wr)
   if(wr_data) buffer[wr_addr] <= data_in;

// ------------------------- pixel read side -------------------------------

reg [1:0]  en_s;
reg [10:0] hstart;
reg  [9:0] vstart;

always @(posedge clk) begin
   en_s   <= { en_s[0], enabled };
   hstart <= screen_width[10:1]  - W/2;
   vstart <= screen_height[9:1]  - H/2;
end

// position of the next pixel relative to the OSD text area. Everything
// below is registered so that it is valid together with the rgb of cx.
wire signed [11:0] hpos = $signed({1'b0, cx}) + 12'sd1 - $signed({1'b0, hstart});
wire signed [10:0] vpos = $signed({1'b0, cy}) - $signed({1'b0, vstart});

reg       active, tactive, sactive;
reg [7:0] buffer_byte;
reg [2:0] bit_sel;

always @(posedge clk) begin
   active  <= en_s[1] && hpos >= -B && hpos < W+B && vpos >= -B && vpos < H+B;
   tactive <= hpos >= 0 && hpos < W && vpos >= 0 && vpos < H;
   sactive <= en_s[1] && hpos >= S-B && hpos < W+B+S && vpos >= S-B && vpos < H+B+S;
   buffer_byte <= buffer[{ vpos[6:4], hpos[7:1] }];
   bit_sel <= vpos[3:1];
end

wire [7:0] r = rgb_in[23:16];
wire [7:0] g = rgb_in[15: 8];
wire [7:0] b = rgb_in[ 7: 0];

// OSD background: picture shines through dimmed and blue tinted,
// less where the shadow is active. Outside the OSD the shadow halves it.
wire [23:0] osd_bg = sactive ? { 4'h0, r[7:4], 4'h0, g[7:4], 4'h4, b[7:4] }
                             : { 3'h0, r[7:3], 3'h0, g[7:3], 3'h2, b[7:3] };
wire [23:0] shadow = { 1'b0, r[7:1], 1'b0, g[7:1], 1'b0, b[7:1] };

assign rgb_out = active  ? ((tactive && buffer_byte[bit_sel]) ? 24'hffffff : osd_bg) :
                 sactive ? shadow : rgb_in;

endmodule
