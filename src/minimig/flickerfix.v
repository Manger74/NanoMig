//
// flickerfix.v
//
// Weave deinterlacer for Amber. Amber outputs every input line twice. In
// interlace mode the first copy of a line stays as is and the second copy
// is replaced by the matching line of the previous field, read from a field
// buffer in external memory. The short (odd) field starts half a line later
// after vsync, so its line n sits between line n and n+1 of the long field:
//   long field:  second copy of line n = short field line n
//   short field: second copy of line n = long field line n+1
// A single field buffer is enough: each row is prefetched before the current
// field overwrites it.
//
// Pixels are stored with 12 bits (the 4 bit per color Amber outputs), 8
// pixels packed into 3 words: pixel i of a group at bits 12i+11:12i.
//
// Memory interface: one read and one write job per line, fb_len*4 words
// each. A job is started by toggling *_req with *_addr/*_idx stable. The
// memory side moves the words in bursts (word addr+n <-> line buffer index
// idx+n) through the wb_*/rb_* ports (clk_mem domain) and toggles *_ack when
// the whole job is done. A job not done at the next line start is an overrun:
// that line falls back to plain line doubling.
//

module flickerfix #(
  parameter X0 = 88,   // first stored hires pixel
  parameter W  = 832,  // stored pixels per line, multiple of 64 (8 word bursts)
  parameter K0 = 16,   // first stored line after vsync
  parameter H  = 300   // stored lines per field, H*W*3/8 <= 128k words
)(
  input             clk,        // 28 MHz pixel side
  input             en,
  input             hss,        // start of input line
  input      [10:0] wr_ptr,
  input      [9:0]  rd_ptr,
  input             first_half, // Amber outputs the second copy of a line
  input             vs_n,
  input      [14:0] pix_in,     // pixel as written into Amber's line buffer
  output reg [14:0] pix_out,    // aligned with Amber's lbfo2
  output reg        pix_use,
  output reg        weave = 1'b0,
  output reg        overrun = 1'b0, // line transfers not done in time

  output     [6:0]  fb_len,     // words per job / 4
  output reg        rd_req = 1'b0,
  output reg [16:0] rd_addr,    // 32 bit word address in field buffer
  output reg [9:0]  rd_idx,     // line buffer index of first word
  input             rd_ack,
  output reg        wr_req = 1'b0,
  output reg [16:0] wr_addr,
  output reg [9:0]  wr_idx,
  input             wr_ack,

  input             clk_mem,
  input      [9:0]  wb_addr,
  output reg [31:0] wb_q,
  input      [9:0]  rb_addr,
  input      [31:0] rb_d,
  input             rb_we
);

localparam WPL = W*3/8;  // words per line

assign fb_len = WPL/4;

// line buffers, two lines each, indexed by {bank, word}. The read buffer is
// split into even and odd words so a pixel spanning two words is one read.
reg [31:0] wbuf [0:1023];
reg [31:0] rbuf0 [0:511];
reg [31:0] rbuf1 [0:511];

always @(posedge clk_mem) begin
  wb_q <= wbuf[wb_addr];
  if (rb_we && !rb_addr[0]) rbuf0[{rb_addr[9], rb_addr[8:1]}] <= rb_d;
  if (rb_we &&  rb_addr[0]) rbuf1[{rb_addr[9], rb_addr[8:1]}] <= rb_d;
end

// ---------------- field and line tracking ----------------
reg       vsD = 1'b1;
reg       lof = 1'b0;       // field of current line: 1 = long field
reg       ilace = 1'b0;
reg       chg = 1'b0;
reg [8:0] k = 9'd0;         // line index since vsync
reg       zero_next = 1'b0;
reg       per = 1'b0;       // toggles every line, selects line buffer banks

