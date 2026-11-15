// DISABLE_IDE1 equivalence test: the same Amiga/MCU accesses with and
// data_out is compared where the cpu takes it, at the end of a read cycle
// without ide1, every output of gayle is printed each clock -> traces must match
`timescale 1ns/1ps
module tb;
reg clk=0, reset=1; always #5 clk=~clk;
reg [23:1] addr=0; reg [15:0] din=0; reg rd=0, wr=0, sel_ide=0, sel_gayle=0, longword=0;
reg [4:0] ide_address=0; reg ide_write=0, ide_read=0; reg [15:0] ide_writedata=0;
wire [15:0] dout, ide_readdata; wire irq, nrdy, led; wire [5:0] ide_req;
gayle g(.clk(clk),.reset(reset),.addr(addr),.data_in(din),.data_out(dout),.rd(rd),.wr(wr),
  .sel_ide(sel_ide),.sel_gayle(sel_gayle),.irq(irq),.nrdy(nrdy),.longword(longword),
  .ide_req(ide_req),.ide_address(ide_address),.ide_write(ide_write),.ide_writedata(ide_writedata),
  .ide_read(ide_read),.ide_readdata(ide_readdata),.led(led));
integer i, seed=1;
always @(posedge clk) if(!reset) $display("%b %b %b %b %h", irq, nrdy, led, ide_req, ide_readdata);
task amiga(input [23:0] a, input w, input [15:0] d, input lw); begin
  @(negedge clk) addr=a[23:1]; sel_ide=(a[23:16]==8'hda); sel_gayle=(a[23:16]==8'hde);
  din=d; rd=~w; wr=w; longword=lw; repeat(3) @(negedge clk); if(rd) $display("rd %h = %h", a, dout); rd=0; wr=0; sel_ide=0; sel_gayle=0; @(negedge clk);
end endtask
task mgmt(input [3:0] a, input w, input [15:0] d); begin
  @(negedge clk) ide_address={1'b0,a}; ide_write=w; ide_read=~w; ide_writedata=d;
  @(negedge clk) ide_write=0; ide_read=0;
end endtask
initial begin
  repeat(4) @(negedge clk); reset=0;
  mgmt(6, 1, 16'h0089);                 // ide0: both drives present
  for(i=0;i<8;i=i+1) begin amiga(24'hda2000+i*4,0,0,0); amiga(24'hda3000+i*4,0,0,0); end
  amiga(24'hda3018,1,16'h0200,0);       // Kickstart writes the control register on port 1
  amiga(24'hda3018,0,0,0); amiga(24'hda301c,1,16'h00ec,0);   // command on port 1 (no drive)
  amiga(24'hda2018,1,16'h00a0,0); amiga(24'hda201c,1,16'h00ec,0); // identify on port 0
  mgmt(5, 1, 16'h0058);                 // MCU: status drq
  for(i=0;i<4;i=i+1) mgmt(15,1,i);      // MCU fills the buffer
  for(i=0;i<300;i=i+1) begin            // random Amiga accesses to tfr, gayle and both ports
    amiga({8'hda, ($random(seed) & 1) ? 4'h3 : 4'h2, 4'h0, 3'b0, 5'($random(seed) & 5'h1c)},
          $random(seed) & 1, $random(seed), $random(seed) & 1);
    if(i%37==0) amiga({8'hda, 4'h8 | 4'($random(seed)&3), 12'h000}, $random(seed)&1, $random(seed), 0);
    if(i%53==0) amiga(24'hde1000, 0, 0, 0);
  end
  $finish;
end
endmodule
