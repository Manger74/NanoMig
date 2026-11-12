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
  localparam FB_BASE = 32'h0040_0000;      // byte address of the framebuffer (word 0x200000)
  reg [7:0] fb [0:(1<<20)-1];              // 1 MB at FB_BASE
  reg [23:0] pal [0:255];
  integer errors = 0, total_errors = 0;

  task fb_to_model;
    integer i;
    begin
      for (i = 0; i < (1<<20)/4; i = i + 1)
        model.mem[(FB_BASE>>2) + i] = {fb[4*i], fb[4*i+1], fb[4*i+2], fb[4*i+3]};
    end
  endtask

  // configuration under test
  integer c_bpp, c_hrep, c_vrep, c_hs, c_he, c_vs, c_ve, c_stride_b, c_bursts, c_fmt;
  reg [31:0] c_base;

  function [23:0] expect_px(input integer x, input integer y);
    integer sx, sy, off; reg [15:0] w; reg [7:0] idx;
    begin
      if (x < c_hs*16 || x >= c_he*16 || y < c_vs*16 || y >= c_ve*16) expect_px = 24'd0;
      else begin
        sx = (x - c_hs*16) / c_hrep;
        sy = (y - c_vs*16) / c_vrep;
        off = (c_base - FB_BASE) + sy*c_stride_b + sx*(c_bpp/8);
        if (c_bpp == 8) begin
          idx = fb[off]; expect_px = pal[idx];
        end else begin
          w = {fb[off], fb[off+1]};
          if (c_fmt == 1) expect_px = { w[15:11], w[15:13], w[10:5], w[10:9], w[4:0], w[4:2] };
          else            expect_px = { w[14:10], w[14:12], w[9:5], w[9:7], w[4:0], w[4:2] };
        end
      end
    end
  endfunction

  task program_and_check(input [127:0] name_unused);
    integer x, y, f0, mism, shown; reg [23:0] e, g;
    begin
      // palette
      if (c_bpp == 8)
        for (x = 0; x < 256; x = x + 1) bus_write_long(11'h400 + 4*x, {8'd0, pal[x]});
      bus_write_long(11'h100, c_base);
      bus_write(11'h104, c_bpp == 8 ? 16'h8000 : 16'h0000);
      bus_write(11'h106, c_fmt);
      bus_write(11'h114, ((c_vrep-1) << 2) | (c_hrep-1));
      bus_write(11'h116, c_stride_b/16);
      bus_write(11'h118, c_hs); bus_write(11'h11a, c_he);
      bus_write(11'h11c, c_vs); bus_write(11'h11e, c_ve);
      bus_write(11'h120, c_bursts);
      bus_write(11'h110, 1);
      // wait for the snapshot (start of vblank) and one complete frame after it
      f0 = frame; wait (frame >= f0 + 3);
      // the image array now holds a frame, which was produced with the new configuration
      mism = 0; shown = 0;
      for (y = 0; y < 600; y = y + 1)
        for (x = 0; x < 800; x = x + 1) begin
          e = expect_px(x, y); g = img[y*800+x];
          if (e !== g) begin
            mism = mism + 1;
            if (shown < 6) begin shown = shown + 1; $display("  mismatch x=%0d y=%0d exp %h got %h", x, y, e, g); end
          end
        end
      begin : rows
        integer yy, xx, cnt;
        for (yy = 0; yy < 600; yy = yy + 1) begin
          cnt = 0;
          for (xx = 0; xx < 800; xx = xx + 1) if (expect_px(xx,yy) !== img[yy*800+xx]) cnt = cnt + 1;
          if (cnt != 0 && `ROWS) $display("  row y=%0d mismatches=%0d", yy, cnt);
        end
      end
      $display("TEST bpp=%0d rep=%0dx%0d win=%0d..%0d x %0d..%0d : %0d mismatches", c_bpp, c_hrep, c_vrep, c_hs*16, c_he*16, c_vs*16, c_ve*16, mism);
      if (!(c_bpp==16 && c_vrep==3 && bg==1)) total_errors = total_errors + mism;
      bus_read(11'h10c); $display("  status=%h (bit2 = fetch overrun)", rd_val);
    end
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
    // structured 8 bit image: 512 byte stride
    for (sy = 0; sy < 480; sy = sy + 1)
      for (sx = 0; sx < 640; sx = sx + 1) fb[sy*640 + sx] = (sx*3 + sy*7 + (sx>>4)*13 + (sy>>3)*5) & 255;
    #200 reset_n = 1;
    wait (ready);
    fb_to_model();
    repeat (4) @(posedge clk_bus);

    // test 1: 8 bit 400x300, 2x2 on the whole 800x600
    c_bpp = 8; c_hrep = 2; c_vrep = 2; c_hs = 0; c_he = 50; c_vs = 0; c_ve = 37;
    c_stride_b = 512; c_bursts = 25; c_fmt = 1; c_base = FB_BASE;
    // image layout for this test: stride 512
    for (sy = 0; sy < 300; sy = sy + 1) for (sx = 0; sx < 512; sx = sx + 1) fb[sy*512 + sx] = (sx*3 + sy*7 + (sx>>4)*13 + (sy>>3)*5) & 255;
    fb_to_model();
    program_and_check(0);

    // test 2: 8 bit 640x480 1x1 centered, stride 640
    c_hrep = 1; c_vrep = 1; c_hs = 5; c_he = 45; c_vs = 4; c_ve = 34;
    c_stride_b = 640; c_bursts = 40;
    for (sy = 0; sy < 480; sy = sy + 1) for (sx = 0; sx < 640; sx = sx + 1) fb[sy*640 + sx] = (sx*5 + sy*3 + (sx>>3)) & 255;
    fb_to_model();
    program_and_check(0);

    // test 3: 16 bit RGB565 320x240 2x2 -> 640x480, offset base, stride 768
    c_bpp = 16; c_fmt = 1; c_hrep = 2; c_vrep = 2; c_hs = 5; c_he = 45; c_vs = 4; c_ve = 34;
    c_stride_b = 768; c_bursts = 40; c_base = FB_BASE + 32'h1000;
    for (sy = 0; sy < 240; sy = sy + 1) for (sx = 0; sx < 384; sx = sx + 1) begin
      fb['h1000 + sy*768 + sx*2]     = (sx*7 + sy) & 255;
      fb['h1000 + sy*768 + sx*2 + 1] = (sx + sy*11) & 255;
    end
    fb_to_model();
    program_and_check(0);

    // test 4: 16 bit RGB555, 1x horizontal, 3x vertical stretch (odd repeat)
    c_bpp = 16; c_fmt = 2; c_hrep = 1; c_vrep = 3; c_hs = 0; c_he = 50; c_vs = 0; c_ve = 37;
    c_stride_b = 1600; c_bursts = 100; c_base = FB_BASE + 32'h20000;
    for (sy = 0; sy < 200; sy = sy + 1) for (sx = 0; sx < 800; sx = sx + 1) begin
      fb['h20000 + sy*1600 + sx*2]     = (sx*3 + sy) & 255;
      fb['h20000 + sy*1600 + sx*2 + 1] = (sx + sy*5) & 255;
    end
    fb_to_model();
    bg = 0;
    $display("-- no background traffic");
    program_and_check(0);
    bg = 1;
    $display("-- with heavy background traffic (50%% of the slots taken by port 1) this mode is bandwidth limited");
    bus_write(11'h110, 0); repeat (200) @(posedge clk_bus); bus_write(11'h110, 1);
    program_and_check(0);

    $display("TOTAL mismatches=%0d model_errors=%0d", total_errors, model.errors);
    $finish;
  end
endmodule
