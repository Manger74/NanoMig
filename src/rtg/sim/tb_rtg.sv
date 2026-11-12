`timescale 1ns/1ps
// full chain test: cpu register writes -> rtg_video -> sdram scanout port -> sdram model, hdmi-like capture
module tb_rtg;
  reg clk_mem = 0, clk_pix = 0, clk_bus = 0;
  always #5.845 clk_mem = ~clk_mem;   // 85.5 MHz
  always #12.53 clk_pix = ~clk_pix;   // 39.9 MHz
  always #17.54 clk_bus = ~clk_bus;   // 28.5 MHz

  // --------------------------- sdram + model ---------------------------
  reg reset_n = 0;
  wire [31:0] sd_data; wire [10:0] sd_addr; wire [3:0] sd_dqm; wire [1:0] sd_ba;
  wire sd_cke, sd_cs, sd_we, sd_ras, sd_cas, ready;
  reg [3:0] slot = 0; reg sync = 0;
  always @(posedge clk_mem) begin slot <= (slot == 11) ? 0 : slot + 1; sync <= (slot == 11); end

  reg [15:0] din = 0; wire [15:0] dout; wire [47:0] dout48;
  reg [21:0] addr = 0; reg [1:0] ds = 2'b11; reg cs = 0, we = 0, refresh = 0;
  reg [15:0] p2_din = 0; wire [15:0] p2_dout; wire [47:0] p2_dout48;
  reg [22:0] p2_addr = 0; reg [1:0] p2_ds = 0; reg p2_cs = 0, p2_we = 0; wire p2_ack;
  wire rtg_cs; wire [18:0] rtg_addr; wire [31:0] rtg_dout; wire rtg_dv, rtg_ack;

  sdram #(.DATA_WIDTH(32), .RAS_WIDTH(11), .CAS_WIDTH(8), .SYNC_DELAY(4), .CHIP48_BURST(1)) dut (
    .clk(clk_mem), .reset_n(reset_n), .ready(ready),
    .sd_data(sd_data), .sd_addr(sd_addr), .sd_dqm(sd_dqm), .sd_ba(sd_ba),
    .sd_cke(sd_cke), .sd_cs(sd_cs), .sd_we(sd_we), .sd_ras(sd_ras), .sd_cas(sd_cas),
    .sync(sync), .refresh(refresh),
    .din(din), .dout(dout), .dout48(dout48), .addr(addr), .ds(ds), .cs(cs), .we(we),
    .p2_din(p2_din), .p2_dout(p2_dout), .p2_dout48(p2_dout48), .p2_addr(p2_addr),
    .p2_ds(p2_ds), .p2_cs(p2_cs), .p2_we(p2_we), .p2_ack(p2_ack),
    .rtg_cs(rtg_cs), .rtg_addr(rtg_addr), .rtg_dout(rtg_dout), .rtg_dv(rtg_dv), .rtg_ack(rtg_ack));
  wire [31:0] m_out; wire m_drv;
  assign sd_data = m_drv ? m_out : 32'bz;
  sdram_model model (.clk(clk_mem), .cke(sd_cke), .cs_n(sd_cs), .ras_n(sd_ras), .cas_n(sd_cas), .we_n(sd_we),
    .addr(sd_addr), .ba(sd_ba), .dqm(sd_dqm), .dq_in(sd_data), .dq_oe(1'b1), .dq_out(m_out), .dq_drv(m_drv));

  // ------------------------------ rtg_video ------------------------------
  reg reg_sel = 0, reg_rd = 0, reg_wr = 0; reg [10:1] reg_addr = 0; reg [15:0] reg_din = 0;
  wire [15:0] reg_dout; wire rtg_enable;
  reg [10:0] cx = 0; reg [9:0] cy = 0;
  wire [23:0] rgb;
  rtg_video rtg (.clk_bus(clk_bus), .reset_bus(1'b0), .reg_sel(reg_sel), .reg_rd(reg_rd), .reg_wr(reg_wr),
    .reg_addr(reg_addr), .reg_din(reg_din), .reg_dout(reg_dout), .rtg_enable(rtg_enable),
    .clk_mem(clk_mem), .mem_req(rtg_cs), .mem_addr(rtg_addr), .mem_data(rtg_dout), .mem_dv(rtg_dv), .mem_ack(rtg_ack),
    .clk_pix(clk_pix), .cx(cx), .cy(cy), .rgb(rgb));

  // hdmi like counters and capture
  integer frame = 0;
  reg [23:0] img [0:600*800-1];
  always @(posedge clk_pix) begin
    if (cx < 800 && cy < 600) img[cy*800+cx] = rgb;
    if (cx == 1055) begin
      cx <= 0;
      if (cy == 627) begin cy <= 0; frame <= frame + 1; end else cy <= cy + 1;
    end else cx <= cx + 1;
  end

  // ------------------------- cpu bus access tasks ------------------------
  task bus_write(input [10:0] a, input [15:0] d);   // a = byte offset inside $B80000
    begin
      @(posedge clk_bus); #1; reg_addr = a[10:1]; reg_din = d; reg_sel = 1; reg_wr = 1;
      repeat (4) @(posedge clk_bus);
      #1; reg_wr = 0; reg_sel = 0;
      repeat (2) @(posedge clk_bus);
    end
  endtask
  task bus_write_long(input [10:0] a, input [31:0] d);
    begin bus_write(a, d[31:16]); bus_write(a + 2, d[15:0]); end
  endtask
  reg [15:0] rd_val;
  task bus_read(input [10:0] a);
    begin
      @(posedge clk_bus); #1; reg_addr = a[10:1]; reg_sel = 1; reg_rd = 1;
      repeat (3) @(posedge clk_bus); #1; rd_val = reg_dout;
      reg_rd = 0; reg_sel = 0; repeat (2) @(posedge clk_bus);
    end
  endtask

  // ----------------------- reference framebuffer / model -----------------------
  localparam FB_BASE = 32'h0040_0000;      // byte address of the framebuffer region (word 0x200000)
  reg [7:0] fb [0:(1<<20)-1];              // 1 MB at FB_BASE
  reg [23:0] pal [0:255];
  integer total_errors = 0;
  reg [31:0] c_base;                       // framebuffer byte address under test

  task fb_to_model;
    integer i;
    begin
      for (i = 0; i < (1<<20)/4; i = i + 1)
        model.mem[(FB_BASE>>2) + i] = {fb[4*i], fb[4*i+1], fb[4*i+2], fb[4*i+3]};
    end
  endtask

  // 400x300 source, shown doubled
  function [23:0] expect_px(input integer x, input integer y);
    begin
      if (x >= 800 || y >= 600) expect_px = 24'd0;
      else expect_px = pal[fb[(c_base - FB_BASE) + (y/2)*400 + (x/2)]];
    end
  endfunction

  task check_frame(input [255:0] name);
    integer x, y, mism, shown, f0; reg [23:0] e, g;
    begin
      // one complete frame after the last change, plus margin
      f0 = frame; wait (frame >= f0 + 3);
      mism = 0; shown = 0;
      for (y = 0; y < 600; y = y + 1)
        for (x = 0; x < 800; x = x + 1) begin
          e = expect_px(x, y); g = img[y*800+x];
          if (e !== g) begin
            mism = mism + 1;
            if (shown < 6) begin shown = shown + 1; $display("  mismatch x=%0d y=%0d exp %h got %h", x, y, e, g); end
          end
        end
      $display("TEST %0s base=%h: %0d mismatches", name, c_base, mism);
      total_errors = total_errors + mism;
      bus_read(11'h10c); $display("  status=%h (bit2 = fetch overrun)", rd_val);
      if (rd_val[2]) total_errors = total_errors + 1;
    end
  endtask

  task program_palette;
    integer x;
    begin for (x = 0; x < 256; x = x + 1) bus_write_long(11'h400 + 4*x, {8'd0, pal[x]}); end
  endtask

  // --------------------------- background traffic ---------------------------
  // random cpu/chipset like load on port 1 and 2 (outside the framebuffer region)
  integer bg = 1;
  reg p2_ack_d = 0; reg p2_busy = 0;
  always @(posedge clk_mem) begin
    p2_ack_d <= p2_ack;
    if (slot == 8) begin cs <= 0; we <= 0; refresh <= 0; end
    if (ready && bg && slot == 10 && $urandom_range(0,99) < 50) begin
      cs <= 1; we <= $urandom_range(0,2) == 0; addr <= $urandom_range(0, 'h0FFFFF); ds <= $urandom_range(0,3); din <= $urandom;
    end
    if (p2_busy) begin
      if (p2_ack != p2_ack_d) begin p2_busy <= 0; p2_cs <= 0; end
    end else if (ready && bg && $urandom_range(0,99) < 50) begin
      p2_cs <= 1; p2_we <= $urandom_range(0,3) == 0; p2_addr <= 'h100000 + $urandom_range(0,'h0FFFFF) & ~3; p2_ds <= 0; p2_din <= $urandom; p2_busy <= 1;
    end
  end

  integer i, sx, sy;
  initial begin
    for (i = 0; i < 256; i = i + 1) pal[i] = { i[7:0] ^ 8'h5a, (i[7:0] * 3), 255 - i[7:0] };
    for (i = 0; i < (1<<20); i = i + 1) fb[i] = $urandom;
    #200 reset_n = 1;
    wait (ready);
    repeat (4) @(posedge clk_bus);

    // test 1: structured image at the start of the region
    c_base = FB_BASE;
    for (sy = 0; sy < 300; sy = sy + 1) for (sx = 0; sx < 400; sx = sx + 1) fb[sy*400 + sx] = (sx*3 + sy*7 + (sx>>4)*13 + (sy>>3)*5) & 255;
    fb_to_model();
    program_palette();
    bus_write_long(11'h100, c_base);
    bus_write(11'h110, 1);
    check_frame("400x300 base 0, bg traffic");

    // test 2: other base address (16 byte aligned, not 4k aligned), other content
    bus_write(11'h110, 0); repeat (200) @(posedge clk_bus);
    c_base = FB_BASE + 32'h12340;
    for (sy = 0; sy < 300; sy = sy + 1) for (sx = 0; sx < 400; sx = sx + 1) fb['h12340 + sy*400 + sx] = (sx*5 + sy*3 + (sx>>3)) & 255;
    fb_to_model();
    bus_write_long(11'h100, c_base);
    bus_write(11'h110, 1);
    check_frame("400x300 base 12340, bg traffic");

    // test 3: palette change while shown, no background traffic
    bg = 0;
    for (i = 0; i < 256; i = i + 1) pal[i] = { 8'd255 - i[7:0], i[7:0], i[7:0] ^ 8'hc3 };
    program_palette();
    check_frame("new palette, no bg");
    bg = 1;

    // test 4: register read back
    bus_read(11'h10e); $display("id=%h", rd_val); if (rd_val !== 16'h8321) total_errors = total_errors + 1;
    bus_read(11'h110); $display("enable=%h", rd_val);

    $display("TOTAL mismatches=%0d model_errors=%0d", total_errors, model.errors);
    $finish;
  end
endmodule
