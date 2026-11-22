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
// Memory interface: one read and one write job per line. A job is started by
// toggling *_req with *_addr/*_idx stable. The memory side then moves fb_len
// bursts of 4 words, burst i at word address addr+4i and line buffer index
// idx+4i, through the wb_*/rb_* ports (clk_mem domain) and toggles *_ack when
// the whole job is done. A job not done at the next line start is an overrun:
// that line falls back to plain line doubling.
//

module flickerfix #(
  parameter X0 = 88,   // first stored hires pixel (even)
  parameter W  = 808,  // stored pixels per line (multiple of 8)
  parameter K0 = 16,   // first stored line after vsync
  parameter H  = 300   // stored lines per field, H*W/2 <= 128k words
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

  output     [6:0]  fb_len,     // bursts per job
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

localparam WPL = W/2;   // words per line
localparam NB  = W/8;   // bursts per line

localparam [8:0] XP = X0/2;

assign fb_len = NB;

// line buffers, two lines each, indexed by {bank, pixel pair}
reg [31:0] wbuf [0:1023];
reg [31:0] rbuf [0:1023];

always @(posedge clk_mem) begin
  wb_q <= wbuf[wb_addr];
  if (rb_we) rbuf[rb_addr] <= rb_d;
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
      rd_idx   <= {~per, XP};
    end

    // write line captured during the line just finished
    if (weave && wrow < H && !wr_busy) begin
      wr_req   <= ~wr_req;
      wr_addr  <= wrow[8:0] * WPL;
      wr_idx   <= {per, XP};
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
reg [14:0] evn;
always @(posedge clk)
  if (wr_ptr[0]) begin
    if (!wr_ptr[1]) evn <= pix_in;
    else wbuf[{per, wr_ptr[10:2]}] <= {1'b0, evn, 1'b0, pix_in};
  end

// ---------------- output previous field ----------------
reg [31:0] rbq;
reg        sel1, use1;
always @(posedge clk) begin
  rbq     <= rbuf[{~per, rd_ptr[9:1]}];
  sel1    <= rd_ptr[0];
  use1    <= first_half && rv[~per] && rd_ptr >= X0 && rd_ptr < X0 + W;
  pix_out <= sel1 ? rbq[14:0] : rbq[30:16];
  pix_use <= use1;
end

endmodule
