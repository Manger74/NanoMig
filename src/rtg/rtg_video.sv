//
// rtg_video.sv
//
// RTG (P96 style) scanout for NanoMig.
//
// The framebuffer lives in the (fast) ram of the sdram. A small engine fetches
// whole source lines through the sdram scanout port (16 byte bursts) into a
// double buffered line buffer, the pixel side reads the line buffer and
// produces RGB for the hdmi module. The picture can be 8 bit (palette) or 16
// bit (RGB565/RGB555), repeated up to 4x horizontally/vertically and placed
// inside the 800x600 display by a viewport (units of 16 pixels / 16 lines).
//
// The register layout is the one of the MiSTle MiniMig RTG implementation
// (registers at $B80100, palette at $B80400) so its P96 driver can be reused:
//
//   $100/$102  framebuffer byte address, long write (hi word first, bits 3:0 ignored)
//   $104       bit 15: 8 bit palette mode
//   $106       1: 16 bit RGB565, 2: 16 bit RGB555
//   $10c       status (read): bit 0 vblank, bit 2 line fetch overrun (sticky while enabled),
//              bit 3 scanout active
//   $10e       id (read): $8321
//   $110       bit 0: display RTG instead of native video
//   $114       [1:0] horizontal repeat-1, [3:2] vertical repeat-1
//   $116       source stride in 16 byte units
//   $118/$11a  viewport horizontal start/stop in 16 pixel units (stop exclusive)
//   $11c/$11e  viewport vertical start/stop in 16 line units (stop exclusive)
//   $120       visible source row length in 16 byte units
//   $400-$7ff  palette, 256 long words $00RRGGBB, written as two words (hi first)
//
// Three clocks are involved: clk_bus (28MHz, cpu register access), clk_mem
// (85MHz, sdram) and clk_pix (pixel clock of the hdmi output). The
// configuration is copied into the pixel domain once per frame (start of
// vblank), line fetch requests cross from the pixel to the memory domain
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
localparam LAT = 4;

// ===========================================================================
// ================================ bus side ================================
// ===========================================================================

reg [18:0] reg_base;       // framebuffer address bits 22:4 (fast ram, below 8 MB)
reg  [6:0] base_hi;
reg        reg_clut;
reg  [1:0] reg_fmt;
reg        reg_en;
reg  [3:0] reg_rep;
reg [11:0] reg_stride;
reg  [6:0] reg_hstart, reg_hstop;
reg  [6:0] reg_vstart, reg_vstop;
reg  [7:0] reg_bursts;

// A write is executed when the bus cycle ends, with the address and data that
// were present at its last clock. This does not depend on how early the cpu
// data is valid inside the cycle.
reg        wr_d;
reg [10:1] wa_q;
reg [15:0] wd_q;
wire       wr_now = reg_sel && reg_wr;
wire       wr_stb = wr_d && !wr_now;
always @(posedge clk_bus) begin
  wr_d <= wr_now;
  if (wr_now) begin wa_q <= reg_addr; wd_q <= reg_din; end
end

reg [15:0] clut_high;
reg [23:0] clut[0:255] /* synthesis syn_ramstyle="block_ram" */;

wire clut_wr = wr_stb && wa_q[10] && wa_q[1];
always @(posedge clk_bus)
  if (clut_wr) clut[wa_q[9:2]] <= { clut_high[7:0], wd_q };

