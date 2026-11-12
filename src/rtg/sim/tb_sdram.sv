`timescale 1ns/1ps
// Random traffic test of src/misc/sdram.sv: chipset port, cpu cache port and rtg port
// run with run_sdram.sh
module tb_sdram;
  reg clk = 0;
  always #5.85 clk = ~clk;   // ~85.5 MHz
  reg reset_n = 0;

  wire [31:0] sd_data;
  wire [10:0] sd_addr; wire [3:0] sd_dqm; wire [1:0] sd_ba;
  wire sd_cke, sd_cs, sd_we, sd_ras, sd_cas;
  wire ready;

  // 12 clk slots
  reg [3:0] slot = 0;
  reg sync = 0;
  always @(posedge clk) begin
    slot <= (slot == 11) ? 0 : slot + 1;
    sync <= (slot == 11);
  end

  // port 1
  reg [15:0] din = 0; wire [15:0] dout; wire [47:0] dout48;
  reg [21:0] addr = 0; reg [1:0] ds = 2'b11; reg cs = 0, we = 0, refresh = 0;
  // port 2
  reg [15:0] p2_din = 0; wire [15:0] p2_dout; wire [47:0] p2_dout48;
  reg [22:0] p2_addr = 0; reg [1:0] p2_ds = 0; reg p2_cs = 0, p2_we = 0; wire p2_ack;
`ifdef RTG
  reg rtg_cs = 0; reg [18:0] rtg_addr = 0; wire [31:0] rtg_dout; wire rtg_dv, rtg_ack;
`endif

  sdram #(.DATA_WIDTH(32), .RAS_WIDTH(11), .CAS_WIDTH(8), .SYNC_DELAY(4), .CHIP48_BURST(1)) dut (
    .clk(clk), .reset_n(reset_n), .ready(ready),
    .sd_data(sd_data), .sd_addr(sd_addr), .sd_dqm(sd_dqm), .sd_ba(sd_ba),
    .sd_cke(sd_cke), .sd_cs(sd_cs), .sd_we(sd_we), .sd_ras(sd_ras), .sd_cas(sd_cas),
    .sync(sync), .refresh(refresh),
    .din(din), .dout(dout), .dout48(dout48), .addr(addr), .ds(ds), .cs(cs), .we(we),
    .p2_din(p2_din), .p2_dout(p2_dout), .p2_dout48(p2_dout48), .p2_addr(p2_addr),
    .p2_ds(p2_ds), .p2_cs(p2_cs), .p2_we(p2_we), .p2_ack(p2_ack)
`ifdef RTG
    , .rtg_cs(rtg_cs), .rtg_addr(rtg_addr), .rtg_dout(rtg_dout), .rtg_dv(rtg_dv), .rtg_ack(rtg_ack)
