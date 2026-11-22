//
// ff_tb.v - testbench for Amber + flickerfix
//
// Generates PAL interlace (313/312 lines, short field vsync in mid line)
// showing a static frame. Frame row y = 2*line + (short field), pixel color
// encodes y and the pixel position. The output rows are counted like
// video_analyzer does and checked:
//   weave: rows are y, y+1, y+2 ... and identical in both fields
//   bob:   every y appears twice, fields differ (= flicker)
// The field buffer memory grants one burst per 7 MHz slot with probability
// SLOT_PCT to emulate a busy sdram.
//
`timescale 1ns/1ps

module ff_tb;

parameter FF_EN    = 1;
parameter SLOT_PCT = 60;
parameter FIELDS   = 8;
parameter LACE     = 1;   // 0: non interlaced, 312 lines per field

localparam X0 = 88, W = 832, K0 = 16, H = 300;

reg clk = 0, clk_mem = 0;
always #17.62 clk = ~clk;       // 28.375 MHz
always #5.87  clk_mem = ~clk_mem; // 85.1 MHz

// ---------------- video generator ----------------
// lines 0..624 of a frame pair: long frame 0..312, short frame 313..624
// long field vsync at line 3 start, short field vsync at line 315 mid
reg [10:0] gpos = 0;
reg [9:0]  gline = 0;
wire hs_n = !(gpos < 134);
// vsync low for 2.5 lines
wire [11:0] hl = gline*2 + (gpos >= 908);  // half line counter
localparam VS2 = LACE ? 631 : 630;    // short field vsync in mid line
wire vs_n = !((hl >= 6 && hl < 11) || (hl >= VS2 && hl < VS2 + 5));

always @(posedge clk) begin
  gpos <= (gpos == 1815) ? 0 : gpos + 1;
  if (gpos == 1815) gline <= (gline == (LACE ? 624 : 623)) ? 0 : gline + 1;
end

wire       is_s = !(gline >= 3 && gline <= 315);
wire [9:0] j    = is_s ? ((gline >= 316) ? gline - 316 : gline + 309) : gline - 3;
wire [9:0] y    = {j[8:0], 1'b0} + is_s;

wire [9:0]  p   = amber.wr_ptr[10:1];
wire [11:0] pix = {y[8:0], p[2:0]};

// ---------------- DUT ----------------
wire [3:0] r, g, b;
wire ohs, ovs;
wire [6:0] ff_len;
wire ff_rd_req, ff_wr_req;
wire [16:0] ff_rd_addr, ff_wr_addr;
wire [9:0] ff_rd_idx, ff_wr_idx;
reg ff_rd_ack = 0, ff_wr_ack = 0;
reg [9:0] wb_addr, rb_addr;
wire [31:0] wb_q;
reg [31:0] rb_d;
reg rb_we = 0;

Amber amber (
  .clk28m(clk), .lr_filter(2'b00), .hr_filter(2'b00), .scanline(2'b00),
  .htotal(8'd226), .hires(1'b1), .dblscan(1'b1),
  .red_in(pix[11:8]), .green_in(pix[7:4]), .blue_in(pix[3:0]),
  ._hsync_in(hs_n), ._vsync_in(vs_n), ._csync_in(1'b1),
  .red_out(r), .green_out(g), .blue_out(b), ._hsync_out(ohs), ._vsync_out(ovs),
  .ff_en(FF_EN[0]), .ff_len(ff_len),
  .ff_rd_req(ff_rd_req), .ff_rd_addr(ff_rd_addr), .ff_rd_idx(ff_rd_idx), .ff_rd_ack(ff_rd_ack),
  .ff_wr_req(ff_wr_req), .ff_wr_addr(ff_wr_addr), .ff_wr_idx(ff_wr_idx), .ff_wr_ack(ff_wr_ack),
  .clk_mem(clk_mem), .ff_wb_addr(wb_addr), .ff_wb_q(wb_q),
  .ff_rb_addr(rb_addr), .ff_rb_d(rb_d), .ff_rb_we(rb_we)
);

// ---------------- field buffer memory model ----------------
reg [31:0] mem [0:131071];
integer i;
initial for (i = 0; i < 131072; i = i + 1) mem[i] = 0;

reg [1:0] rqS = 0, wqS = 0;
reg [3:0] slot = 0;
reg [3:0] st = 0;
reg       we;               // current burst is a write
reg [6:0] rcnt = 0, wcnt = 0;
wire [16:0] maddr = we ? ff_wr_addr + {wcnt, 2'b00} : ff_rd_addr + {rcnt, 2'b00};
wire [9:0]  midx  = we ? ff_wr_idx  + {wcnt, 2'b00} : ff_rd_idx  + {rcnt, 2'b00};
wire rd_pend = rqS[1] != ff_rd_ack;
wire wr_pend = wqS[1] != ff_wr_ack;

always @(posedge clk_mem) begin
  rqS <= {rqS[0], ff_rd_req};
  wqS <= {wqS[0], ff_wr_req};
  slot <= (slot == 11) ? 0 : slot + 1;
  rb_we <= 0;
  if (st == 0) begin
    // one burst per 7 MHz slot, if the slot is free
    if ((rd_pend || wr_pend) && slot == 0 && ($urandom % 100) < SLOT_PCT) begin
      we <= !rd_pend;
      st <= 1;
    end
  end else begin
    st <= st + 1;
    if (we) begin               // wbuf -> mem, one cycle read latency
      if (st <= 4) wb_addr <= midx + st - 1;
      if (st >= 3 && st <= 6) mem[maddr + st - 3] <= wb_q;
    end else if (st <= 4) begin // mem -> rbuf
      rb_addr <= midx + st - 1;
      rb_d    <= mem[maddr + st - 1];
      rb_we   <= 1;
    end
    if (st == 7) begin
      st <= 0;
      if (we) begin
        if (wcnt == ff_len - 1) begin wcnt <= 0; ff_wr_ack <= ~ff_wr_ack; end
        else wcnt <= wcnt + 1;
      end else begin
        if (rcnt == ff_len - 1) begin rcnt <= 0; ff_rd_ack <= ~ff_rd_ack; end
        else rcnt <= rcnt + 1;
      end
    end
  end
end

// ---------------- output checker ----------------
reg ohsD = 1, ovsD = 1;
integer uses = 0;
integer c = 0, row = 0, field = -1, errors = 0, ovr = 0;
integer yrow, xoff = -1, rowerr;
integer yf [0:FIELDS][0:639];
reg [11:0] opix;

always @(posedge clk) begin
  opix = {r, g, b};
  ohsD <= ohs;
  if (amber.ff.overrun && amber.ff.hss) ovr = ovr + 1;
  if (amber.ff.pix_use) uses = uses + 1;
  if (ohsD && !ohs) begin
    if (field >= 0 && row < 640) yf[field][row] = rowerr ? -2 : yrow;
    ovsD <= ovs;
    if (!ovs && ovsD) begin row = 0; field = field + 1; end
    else row = row + 1;
    c = 0; yrow = -1; rowerr = 0;
  end else begin
    c = c + 1;
    if (field >= 1 && c >= X0 + 16 && c < X0 + W - 16) begin
      if (xoff < 0) xoff = (opix[2:0] - c) & 7;
      if (((opix[2:0] - c) & 7) != xoff) rowerr = 1;
      if (yrow < 0) yrow = opix[11:3];
      else if (yrow != opix[11:3]) rowerr = 1;
    end
  end
  if (field == FIELDS) finish_check;
end

task finish_check;
  integer f, rr, r0, r1, bad;
  begin
    // rows of stored lines K0+2 .. end of field
    r0 = 2*(K0+2); r1 = 610;  // field has 625 rows
    bad = 0;
    for (f = 4; f < FIELDS; f = f + 1)
      for (rr = r0; rr < r1; rr = rr + 1) begin
        if (yf[f][rr] < 0 || (FF_EN && LACE && (yf[f][rr+1] != ((yf[f][rr] + 1) & 511) || yf[f][rr] != yf[f-1][rr]))) begin
          bad = bad + 1;
          if (bad <= 8) $display("  bad: field %0d row %0d y=%0d next=%0d prev field=%0d", f, rr, yf[f][rr], yf[f][rr+1], yf[f-1][rr]);
        end
      end
    if (!LACE && uses != 0) bad = bad + 1;  // weave must stay off
    $display("FF_EN=%0d LACE=%0d SLOT_PCT=%0d xoff=%0d overruns=%0d ff_pixels=%0d bad=%0d", FF_EN, LACE, SLOT_PCT, xoff, ovr, uses, bad);
    for (rr = r0; rr < r0 + 6; rr = rr + 1)
      $display("  row %0d: field4 y=%0d field5 y=%0d", rr, yf[4][rr], yf[5][rr]);
    if (bad == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endtask

endmodule