wire        vfall = vsD && !vs_n;
wire [10:0] pos   = hss ? 11'd0 : wr_ptr;
wire        mid   = pos >= 11'd454 && pos < 11'd1362;  // vsync in mid line: short field
wire [8:0]  kn    = zero_next ? 9'd0 : k + 9'd1;
wire [9:0]  rrow  = {1'b0, kn} + {9'd0, ~lof} - K0;   // row to prefetch
wire [9:0]  wrow  = {1'b0, k} - K0;                   // row of captured line

// ---------------- transfer scheduling ----------------
reg [1:0] rv = 2'b00;        // read bank holds valid data
reg [1:0] rdS = 2'b00, wrS = 2'b00;

wire rd_busy = rd_req != rdS[1];
wire wr_busy = wr_req != wrS[1];

always @(posedge clk) begin
  rdS <= {rdS[0], rd_ack};
  wrS <= {wrS[0], wr_ack};
  vsD <= vs_n;

  if (hss) begin
    per       <= ~per;
    k         <= kn;
    zero_next <= 1'b0;
    weave     <= en && ilace;
    overrun   <= rd_busy || wr_busy;

    // bank filled during the line just finished is displayed now
    if (rd_busy) rv[per] <= 1'b0;

    // prefetch row of previous field into the other bank
    rv[~per] <= 1'b0;
    if (en && ilace && rrow < H && !rd_busy) begin
      rv[~per] <= 1'b1;
      rd_req   <= ~rd_req;
      rd_addr  <= rrow[8:0] * WPL;
      rd_idx   <= {~per, 9'd0};
    end

    // write line captured during the line just finished
    if (weave && wrow < H && !wr_busy) begin
      wr_req   <= ~wr_req;
      wr_addr  <= wrow[8:0] * WPL;
      wr_idx   <= {per, 9'd0};
    end
  end

  // vsync: determine field and restart line index
  if (vfall) begin
    lof   <= !mid;
    chg   <= lof == mid;       // field type changed
    ilace <= lof == mid && chg; // ... twice in a row
    if (pos < 11'd454) k <= 9'd0;
    else zero_next <= 1'b1;
  end
end

// ---------------- capture current line ----------------
// pixel q = 8g+i, word 3g+0 complete at i=2, 3g+1 at i=5, 3g+2 at i=7
wire [9:0]  q   = wr_ptr[10:1] - X0;
wire [11:0] px  = {pix_in[14:11], pix_in[9:6], pix_in[4:1]};
wire [8:0]  g3  = {q[9:3], 1'b0} + q[9:3];
reg  [11:0] pa, pb;
reg  [7:0]  pc;
always @(posedge clk)
  if (wr_ptr[0])
    case (q[2:0])
      3'd0, 3'd3, 3'd6: pa <= px;
      3'd1, 3'd4:       pb <= px;
      3'd2: begin wbuf[{per, g3}]        <= {px[7:0], pb, pa};           pc <= {4'd0, px[11:8]}; end
      3'd5: begin wbuf[{per, g3 + 9'd1}] <= {px[3:0], pb, pa, pc[3:0]}; pc <= px[11:4]; end
      3'd7:       wbuf[{per, g3 + 9'd2}] <= {px, pa, pc};
    endcase

// ---------------- output previous field ----------------
// pixel q starts at bit 12q: word w = 3q/8, shift 4*(3q mod 8)
wire [9:0]  oq  = rd_ptr - X0;
wire [11:0] o3  = {oq, 1'b0} + oq;   // w = o3[11:3]
reg  [31:0] r0q, r1q;
reg  [2:0]  sh1;
reg         odd1, use1;
always @(posedge clk) begin
  // words w and w+1, one from each half
  r0q  <= rbuf0[{~per, o3[11:4] + {7'd0, o3[3]}}];
  r1q  <= rbuf1[{~per, o3[11:4]}];
  odd1 <= o3[3];
  sh1  <= o3[2:0];
  use1 <= first_half && rv[~per] && oq < W;
  pix_use <= use1;
end

wire [63:0] owin = odd1 ? {r0q, r1q} : {r1q, r0q};
wire [11:0] opx  = owin[{sh1, 2'b00} +: 12];
always @(posedge clk)
  pix_out <= {opx[11:8], 1'b0, opx[7:4], 1'b0, opx[3:0], 1'b0};

endmodule