`endif
  );

  wire [31:0] m_out; wire m_drv;
  assign sd_data = m_drv ? m_out : 32'bz;
  sdram_model model (.clk(clk), .cke(sd_cke), .cs_n(sd_cs), .ras_n(sd_ras), .cas_n(sd_cas), .we_n(sd_we),
    .addr(sd_addr), .ba(sd_ba), .dqm(sd_dqm), .dq_in(sd_data), .dq_oe(1'b1), .dq_out(m_out), .dq_drv(m_drv));

  // reference memory (16 bit words)
  reg [15:0] ref_mem [0:(1<<22)-1];
  integer i, errors = 0;
  initial begin
    for (i = 0; i < (1<<22); i = i + 1) begin
      ref_mem[i] = $urandom;
    end
    for (i = 0; i < (1<<21); i = i + 1)
      model.mem[i] = {ref_mem[2*i], ref_mem[2*i+1]};
  end

  // ---------------- port 1 client: one access per random slot ----------------
  integer p1_reads = 0, p1_writes = 0, p1_busy = 0;
  // read requests are queued; data of request n is complete at slot 0 of cycle n+2
  reg        q_v [0:1]; reg [21:0] q_a [0:1]; reg q_c [0:1];
  initial begin q_v[0]=0; q_v[1]=0; end
  reg        p1_pend_rd = 0;
  reg [21:0] p1_pend_addr;
  reg        p1_chk48;
  integer seed = 1;
  integer cyc = 0;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (slot == 2 && ready && q_v[1]) begin
      // q[1] is the oldest request, q[0] the newer one
      if (dout !== ref_mem[q_a[1]]) begin errors++; $display("P1 rd %h: got %h exp %h cyc=%0d", q_a[1], dout, ref_mem[q_a[1]], cyc); end
      if (q_c[1]) begin
        if ({dout, dout48} !== {ref_mem[q_a[1]], ref_mem[q_a[1]+1], ref_mem[q_a[1]+2], ref_mem[q_a[1]+3]}) begin
          errors++; $display("P1 rd64 %h: got %h_%h exp %h_%h_%h_%h", q_a[1], dout, dout48, ref_mem[q_a[1]], ref_mem[q_a[1]+1], ref_mem[q_a[1]+2], ref_mem[q_a[1]+3]);
        end
      end
      q_v[1] <= 0;
    end
    // request starts at slot==10 (one clock before the sync)
    if (slot == 8) begin
      cs <= 0; we <= 0; refresh <= 0;
    end
    if (slot == 10) begin q_v[1] <= q_v[0]; q_a[1] <= q_a[0]; q_c[1] <= q_c[0]; q_v[0] <= 0; end
    if (ready && slot == 10 && $urandom_range(0,99) < `P1_RATE) begin
      reg [21:0] a; reg w;
      a = $urandom_range(0, 'h0FFFFF);
      w = $urandom_range(0,2) == 0;
      cs <= 1; we <= w; addr <= a; refresh <= 0;
      if (w) begin
        reg [1:0] d; reg [15:0] v;
        d = $urandom_range(0,3); v = $urandom;
        ds <= d; din <= v;
        if (!d[1]) ref_mem[a][15:8] = v[15:8];
        if (!d[0]) ref_mem[a][7:0]  = v[7:0];
        p1_writes++;
      end else begin
        ds <= 2'b00;
        if ($urandom_range(0,1)) a[2:1] = 0; // aligned for 64 bit check
        addr <= a;
        q_v[0] <= 1; q_a[0] <= a; q_c[0] <= (a[2:1] == 0);
        p1_reads++;
      end
    end else if (ready && slot == 10 && $urandom_range(0,99) < 5) begin
      cs <= 1; refresh <= 1; we <= 0;
    end
  end

  // ---------------- port 2 client: like the cpu cache ----------------
  integer p2_reads = 0, p2_writes = 0;
  reg p2_ack_d = 0; reg p2_busy = 0; reg [22:0] p2_a; reg p2_w;
  integer p2_lat = 0, p2_maxlat = 0;
  always @(posedge clk) begin
    p2_ack_d <= p2_ack;
    if (p2_busy) begin
      p2_lat <= p2_lat + 1;
      if (p2_ack != p2_ack_d) begin
        p2_busy <= 0; p2_cs <= 0;
        if (p2_lat > p2_maxlat) p2_maxlat <= p2_lat;
        if (!p2_w) begin
          if ({p2_dout, p2_dout48} !== {ref_mem[p2_a[21:0]], ref_mem[p2_a[21:0]+1], ref_mem[p2_a[21:0]+2], ref_mem[p2_a[21:0]+3]}) begin
            errors++; $display("P2 rd %h: got %h_%h", p2_a, p2_dout, p2_dout48);
          end
        end
      end
    end else if (ready && $urandom_range(0,99) < `P2_RATE) begin
      reg [22:0] a; reg w; reg [15:0] v; reg [1:0] d;
      w = $urandom_range(0,3) == 0;
      a = 'h100000 + $urandom_range(0,'h0FFFFF);
      if (!w) a[1:0] = 0;      // line fills are aligned
      p2_a <= a; p2_w <= w; p2_cs <= 1; p2_we <= w; p2_addr <= a; p2_busy <= 1; p2_lat <= 0;
      v = $urandom; d = $urandom_range(0,3);
      p2_din <= v; p2_ds <= d;
      if (w) begin
        if (!d[1]) ref_mem[a[21:0]][15:8] = v[15:8];
        if (!d[0]) ref_mem[a[21:0]][7:0]  = v[7:0];
        p2_writes++;
      end else p2_reads++;
    end
  end

`ifdef RTG
  // ---------------- rtg client: keeps requesting consecutive 16 byte units ----------------
  integer rtg_bursts = 0, rtg_lat = 0, rtg_maxlat = 0, rtg_beat = 0;
  reg rtg_busy = 0; reg [18:0] rtg_next = 19'h40000;   // word 0x200000 = byte 0x400000 -> unit 0x40000
  reg [18:0] rtg_cur; reg [127:0] rtg_acc;
  always @(posedge clk) begin
    if (rtg_dv) begin
      rtg_acc[127 - 32*rtg_beat -: 32] = rtg_dout;
      rtg_beat <= rtg_ack ? 0 : rtg_beat + 1;
      if (rtg_ack && rtg_beat != 3) begin errors++; $display("RTG: ack on beat %0d", rtg_beat); end
    end else if (rtg_ack) begin errors++; $display("RTG: ack without dv"); end
    if (rtg_busy) begin
      rtg_lat <= rtg_lat + 1;
      if (rtg_ack) begin
        reg [127:0] e; integer k;
        for (k = 0; k < 8; k = k + 1) e[127 - 16*k -: 16] = ref_mem[{rtg_cur, 3'b000} + k];
        if (rtg_acc !== e) begin errors++; $display("RTG %h: got %h exp %h", rtg_cur, rtg_acc, e); end
        rtg_bursts <= rtg_bursts + 1;
        if (rtg_lat > rtg_maxlat) rtg_maxlat <= rtg_lat;
        rtg_busy <= 0; rtg_cs <= 0;
      end
    end else if (ready && $urandom_range(0,99) < `RTG_RATE) begin
      rtg_cur <= rtg_next; rtg_addr <= rtg_next; rtg_cs <= 1; rtg_busy <= 1; rtg_lat <= 0;
      rtg_next <= (rtg_next == 19'h7ffff) ? 19'h40000 : rtg_next + 1;
    end
  end
`endif

`ifdef DBG
  always @(posedge clk) if (ready && cyc < `DBG) begin
    if (model.rd_pend || m_drv || sd_cas==0 || sd_ras==0)
      $display("%0d st=%0d cmd=%b%b%b ba=%0d a=%h rdp=%b drv=%b mout=%h sd=%h dout=%h cs=%b", cyc, dut.state, sd_ras, sd_cas, sd_we, sd_ba, sd_addr, model.rd_pend, m_drv, m_out, sd_data, dout, cs);
  end
`endif
  initial begin
    #100 reset_n = 1;
    wait (ready);
    repeat (`RUN_SLOTS * 12) @(posedge clk);
    $display("RESULT errors=%0d model_errors=%0d p1 r/w=%0d/%0d p2 r/w=%0d/%0d p2_maxlat=%0d clk refresh=%0d",
      errors, model.errors, p1_reads, p1_writes, p2_reads, p2_writes, p2_maxlat, model.refreshes);
`ifdef RTG
    $display("RTG bursts=%0d maxlat=%0d clk (slots=%0d => %0d bursts/line-equivalent)", rtg_bursts, rtg_maxlat, `RUN_SLOTS, rtg_bursts);
`endif
    $finish;
  end
endmodule