always @(posedge clk_bus) begin
  if (reset_bus) begin
    reg_base   <= 19'd0;
    base_hi    <= 7'd0;
    reg_clut   <= 1'b0;
    reg_fmt    <= 2'd1;
    reg_en     <= 1'b0;
    reg_rep    <= 4'd0;
    reg_stride <= 12'd0;
    reg_hstart <= 7'd0;
    reg_hstop  <= 7'd0;
    reg_vstart <= 7'd0;
    reg_vstop  <= 7'd0;
    reg_bursts <= 8'd0;
    clut_high  <= 16'd0;
  end else if (wr_stb) begin
    if (wa_q[10]) begin
      if (!wa_q[1]) clut_high <= wd_q;
    end else begin
      case ({wa_q[10:1], 1'b0})
        11'h100: base_hi    <= wd_q[6:0];
        11'h102: reg_base   <= { base_hi, wd_q[15:4] };
        11'h104: reg_clut   <= wd_q[15];
        11'h106: reg_fmt    <= wd_q[1:0];
        11'h110: reg_en     <= wd_q[0];
        11'h114: reg_rep    <= wd_q[3:0];
        11'h116: reg_stride <= wd_q[11:0];
        11'h118: reg_hstart <= wd_q[6:0];
        11'h11a: reg_hstop  <= wd_q[6:0];
        11'h11c: reg_vstart <= wd_q[6:0];
        11'h11e: reg_vstop  <= wd_q[6:0];
        11'h120: reg_bursts <= wd_q[7:0];
        default: ;
      endcase
    end
  end
end

assign rtg_enable = reg_en;

// status bits coming from the pixel domain
reg [1:0] vblank_sync, active_sync;
reg       vblank_pix, active_pix;
always @(posedge clk_bus) begin
  vblank_sync <= { vblank_sync[0], vblank_pix };
  active_sync <= { active_sync[0], active_pix };
end

reg [1:0] ovr_sync;
reg [15:0] rd_data;
always @* begin
  case ({reg_addr[10:1], 1'b0})
    11'h10c: rd_data = { 12'd0, active_sync[1], ovr_sync[1], 1'b0, vblank_sync[1] };
    11'h10e: rd_data = 16'h8321;
    11'h110: rd_data = { 15'd0, reg_en };
    default: rd_data = 16'd0;
  endcase
end

assign reg_dout = (reg_sel && reg_rd && !reg_addr[10]) ? rd_data : 16'd0;

// ===========================================================================
// ====================== pixel side (clk_pix) ===============================
// ===========================================================================

// ---- configuration snapshot, taken once per frame at the start of vblank ----
reg         p_en, p_clut, p_565;
reg  [1:0]  p_hrep, p_vrep;                 // repeat - 1
reg [10:0]  p_hs, p_he;                     // viewport in pixels
reg  [9:0]  p_vs, p_ve;                     // viewport in lines
reg [11:0]  p_stride;
reg  [7:0]  p_bursts;
reg [18:0]  p_base;

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

// event at the last position of every line: prepare the next line
wire        line_end = (x0 == H_TOTAL - 1);
wire  [9:0] yn       = (y0 == V_TOTAL - 1) ? 10'd0 : y0 + 10'd1;
wire  [9:0] yn1      = (yn == V_TOTAL - 1) ? 10'd0 : yn + 10'd1;

reg         vin;           // current line is inside the viewport
reg  [9:0]  ry;            // source row of the current line
reg  [1:0]  vsub;          // line repeat counter
reg         rdbuf;         // line buffer of the current row

// next-line state
reg         vin_n;
reg  [9:0]  ry_n;
reg  [1:0]  vsub_n;
always @* begin
  vin_n  = vin;
  ry_n   = ry;
  vsub_n = vsub;
  if (yn == p_vs) begin
    vin_n = 1'b1; ry_n = 10'd0; vsub_n = 2'd0;
  end else if (yn == p_ve || yn == 10'd0) begin
    vin_n = 1'b0;
  end else if (vin) begin
    if (vsub == p_vrep) begin vsub_n = 2'd0; ry_n = ry + 10'd1; end
    else vsub_n = vsub + 2'd1;
  end
end

// rows still to come inside the viewport: only fetch what will really be shown
wire [10:0] yn_next_row = { 1'b0, yn } + { 9'd0, p_vrep } + 11'd1;   // first line of the next row
wire        more_rows   = (yn_next_row < { 1'b0, p_ve });

// fetch requests
reg         f_toggle;
reg  [18:0] f_addr;
reg         f_buf;
reg  [18:0] r_addr;        // address of the most recently requested row
reg   [7:0] f_bursts;

wire        fetch_row0  = p_en && (yn1 == p_vs) && (p_vs < V_ACTIVE);
wire        fetch_next  = p_en && vin_n && (vsub_n == 2'd0) && more_rows;

always @(posedge clk_pix) begin
  vblank_pix <= (y0 >= V_ACTIVE);
  active_pix <= p_en;

  if (line_end) begin
    // snapshot the configuration once per frame
    if (yn == V_ACTIVE) begin
      p_en     <= reg_en;
      p_clut   <= reg_clut;
      p_565    <= (reg_fmt != 2'd2);
      p_hrep   <= reg_rep[1:0];
      p_vrep   <= reg_rep[3:2];
      p_hs     <= { reg_hstart, 4'd0 };
      p_he     <= { reg_hstop,  4'd0 };
      p_vs     <= { reg_vstart, 4'd0 };
      p_ve     <= { reg_vstop,  4'd0 };
      p_stride <= reg_stride;
      p_bursts <= reg_bursts;
      p_base   <= reg_base;
    end

    vin    <= vin_n;
    ry     <= ry_n;
    vsub   <= vsub_n;
    rdbuf  <= ry_n[0];

    if (fetch_row0) begin
      r_addr   <= p_base[18:0];
      f_addr   <= p_base[18:0];
      f_buf    <= 1'b0;                    // row 0
      f_bursts <= p_bursts;
      f_toggle <= ~f_toggle;
    end else if (fetch_next) begin
      r_addr   <= r_addr + { 7'd0, p_stride };
      f_addr   <= r_addr + { 7'd0, p_stride };
      f_buf    <= ~ry_n[0];                // next row uses the other buffer
      f_bursts <= p_bursts;
      f_toggle <= ~f_toggle;
    end
  end
end

// ---- horizontal position inside the viewport ----
wire        hv = vin && (x0 >= p_hs) && (x0 < p_he) && p_en;

reg  [9:0]  rx;            // source pixel index
reg  [1:0]  hsub;

always @(posedge clk_pix) begin
  if (!hv) begin
    rx   <= 10'd0;
    hsub <= 2'd0;
  end else if (hsub == p_hrep) begin
    hsub <= 2'd0;
    rx   <= rx + 10'd1;
  end else begin
    hsub <= hsub + 2'd1;
  end
end

// ---- line buffer: 2 x 512 words of 32 bit ----
reg [31:0] lb[0:1023] /* synthesis syn_ramstyle="block_ram" */;

wire [8:0] rword = p_clut ? { 2'b00, rx[9:2] } : { 1'b0, rx[9:1] };
wire [9:0] raddr = { rdbuf, rword };

reg [31:0] lb_q;
always @(posedge clk_pix) lb_q <= lb[raddr];

// stage 1 control
reg        s1_valid, s1_clut, s1_565;
reg  [1:0] s1_sel;
always @(posedge clk_pix) begin
  s1_valid <= hv;
  s1_clut  <= p_clut;
  s1_565   <= p_565;
  s1_sel   <= p_clut ? rx[1:0] : { rx[0], 1'b0 };
end

wire [7:0]  s1_index = (s1_sel == 2'd0) ? lb_q[31:24] :
                       (s1_sel == 2'd1) ? lb_q[23:16] :
                       (s1_sel == 2'd2) ? lb_q[15: 8] : lb_q[7:0];
wire [15:0] s1_half  = s1_sel[1] ? lb_q[15:0] : lb_q[31:16];

// stage 2: palette lookup and direct color expansion
reg [23:0] s2_pal, s2_dir;
reg        s2_valid, s2_clut;
always @(posedge clk_pix) begin
  s2_pal   <= clut[s1_index];
  s2_dir   <= s1_565 ?
              { s1_half[15:11], s1_half[15:13], s1_half[10:5], s1_half[10:9], s1_half[4:0], s1_half[4:2] } :
              { s1_half[14:10], s1_half[14:12], s1_half[ 9:5], s1_half[ 9:7], s1_half[4:0], s1_half[4:2] };
  s2_valid <= s1_valid;
  s2_clut  <= s1_clut;
end

// stage 3: output register
always @(posedge clk_pix)
  rgb <= !s2_valid ? 24'd0 : s2_clut ? s2_pal : s2_dir;

// the clut is written by the cpu from another clock domain. Port b of this
// ram is read on clk_pix, that's why a separate read register is used.

// ===========================================================================
// ===================== line fetch engine (clk_mem) =========================
// ===========================================================================

reg  [2:0] tgl_sync;
always @(posedge clk_mem) tgl_sync <= { tgl_sync[1:0], f_toggle };
wire       req_ev = (tgl_sync[2] != tgl_sync[1]);

// The next burst is requested right when the previous one has been acknowledged,
// which allows one burst per sdram slot. The four beats of a burst arrive one
// per clock and are written into the line buffer as they come.
reg          f_busy;
reg  [7:0]   m_left;         // bursts still to be requested
reg          m_buf;
reg  [8:0]   m_waddr;        // line buffer word address of the next word
reg          lb_we;
reg  [31:0]  lb_wdata;
reg  [9:0]   lb_waddr;
reg          overrun;

reg  [1:0]   en_sync_m;
always @(posedge clk_mem) en_sync_m <= { en_sync_m[0], reg_en };

always @(posedge clk_mem) begin
  lb_we <= 1'b0;

  if (!en_sync_m[1]) overrun <= 1'b0;

  // ---- request side ----
  if (!f_busy) begin
    if (req_ev && f_bursts != 0) begin
      mem_addr <= f_addr;
      mem_req  <= 1'b1;
      m_buf    <= f_buf;
      m_left   <= f_bursts;
      m_waddr  <= 9'd0;
      f_busy   <= 1'b1;
    end
  end else begin
    if (req_ev) overrun <= 1'b1;            // the previous line has not been completed in time
    if (mem_ack) begin
      m_left  <= m_left - 8'd1;
      if (m_left == 8'd1) begin
        mem_req <= 1'b0;
        f_busy  <= 1'b0;
      end else begin
        mem_addr <= mem_addr + 19'd1;
      end
    end
  end

  // ---- line buffer write side ----
  if (mem_dv) begin
    lb_we    <= 1'b1;
    lb_waddr <= { m_buf, m_waddr };
    lb_wdata <= mem_data;
    m_waddr  <= m_waddr + 9'd1;
  end
end

always @(posedge clk_mem)
  if (lb_we) lb[lb_waddr] <= lb_wdata;

// overrun flag towards the bus domain
always @(posedge clk_bus) ovr_sync <= { ovr_sync[0], overrun };

// power-up values (the fpga starts with these)
initial begin
  f_busy = 1'b0; mem_req = 1'b0; f_toggle = 1'b0; tgl_sync = 3'd0; overrun = 1'b0; ovr_sync = 2'd0; en_sync_m = 2'd0;
  p_en = 1'b0; vin = 1'b0; ry = 10'd0; vsub = 2'd0; rdbuf = 1'b0;
  hsub = 2'd0; rx = 10'd0; vblank_pix = 1'b0; active_pix = 1'b0;
  vblank_sync = 2'd0; active_sync = 2'd0; r_addr = 19'd0; f_bursts = 8'd0;
  lb_we = 1'b0; rgb = 24'd0;
  p_hrep = 2'd0; p_vrep = 2'd0; p_hs = 11'd0; p_he = 11'd0; p_vs = 10'd0; p_ve = 10'd0;
  p_stride = 12'd0; p_bursts = 8'd0; p_base = 19'd0; p_clut = 1'b0; p_565 = 1'b1;
  wr_d = 1'b0;
end

endmodule
`default_nettype wire
