// video_analyzer resync after an extended video mode (top_020.sv, HDMI_VIDEO_MODES).
// The resync logic below is a copy of the one in top_020.sv. Without it the analyzer
// sends no vreset after the return to the native mode (FIX=0 shows the fault).
`timescale 1ns/1ps
module tb;
parameter FIX = 1;
reg clk = 0; always #17.6 clk = ~clk;

// small video timing: 200 clocks per line, 100 lines per frame
localparam HT = 200, VT = 100;
reg [7:0] hc = 0; reg [6:0] vc = 0;
always @(posedge clk) begin
  hc <= hc == HT-1 ? 8'd0 : hc + 8'd1;
  if(hc == HT-1) vc <= vc == VT-1 ? 7'd0 : vc + 7'd1;
end
wire hs_n = !(hc < 16), vs_n = !(vc < 3);

reg [1:0] video_mode = 2'b01; reg video_locked = 1'b1;
wire [1:0] osd_video_screen = 2'd0;

reg [1:0] vlock_s = 2'b00;
reg [7:0] resync_cnt = 8'hff;
always @(posedge clk) begin
  vlock_s <= { vlock_s[0], video_locked };
  if (video_mode != 2'b01 || !vlock_s[1]) resync_cnt <= 8'hff;
  else if (resync_cnt != 8'h00)            resync_cnt <= resync_cnt - 8'd1;
end
wire [1:0] va_screen = (FIX && resync_cnt != 8'h00) ? ~osd_video_screen : osd_video_screen;

wire vreset, pal, short_frame, interlace;
video_analyzer va (.clk(clk), .hs(hs_n), .vs(vs_n), .screen(va_screen),
  .pal(pal), .short_frame(short_frame), .interlace(interlace), .vreset(vreset));

integer n = 0, n_bad = 0; time t_lock = 0, t_vr = 0;
always @(posedge clk) if(vreset) begin
  n = n + 1; t_vr = $time;
  // must fire at the same place of the Amiga frame: one clock after hcnt 162 of line 46
  if(va.hcnt != 163 || va.vcnt != 46) n_bad = n_bad + 1;
end

integer errors = 0;
task check(input c, input [8*72-1:0] msg); begin
  if(c) $display("ok   %0s", msg); else begin $display("FAIL %0s", msg); errors = errors + 1; end
end endtask

task frames(input integer f); repeat(f*HT*VT) @(posedge clk); endtask

integer n0;
initial begin
  frames(5);
  check(n >= 1, "vreset after power-up");
  n0 = n; frames(3);
  check(n == n0, "no vreset while nothing changes");
  // rtg on: 800x600, pll re-locks
  @(posedge clk) video_mode <= 2'b10; repeat(3) @(posedge clk); video_locked <= 1'b0;
  repeat(2000) @(posedge clk); video_locked <= 1'b1;
  frames(4);
  // rtg off: native, pll re-locks again
  n0 = n;
  @(posedge clk) video_mode <= 2'b01; repeat(3) @(posedge clk); video_locked <= 1'b0;
  repeat(2000) @(posedge clk); video_locked <= 1'b1; t_lock = $time;
  frames(3);
  check(n - n0 >= 1, "vreset after the return to the native mode");
  check(t_vr > t_lock + 255*35.2, "the last vreset comes after the pll is locked again");
  n0 = n; frames(3);
  check(n == n0, "no vreset afterwards");
  check(n_bad == 0, "vreset always at the same position");
  if(errors == 0) $display("PASS (FIX=%0d)", FIX); else $display("FAIL (FIX=%0d, %0d errors)", FIX, errors);
  $finish;
end
endmodule
