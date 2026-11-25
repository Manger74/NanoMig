`timescale 1ns/1ps
module tb2;
reg clk=0; always #17.5 clk=~clk;
reg reset=1; reg req=0, we=0; reg [15:1] addr=0; reg [15:0] wd=0; wire [15:0] rd; wire ack;
nanoport np(.clk(clk),.reset(reset),.cpu_req(req),.cpu_we(we),.cpu_addr(addr),.cpu_uds_n(1'b0),.cpu_lds_n(1'b0),
 .cpu_din(wd),.cpu_dout(rd),.cpu_ack(ack),.int2(),.spi_strobe(1'b0),.spi_start(1'b0),.spi_din(8'd0),
 .spi_dout(),.mcu_int(),.mcu_iack(1'b0),.sck(1'b0),.sck_rd(1'b0),.sck_idx(11'd0),.sck_q());
integer i, nack=0, err=0;
// TG68K model: address/data registered on the clkena (=ack) edge, request stays up
always @(posedge clk) if(!reset && req && ack) begin
  nack <= nack+1;
  if(!we && rd !== {np.rx_hi[addr[12:1]], np.rx_lo[addr[12:1]]}) err<=err+1;
  addr <= addr + 1; wd <= wd + 16'h0101;
end
initial begin
  for(i=0;i<4096;i=i+1) begin np.rx_hi[i]=i; np.rx_lo[i]=~i; end
  #100 reset=0;
  @(posedge clk) #1 req=1; we=1; addr=15'h4000; wd=16'h0102;   // TX writes
  repeat(200) @(posedge clk);
  #1 req=0; we=0;
  $display("writes acked %0d in 200 cycles", nack);
  for(i=0;i<nack;i=i+1) if({np.tx_hi[i],np.tx_lo[i]} !== 16'h0102 + i*16'h0101) err=err+1;
  if({np.tx_hi[nack],np.tx_lo[nack]} !== 16'hxxxx) err=err+1;   // nothing written beyond
  nack=0; @(posedge clk) #1 req=1; addr=15'h0000;
  repeat(200) @(posedge clk); #1 req=0;
  $display("reads acked %0d, errors %0d", nack, err); $finish;
end
endmodule
