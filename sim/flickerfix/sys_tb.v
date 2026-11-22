//
// sys_tb.v - Amber + flickerfix + sdram.sv + sdr_chip_model
// usage: ./sys_run.sh [FF_EN] [CHIP_PCT] [BURST] [SYNC_DLY]
//
// - PAL interlace video with a static frame, checked as in ff_tb.v
// - port 1 (chipset): random reads/writes to chip ram in CHIP_PCT % of the
//   7 MHz slots, data checked against a shadow copy
// - port 2 (cpu): back to back random reads/writes to fast ram right below
//   and above the field buffer, data checked, throughput counted
// - sdram command timing checked per bank (tRCD, tRAS, tRP, tRC, tWR),
//   bus contention checked
//
`timescale 1ns/1ps

module sys_tb;

parameter FF_EN    = 1;
parameter CHIP_PCT = 45;
parameter BURST    = 0;     // CHIP48_BURST: 1 = burst 4 mode register (020/aga)
parameter SYNC_DLY = 4;
parameter FIELDS   = 6;

localparam X0 = 88, W = 832, K0 = 16, H = 300;

// 85.125 MHz sdram clock, 28.375 MHz = /3, 7 MHz enable = /4
reg clk85 = 0;
always #5.873 clk85 = ~clk85;
// 28 MHz from both clk85 edges, aligned like the PLL outputs
reg clk28 = 0;
reg [2:0] ph = 0;
always @(posedge clk85 or negedge clk85) begin
  ph <= (ph == 5) ? 0 : ph + 1;
  if (ph == 2 || ph == 5) clk28 <= ~clk28;
end

reg [1:0] c7 = 0;
reg clk7_en = 0;
always @(posedge clk28) begin
  c7 <= c7 + 1;
  clk7_en <= (c7 == 3);
end

// ---------------- video generator (as ff_tb.v) ----------------
reg [10:0] gpos = 0;
reg [9:0]  gline = 0;
wire hs_n = !(gpos < 134);
wire [11:0] hl = gline*2 + (gpos >= 908);
wire vs_n = !((hl >= 6 && hl < 11) || (hl >= 631 && hl < 636));
always @(posedge clk28) begin
  gpos <= (gpos == 1815) ? 0 : gpos + 1;
  if (gpos == 1815) gline <= (gline == 624) ? 0 : gline + 1;
end
wire       is_s = !(gline >= 3 && gline <= 315);
wire [9:0] j    = is_s ? ((gline >= 316) ? gline - 316 : gline + 309) : gline - 3;
wire [9:0] y    = {j[8:0], 1'b0} + is_s;
wire [9:0] p    = amber.wr_ptr[10:1];
wire [11:0] pix = {y[8:0], p[2:0]};

// ---------------- DUT ----------------
wire [3:0] r, g, b;
wire ohs, ovs;
wire [6:0] ff_len;
wire ff_rd_req, ff_wr_req, ff_rd_ack, ff_wr_ack, rb_we;
wire [16:0] ff_rd_addr, ff_wr_addr;
wire [9:0] ff_rd_idx, ff_wr_idx, wb_addr, rb_addr;
wire [31:0] wb_q, rb_d;

Amber amber (
  .clk28m(clk28), .lr_filter(2'b00), .hr_filter(2'b00), .scanline(2'b00),
  .htotal(8'd226), .hires(1'b1), .dblscan(1'b1),
  .red_in(pix[11:8]), .green_in(pix[7:4]), .blue_in(pix[3:0]),
  ._hsync_in(hs_n), ._vsync_in(vs_n), ._csync_in(1'b1),
  .red_out(r), .green_out(g), .blue_out(b), ._hsync_out(ohs), ._vsync_out(ovs),
  .ff_en(FF_EN[0]), .ff_len(ff_len),
  .ff_rd_req(ff_rd_req), .ff_rd_addr(ff_rd_addr), .ff_rd_idx(ff_rd_idx), .ff_rd_ack(ff_rd_ack),
  .ff_wr_req(ff_wr_req), .ff_wr_addr(ff_wr_addr), .ff_wr_idx(ff_wr_idx), .ff_wr_ack(ff_wr_ack),
  .clk_mem(clk85), .ff_wb_addr(wb_addr), .ff_wb_q(wb_q),
  .ff_rb_addr(rb_addr), .ff_rb_d(rb_d), .ff_rb_we(rb_we)
);

wire [31:0] dq;
wire [10:0] sa;
wire [3:0]  dqm;
wire [1:0]  ba;
wire cs_n, we_n, ras_n, cas_n, cke, ready;

reg reset_n = 0;
initial #200 reset_n = 1;

reg         c1_cs = 0, c1_we = 0;
reg  [21:0] c1_addr;
reg  [1:0]  c1_ds;
reg  [15:0] c1_din;
wire [15:0] c1_dout;
reg         c2_cs = 0, c2_we = 0;
reg  [22:0] c2_addr;
reg  [1:0]  c2_ds;
reg  [15:0] c2_din;
wire [15:0] c2_dout;
wire        c2_ack;

sdram #(
  .DATA_WIDTH(32), .RAS_WIDTH(11), .CAS_WIDTH(8),
  .SYNC_DELAY(SYNC_DLY), .CHIP48_BURST(BURST)
) sdram (
  .clk(clk85), .reset_n(reset_n), .ready(ready),
  .sd_data(dq), .sd_addr(sa), .sd_dqm(dqm), .sd_ba(ba), .sd_cke(cke),
  .sd_cs(cs_n), .sd_we(we_n), .sd_ras(ras_n), .sd_cas(cas_n),
  .sync(clk7_en), .refresh(1'b0),
  .din(c1_din), .dout(c1_dout), .dout48(), .addr(c1_addr), .ds(c1_ds), .cs(c1_cs), .we(c1_we),
  .p2_din(c2_din), .p2_dout(c2_dout), .p2_dout48(), .p2_addr(c2_addr), .p2_ds(c2_ds),
  .p2_cs(c2_cs), .p2_we(c2_we), .p2_ack(c2_ack),
  .ff_len(ff_len),
  .ff_rd_req(ff_rd_req), .ff_rd_addr(ff_rd_addr), .ff_rd_idx(ff_rd_idx), .ff_rd_ack(ff_rd_ack),
  .ff_wr_req(ff_wr_req), .ff_wr_addr(ff_wr_addr), .ff_wr_idx(ff_wr_idx), .ff_wr_ack(ff_wr_ack),
  .ff_wb_addr(wb_addr), .ff_wb_q(wb_q), .ff_rb_addr(rb_addr), .ff_rb_d(rb_d), .ff_rb_we(rb_we)
);

sdr_chip_model ram (.clk(clk85), .dq(dq), .addr(sa), .dqm(dqm), .ba(ba),
  .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n));

integer errors = 0;

// p2_ack_i has no reset value in sdram.sv (0 after fpga configuration)
initial begin sdram.p2_ack_i = 1'b0; sdram.genblk3.p2_ack_d = 1'b0; end

// ---------------- shadow memory (16 bit words) ----------------
reg [15:0] shadow [0:4194303];
reg        known  [0:4194303];
integer i;
initial for (i = 0; i < 4194304; i = i + 1) known[i] = 0;

task automatic shadow_write(input [21:0] a, input [1:0] ds, input [15:0] d);
  begin
    if (!known[a]) begin shadow[a] = 16'hxxxx; end
    if (!ds[1]) shadow[a][15:8] = d[15:8];
    if (!ds[0]) shadow[a][7:0]  = d[7:0];
    known[a] = (ds == 2'b00) || known[a];
  end
endtask

task automatic shadow_check(input [21:0] a, input [15:0] d, input integer port);
  begin
    if (known[a] && d !== shadow[a]) begin
      errors = errors + 1;
      if (errors < 10) $display("%0t port%0d read %h: %h expected %h", $time, port, a, d, shadow[a]);
    end
  end
endtask

// ---------------- port 1: chipset ----------------
reg c1_chk = 0;
reg [21:0] c1_last;
integer c1_n = 0;
always @(posedge clk28) if (clk7_en && ready) begin
  if (c1_chk) shadow_check(c1_last, c1_dout, 1);
  c1_chk <= 0;
  if (($urandom % 100) < CHIP_PCT) begin
    c1_cs   <= 1;
    c1_we   = $urandom % 2;
    c1_addr = $urandom % 4096;            // small range, many re-reads
    c1_ds   = (c1_we) ? ($urandom % 3) : 2'b00;
    c1_din  = $urandom;
    if (c1_we) shadow_write(c1_addr, c1_ds, c1_din);
    else begin c1_chk <= 1; c1_last <= c1_addr; end
    c1_n = c1_n + 1;
  end else
    c1_cs <= 0;
end

// ---------------- port 2: cpu, back to back ----------------
reg c2_ackD = 0;
integer c2_n = 0;
reg [22:0] c2_a;
always @(posedge clk28) if (ready) begin
  c2_ackD <= c2_ack;
  if (c2_cs && c2_ack != c2_ackD) begin
    if (!c2_we) shadow_check(c2_addr[21:0], c2_dout, 2);
    c2_cs <= 0;
    c2_n = c2_n + 1;
  end else if (!c2_cs) begin
    // fast ram words right below $700000 and right above $780000
    c2_a  = ($urandom % 2) ? 23'h37F000 + ($urandom % 4096) : 23'h3C0000 + ($urandom % 4096);
    c2_we = $urandom % 2;
    c2_ds = c2_we ? ($urandom % 3) : 2'b00;
    c2_din = $urandom;
    c2_addr <= c2_a;
    if (c2_we) shadow_write(c2_a[21:0], c2_ds, c2_din);
    c2_cs <= 1;
  end
end

// ---------------- sdram timing checker ----------------
localparam T_RCD = 2, T_RAS = 4, T_RP = 2, T_RC = 6, T_WR = 2, T_RFC = 6;
integer cyc = 0;
integer act_t [0:3], idle_t [0:3];
reg     open [0:3];
reg [10:0] orow [0:3];
integer blen = 1;
integer k2;
initial for (k2 = 0; k2 < 4; k2 = k2 + 1) begin act_t[k2] = -100; idle_t[k2] = 0; open[k2] = 0; end

task automatic terr(input [8*24:1] msg);
  begin
    errors = errors + 1;
    if (errors < 10) $display("%0t sdram timing: %0s bank %0d", $time, msg, ba);
  end
endtask

always @(posedge clk85) begin
  cyc = cyc + 1;
  if (!cs_n) case ({ras_n, cas_n, we_n})
    3'b000: blen = 1 << sa[2:0];
    3'b011: begin  // ACTIVE
      if (open[ba]) terr("ACTIVE on open bank");
      if (cyc < idle_t[ba]) terr("tRP");
      if (cyc - act_t[ba] < T_RC) terr("tRC");
      open[ba] = 1; act_t[ba] = cyc; orow[ba] = sa;
    end
    3'b101, 3'b100: begin  // READ / WRITE
      if (!open[ba]) terr("access to closed bank");
      if (cyc - act_t[ba] < T_RCD) terr("tRCD");
      if (sa[10]) begin
        open[ba] = 0;
        idle_t[ba] = ({ras_n, cas_n, we_n} == 3'b101) ? cyc + blen : cyc + 1 + T_WR;
        if (idle_t[ba] < act_t[ba] + T_RAS) idle_t[ba] = act_t[ba] + T_RAS;
        idle_t[ba] = idle_t[ba] + T_RP;
      end
    end
    3'b001: begin  // REFRESH
      for (k2 = 0; k2 < 4; k2 = k2 + 1) begin
        if (open[k2] || cyc < idle_t[k2]) terr("REFRESH with bank busy");
        idle_t[k2] = cyc + T_RFC;
      end
    end
    3'b010: for (k2 = 0; k2 < 4; k2 = k2 + 1) open[k2] = 0;  // PRECHARGE (init)
    default: ;
  endcase
  // controller drives while the chip drives
  if (sdram.sd_dq && ram.v1) begin
    errors = errors + 1;
    if (errors < 10) $display("%0t bus contention", $time);
  end
end

// ---------------- video checker ----------------
reg ohsD = 1, ovsD = 1;
integer c = 0, row = 0, field = -1, ovr = 0, uses = 0;
integer yrow, xoff = -1, rowerr;
integer yf [0:FIELDS][0:639];
reg [11:0] opix;
integer c2_start = 0;

always @(posedge clk28) begin
  opix = {r, g, b};
  ohsD <= ohs;
  if (amber.ff.overrun && amber.ff.hss) ovr = ovr + 1;
  if (amber.ff.pix_use) uses = uses + 1;
  if (ohsD && !ohs) begin
    if (field >= 0 && row < 640) yf[field][row] = rowerr ? -2 : yrow;
    ovsD <= ovs;
    if (!ovs && ovsD) begin
      row = 0; field = field + 1;
      if (field == 2) c2_start = c2_n;
    end else row = row + 1;
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
  integer f, rr, bad;
  begin
    bad = 0;
    for (f = 3; f < FIELDS; f = f + 1)
      for (rr = 2*(K0+2); rr < 610; rr = rr + 1)
        if (yf[f][rr] < 0 || (FF_EN && (yf[f][rr+1] != ((yf[f][rr] + 1) & 511) || yf[f][rr] != yf[f-1][rr]))) begin
          bad = bad + 1;
          if (bad <= 5) $display("  bad: field %0d row %0d y=%0d next=%0d prev field=%0d", f, rr, yf[f][rr], yf[f][rr+1], yf[f-1][rr]);
        end
    $display("FF_EN=%0d CHIP_PCT=%0d BURST=%0d SYNC_DLY=%0d: video bad=%0d overruns=%0d ff_pixels=%0d",
             FF_EN, CHIP_PCT, BURST, SYNC_DLY, bad, ovr, uses);
    $display("  cpu total=%0d start=%0d", c2_n, c2_start);
    $display("  chip accesses=%0d cpu accesses/field=%0d data+timing errors=%0d",
             c1_n, (c2_n - c2_start) / (FIELDS - 2), errors);
    if (bad == 0 && errors == 0) $display("PASS"); else $display("FAIL");
    $finish;
  end
endtask

endmodule
