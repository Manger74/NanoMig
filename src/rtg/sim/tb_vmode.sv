// Checks the sync generator of hdmi.sv for video mode 2'b10 (build-time raster).
// DVI output (no data islands): Verilator cannot elaborate the audio clock packet.
// Measures one frame: line length, active area, hsync position/width/polarity,
// vsync start line/width/polarity. Run with run_vmode.sh.
module tb_vmode;
  logic clk = 0, clk5 = 0;
  always #5 clk = ~clk;
  logic [15:0] aw [1:0];
  assign aw[0] = 16'd0; assign aw[1] = 16'd0;
  logic [2:0] tmds; logic tmds_clock;

  hdmi #(.DVI_OUTPUT(1)) dut (
    .clk_pixel_x5(clk5), .clk_pixel(clk), .clk_audio(1'b0),
    .video_mode(2'b10), .pal_mode(1'b1), .screen(2'd0), .short_frame(1'b0), .interlace(1'b0),
    .reset(1'b0), .rgb(24'h0), .audio_sample_word(aw), .tmds(tmds), .tmds_clock(tmds_clock));

  // inactive level of the syncs is the level at cx=0, cy=0
  int x, y, hs_first, hs_len, vs_first, vs_lines, act_w, act_h;
  logic hs_idle, vs_idle;
  initial begin
    // wait for the start of a frame
    @(posedge clk); while (!(dut.cx == 0 && dut.cy == 0)) @(posedge clk);
    hs_idle = dut.hsync; vs_idle = dut.vsync;
    hs_first = -1; hs_len = 0; vs_first = -1; vs_lines = 0; act_w = 0; act_h = 0;
    for (y = 0; ; y++) begin
      for (x = 0; ; x++) begin
        #1;
        if (y == 0 && dut.hsync != hs_idle) begin if (hs_first < 0) hs_first = x; hs_len++; end
        if (x == 0 && y > 0 && dut.vsync != vs_idle) begin if (vs_first < 0) vs_first = y; vs_lines++; end
        if (y == 0 && dut.video_data_period) act_w++;
        if (x == 0 && dut.video_data_period) act_h++;
        @(posedge clk);
        if (dut.cx == 0) break;
      end
      if (y == 0) $display("line length %0d", x + 1);
      if (dut.cy == 0) break;
    end
    $display("frame lines %0d", y + 1);
    $display("active %0d x %0d (video_data_period is one clock late, rows counted at x=0)", act_w, act_h);
    // the loop samples one clock after cx changed, so x = cx - 1
    $display("hsync start cx=%0d width %0d %s", hs_first + 1, hs_len, hs_idle ? "negative" : "positive");
    $display("vsync start line %0d width %0d %s", vs_first, vs_lines, vs_idle ? "negative" : "positive");
    $finish;
  end
endmodule

// stub of the Gowin serializer primitive (the tmds output is not checked here)
module OSER10 (output Q, input D0, D1, D2, D3, D4, D5, D6, D7, D8, D9, PCLK, FCLK, RESET);
  assign Q = D0;
endmodule
