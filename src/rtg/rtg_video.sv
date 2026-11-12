//
// rtg_video.sv
//
// RTG (P96 style) scanout for NanoMig, lean version: 8 bit palette pictures of
// 400x300 pixels, shown doubled in both directions on the 800x600 hdmi mode.
//
// The framebuffer lives in the (fast) ram of the sdram. A small engine fetches
// one source row (400 bytes = 25 bursts of 16 bytes) at a time through the sdram
// scanout port into a double buffered line buffer, the pixel side reads the
// line buffer, looks the pixel up in the palette and delivers RGB to the hdmi
// module. Every source row is shown on two display lines, so there is one fetch
// per two display lines and the next row is loaded while the current one is shown.
//
// The register layout is the one of the MiSTle MiniMig RTG implementation
// (registers at $B80100, palette at $B80400). Only what the picture needs is
// implemented, writes to the other registers are ignored:
//
//   $100/$102  framebuffer byte address, long write (hi word first, bits 3:0 ignored)
//   $10c       status (read): bit 0 vblank, bit 2 line fetch overrun (sticky while enabled)
//   $10e       id (read): $8321
//   $110       bit 0: display RTG instead of native video
//   $400-$7ff  palette, 256 long words $00RRGGBB, written as two words (hi first)
//
// Three clocks are involved: clk_bus (28MHz, cpu register access), clk_mem
// (85MHz, sdram) and clk_pix (pixel clock of the hdmi output). The framebuffer
// address and the enable are copied into the pixel domain once per frame (start
// of vblank), row fetch requests cross from the pixel to the memory domain
// through a toggle handshake while their payload is quasi static.
//

