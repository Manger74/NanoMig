`timescale 1ns/1ps
// ring reset (CTRL bit 7) by the cpu in the same cycle as an MCU pointer
// update (RX commit, TX_DONE): the reset has to win
module tb_race;
reg clk=0; always #17.5 clk=~clk;
reg reset=1, req=0, we=0; reg [15:1] addr=0; reg [15:0] wd=0;
reg strobe=0, start=0; reg [7:0] din=0;
nanoport np(.clk(clk),.reset(reset),.cpu_req(req),.cpu_we(we),.cpu_addr(addr),.cpu_uds_n(1'b0),.cpu_lds_n(1'b0),
 .cpu_din(wd),.cpu_dout(),.cpu_ack(),.int2(),.spi_strobe(strobe),.spi_start(start),.spi_din(din),
 .spi_dout(),.mcu_int(),.mcu_iack(1'b0),.sck(1'b0),.sck_rd(1'b0),.sck_idx(11'd0),.sck_q());
integer i, err=0;
task mcu(input s, input [7:0] d); begin @(posedge clk) #1 strobe=1; start=s; din=d; @(posedge clk) #1 strobe=0; start=0; end endtask
task cpuw(input [15:0] a, input [15:0] d); begin @(posedge clk) #1 req=1; we=1; addr=a[15:1]; wd=d; @(posedge clk) #1 req=0; we=0; end endtask
initial begin
  #100 reset=0;
  // RX_PUT of a 14 byte frame, the cpu resets the rings with the last byte
  mcu(1, 1); mcu(0, 0); mcu(0, 14);
  for(i=0;i<13;i=i+1) mcu(0, i);
  @(posedge clk) #1 strobe=1; start=0; din=8'h55; req=1; we=1; addr=15'h6006; wd=16'h0081;
  @(posedge clk) #1 strobe=0; req=0; we=0;
  if(np.rx_tail !== 0 || np.rx_head !== 0) begin err=err+1; $display("rx not reset: tail %0d head %0d", np.rx_tail, np.rx_head); end
  // queue a TX frame, TX_DONE starts in the same cycle as a ring reset
  cpuw(16'hC008, 0);
  if(np.tx_tail !== 1) err=err+1;
  @(posedge clk) #1 strobe=1; start=1; din=3; req=1; we=1; addr=15'h6006; wd=16'h0081;
  @(posedge clk) #1 strobe=0; start=0; req=0; we=0;
  if(np.tx_head !== 0 || np.tx_tail !== 0) begin err=err+1; $display("tx not reset: head %0d tail %0d", np.tx_head, np.tx_tail); end
  // normal operation afterwards: one frame in, one acked
  mcu(1, 1); mcu(0, 0); mcu(0, 14); for(i=0;i<14;i=i+1) mcu(0, i);
  if(np.rx_tail !== 1) err=err+1;
  cpuw(16'hC006, 0);
  if(np.rx_head !== 1) err=err+1;
  $display("race: errors %0d", err); $finish;
end
endmodule
