`timescale 1ns/1ps
// osd_hdmi inside hdmi.sv: one set OSD pixel must appear as 2x2 block at the
// centered position, aligned with the picture (video_data register)
module tb_hdmi_osd;
reg clk=0, wclk=0; always #15 clk=~clk; always #17.6 wclk=~wclk;
reg rst=1, hrst=1, st=0, sa=0; reg [7:0] d=0;
wire [2:0] tmds; wire tc;
logic [15:0] aw [1:0]; assign aw[0]=0; assign aw[1]=0;
hdmi #(.DVI_OUTPUT(1)) h(.clk_pixel_x5(1'b0), .clk_pixel(clk), .clk_audio(1'b0),
  .pal_mode(1'b1), .screen(2'd0), .short_frame(1'b0), .interlace(1'b0), .reset(hrst),
  .osd_clk(wclk), .osd_reset(rst), .osd_strobe(st), .osd_start(sa), .osd_data(d),
  .rgb(24'h102030), .audio_sample_word(aw), .tmds(tmds), .tmds_clock(tc));
task send(input s, input [7:0] v); begin @(posedge wclk); st<=1; sa<=s; d<=v; @(posedge wclk); st<=0; end endtask
integer n=0, first_x=-1, first_y=-1, frames=0;
initial begin
  repeat(3) @(posedge wclk); rst<=0; hrst<=0;
  // tile 0, column 0 = 0x01: only the top left OSD pixel (2x2 on screen) is set
  send(1,2); send(0,0); send(0,8'h01);
  send(1,1); send(0,1);
end
// video_data holds pixel cx-1 (it is registered from the rgb of cx)
always @(posedge clk) begin
  if(!hrst && h.cx==0 && h.cy==0) frames <= frames+1;
  if(frames==2 && h.video_data==24'hffffff) begin
     if(first_x<0) begin first_x = h.cx-1; first_y = h.cy; end
     n = n+1;
  end
  if(frames==3) begin
     $display("white pixels %0d, first at %0d,%0d (expected 4 at 232,224)", n, first_x, first_y);
     $finish;
  end
end
initial #60000000 begin $display("TIMEOUT"); $finish; end
endmodule