`default_nettype none

module rtg_video #(
  parameter H_TOTAL  = 1056,
  parameter H_ACTIVE = 800,
  parameter V_TOTAL  = 628,
  parameter V_ACTIVE = 600
) (
  // ------------------------ register bus (clk_bus) -------------------------
  input  wire        clk_bus,
  input  wire        reset_bus,
  input  wire        reg_sel,       // address in the $B8xxxx window
  input  wire        reg_rd,        // read cycle in progress
  input  wire        reg_wr,        // write cycle in progress (hwr|lwr)
  input  wire [10:1] reg_addr,
  input  wire [15:0] reg_din,
  output wire [15:0] reg_dout,      // zero unless a read of a register is in progress
  output wire        rtg_enable,    // bus domain: rtg display requested

  // ----------------------------- sdram (clk_mem) ---------------------------
  input  wire        clk_mem,
  output reg         mem_req,
  output reg  [18:0] mem_addr,      // 16 byte unit
  input  wire [31:0] mem_data,      // burst beats ...
  input  wire        mem_dv,        // ... flagged by this strobe
  input  wire        mem_ack,       // together with the last beat

  // ------------------------------- video (clk_pix) -------------------------
  input  wire        clk_pix,
  input  wire [10:0] cx,            // current hdmi position
  input  wire [9:0]  cy,
  output reg  [23:0] rgb            // pixel for the position given by cx/cy
);

// the pixel pipeline is this many clocks long, see the lookahead below
localparam LAT    = 4;
localparam BURSTS = 25;             // 400 bytes per source row

// ===========================================================================
// ================================ bus side =================================
// ===========================================================================

reg  [6:0]  base_hi;
reg  [18:0] reg_base;       // framebuffer address bits 22:4
reg         reg_en;
reg  [15:0] clut_high;

// A write is executed when the bus cycle ends, with the address and data that
// were present at its last clock. This does not depend on how early the cpu
// data is valid inside the cycle.
reg         wr_d;
reg [10:1]  wa_q;
reg [15:0]  wd_q;
wire        wr_now = reg_sel && reg_wr;
wire        wr_stb = wr_d && !wr_now;
always @(posedge clk_bus) begin
  wr_d <= wr_now;
  if (wr_now) begin wa_q <= reg_addr; wd_q <= reg_din; end
end

reg [23:0] clut[0:255] /* synthesis syn_ramstyle="block_ram" */;

wire clut_wr = wr_stb && wa_q[10] && wa_q[1];
always @(posedge clk_bus)
  if (clut_wr) clut[wa_q[9:2]] <= { clut_high[7:0], wd_q };

always @(posedge clk_bus) begin
  if (reset_bus) begin
    base_hi  <= 7'd0;
    reg_base <= 19'd0;
    reg_en   <= 1'b0;
  end else if (wr_stb) begin
    if (wa_q[10]) begin
      if (!wa_q[1]) clut_high <= wd_q;
    end else begin
      case ({wa_q[10:1], 1'b0})
        11'h100: base_hi  <= wd_q[6:0];
        11'h102: reg_base <= { base_hi, wd_q[15:4] };
        11'h110: reg_en   <= wd_q[0];
        default: ;
      endcase
    end
  end
end

assign rtg_enable = reg_en;

// status bits coming from the pixel and memory domains
reg        vblank_pix, overrun;
reg  [1:0] vblank_sync, ovr_sync;
always @(posedge clk_bus) begin
  vblank_sync <= { vblank_sync[0], vblank_pix };
  ovr_sync    <= { ovr_sync[0], overrun };
end

reg [15:0] rd_data;
always @* begin
  case ({reg_addr[10:1], 1'b0})
    11'h10c: rd_data = { 13'd0, ovr_sync[1], 1'b0, vblank_sync[1] };
    11'h10e: rd_data = 16'h8321;
    default: rd_data = 16'd0;
  endcase
end

assign reg_dout = (reg_sel && reg_rd) ? rd_data : 16'd0;

// ===========================================================================
// ====================== pixel side (clk_pix) ===============================
// ===========================================================================

// configuration snapshot, taken once per frame at the start of vblank
reg         p_en;
reg  [18:0] p_base;

reg  [1:0]  en_pix;
always @(posedge clk_pix) en_pix <= { en_pix[0], reg_en };

// ---- lookahead position: the pipeline needs LAT clocks to deliver a pixel ----
wire        wrap = (cx >= H_TOTAL - LAT);
wire [10:0] lx   = wrap ? (cx + LAT - H_TOTAL) : (cx + LAT);
wire  [9:0] ly   = wrap ? ((cy == V_TOTAL - 1) ? 10'd0 : cy + 10'd1) : cy;

reg [10:0]  x0;
reg  [9:0]  y0;
always @(posedge clk_pix) begin
  x0 <= lx;
  y0 <= ly;
end

// ---- row fetch requests, issued at the start of a line ----
//   line 627:            row 0 into buffer 0
//   even lines below 598: the next row (line/2 + 1) into the buffer which is not shown
reg         f_toggle;
reg  [18:0] f_addr;
reg         f_buf;
reg  [18:0] r_addr;         // address of the most recently requested row

wire        ev       = (x0 == 11'd0);
wire        fetch_ok = p_en && en_pix[1];

always @(posedge clk_pix) begin
  vblank_pix <= (y0 >= V_ACTIVE);

  if (ev) begin
    if (y0 == V_ACTIVE) begin
      p_en   <= reg_en;
      p_base <= reg_base;
    end

    if (fetch_ok && y0 == V_TOTAL - 1) begin
      r_addr   <= p_base;
      f_addr   <= p_base;
      f_buf    <= 1'b0;
      f_toggle <= ~f_toggle;
    end else if (fetch_ok && !y0[0] && y0 < V_ACTIVE - 2) begin
      r_addr   <= r_addr + BURSTS;
      f_addr   <= r_addr + BURSTS;
      f_buf    <= ~y0[1];
      f_toggle <= ~f_toggle;
    end
  end
end

// ---- line buffer: 2 x 128 words of 32 bit (100 used) ----
reg [31:0] lb[0:255] /* synthesis syn_ramstyle="block_ram" */;

wire        hv = p_en && (y0 < V_ACTIVE) && (x0 < H_ACTIVE);

reg [31:0] lb_q;
always @(posedge clk_pix) lb_q <= lb[{ y0[1], x0[9:3] }];

// stage 1: byte of the word, source pixel = x0/2
reg        s1_valid;
reg  [1:0] s1_sel;
always @(posedge clk_pix) begin
  s1_valid <= hv;
  s1_sel   <= x0[2:1];
end

wire [7:0] s1_index = (s1_sel == 2'd0) ? lb_q[31:24] :
                      (s1_sel == 2'd1) ? lb_q[23:16] :
                      (s1_sel == 2'd2) ? lb_q[15: 8] : lb_q[7:0];

// stage 2: palette lookup (the ram is written on clk_bus, read on clk_pix)
reg [23:0] s2_pal;
reg        s2_valid;
always @(posedge clk_pix) begin
  s2_pal   <= clut[s1_index];
  s2_valid <= s1_valid;
end

// stage 3: output register
always @(posedge clk_pix)
  rgb <= s2_valid ? s2_pal : 24'd0;

// ===========================================================================
// ===================== row fetch engine (clk_mem) ==========================
// ===========================================================================

reg  [2:0] tgl_sync;
always @(posedge clk_mem) tgl_sync <= { tgl_sync[1:0], f_toggle };
wire       req_ev = (tgl_sync[2] != tgl_sync[1]);

// The next burst is requested right when the previous one has been acknowledged,
// which allows one burst per sdram slot. The four beats of a burst arrive one
// per clock and are written into the line buffer as they come.
reg         f_busy;
reg  [4:0]  m_left;          // bursts still to be requested
reg         m_buf;
reg  [6:0]  m_waddr;         // line buffer word address of the next word

reg  [1:0]  en_sync_m;
always @(posedge clk_mem) en_sync_m <= { en_sync_m[0], reg_en };

always @(posedge clk_mem) begin
  if (!en_sync_m[1]) overrun <= 1'b0;

  if (!f_busy) begin
    if (req_ev) begin
      mem_addr <= f_addr;
      mem_req  <= 1'b1;
      m_buf    <= f_buf;
      m_left   <= BURSTS;
      m_waddr  <= 7'd0;
      f_busy   <= 1'b1;
    end
  end else begin
    if (req_ev) overrun <= 1'b1;            // the previous row has not been completed in time
    if (mem_ack) begin
      m_left <= m_left - 5'd1;
      if (m_left == 5'd1) begin
        mem_req <= 1'b0;
        f_busy  <= 1'b0;
      end else begin
        mem_addr <= mem_addr + 19'd1;
      end
    end
  end

  if (mem_dv) begin
    lb[{ m_buf, m_waddr }] <= mem_data;
    m_waddr <= m_waddr + 7'd1;
  end
end

// power-up values (the fpga starts with these)
initial begin
  f_busy = 1'b0; mem_req = 1'b0; f_toggle = 1'b0; tgl_sync = 3'd0; overrun = 1'b0; ovr_sync = 2'd0; en_sync_m = 2'd0;
  vblank_pix = 1'b0; vblank_sync = 2'd0; en_pix = 2'd0; p_en = 1'b0; p_base = 19'd0;
  f_addr = 19'd0; r_addr = 19'd0; f_buf = 1'b0; rgb = 24'd0; wr_d = 1'b0;
end

endmodule
`default_nettype wire
