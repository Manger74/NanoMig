`timescale 1ns/1ps
`define ENABLE_NANOPORT
module tb;
reg clk=0; always #17.5 clk=~clk;      // ~28.5 MHz
reg reset=1;
// spi
reg ss=1, sck=0, mosi=0; wire miso;
wire sys_s, hid_s, osd_s, sdc_s, start, net_s; wire [7:0] dout;
wire [7:0] net_din; wire sck_rd; wire [10:0] sck_idx; wire [7:0] sck_q;
mcu_spi spi(.clk(clk),.reset(reset),.spi_io_ss(ss),.spi_io_clk(sck),.spi_io_din(mosi),.spi_io_dout(miso),
 .mcu_sys_strobe(sys_s),.mcu_hid_strobe(hid_s),.mcu_osd_strobe(osd_s),.mcu_sdc_strobe(sdc_s),.mcu_start(start),
 .mcu_sys_din(8'h11),.mcu_hid_din(8'h22),.mcu_osd_din(8'h33),.mcu_sdc_din(8'h44),
 .mcu_net_strobe(net_s),.mcu_net_din(net_din),.net_sck_rd(sck_rd),.net_sck_idx(sck_idx),.net_sck_q(sck_q),
 .mcu_dout(dout));
// cpu
reg req=0, we=0; reg [15:1] addr=0; reg uds=1, lds=1; reg [15:0] wd=0; wire [15:0] rd; wire ack; wire int2, mint;
reg iack=0;
nanoport np(.clk(clk),.reset(reset),.cpu_req(req),.cpu_we(we),.cpu_addr(addr),.cpu_uds_n(uds),.cpu_lds_n(lds),
 .cpu_din(wd),.cpu_dout(rd),.cpu_ack(ack),.int2(int2),.spi_strobe(net_s),.spi_start(start),.spi_din(dout),
 .spi_dout(net_din),.mcu_int(mint),.mcu_iack(iack),.sck(sck),.sck_rd(sck_rd),.sck_idx(sck_idx),.sck_q(sck_q));

// TG68K like bus access: request held until ack, data sampled with ack
task cpu_wr(input [15:0] a, input [15:0] d, input u, input l);
 begin @(posedge clk); #1 req=1; we=1; addr=a[15:1]; wd=d; uds=u; lds=l;
  @(posedge clk); while(!ack) @(posedge clk); #1 req=0; we=0; uds=1; lds=1; end endtask
// back to back: new request in the cycle right after ack
reg [15:0] rdv;
task cpu_rd(input [15:0] a);
 begin @(posedge clk); #1 req=1; we=0; addr=a[15:1];
  @(posedge clk); while(!ack) @(posedge clk); rdv=rd; #1 req=0; end endtask

real half; integer gap;
reg [7:0] rx;
task spi_byte(input [7:0] b);
 integer i; begin
  rx=0;
  for(i=7;i>=0;i=i-1) begin
   #(half) sck=1; mosi=b[i];   // mode 1: setup on rising (MCU drives on rising too)
   #(half) sck=0; rx={rx[6:0],miso};
  end
  if(gap) #(gap);
 end endtask
task spi_begin; begin ss=0; #50; end endtask
task spi_end; begin #50 ss=1; #200; end endtask

integer i, errors=0, n; reg [7:0] b0,b1,b2,b3; reg [15:0] len;
reg [7:0] frame [0:1600];

task check(input cond, input [255:0] msg); begin if(!cond) begin errors=errors+1; $display("FAIL %0s @%0t", msg, $time); end end endtask

task mcu_status; begin
 spi_begin; spi_byte(5); spi_byte(0); spi_byte(0); b0=rx; spi_byte(0); b1=rx; spi_byte(0); b2=rx; spi_byte(0); b3=rx; spi_end;
end endtask

task test_round(input integer flen, input integer gp, input real hp);
 integer k; begin
  gap=gp; half=hp; $display("round len=%0d gap=%0d half=%0f errors so far %0d", flen, gp, hp, errors);
  // ---- amiga sends a frame
  cpu_rd(16'hC002); check(rdv[7:4]==2, "txfree");
  cpu_rd(16'hC004); n = 16'h8000 + rdv[7:4]*16'h800;
  cpu_wr(n, flen, 0,0);
  for(k=0;k<flen;k=k+2) begin
   if(k+1<flen) cpu_wr(n+2+k, {frame[k],frame[k+1]},0,0);
   else cpu_wr(n+2+k, {frame[k],8'h00},0,1);  // last odd byte as byte write
  end
  cpu_wr(16'hC008, 0,0,0);
  check(mint==1, "mcu irq after TXGO");
  iack=1; @(posedge clk); iack=0; @(posedge clk);
  mcu_status; check(b0[7:4]==4'hA && b0[2]==1, "status tx pending"); check(b2[3:0]==1, "tx used 1");
  // ---- MCU reads it back to back
  spi_begin; spi_byte(5); spi_byte(2);
  spi_byte(0); len[15:8]=rx; spi_byte(0); len[7:0]=rx;
  check(len===flen, "tx len");
  for(k=0;k<flen;k=k+1) begin spi_byte(0); if(rx!==frame[k]) begin errors=errors+1; if(errors<10) $display("FAIL tx byte %0d %h!=%h", k, rx, frame[k]); end end
  spi_end;
  spi_begin; spi_byte(5); spi_byte(3); spi_end;
  mcu_status; check(b2[3:0]==0, "tx done");
  // ---- MCU puts a frame
  spi_begin; spi_byte(5); spi_byte(1); spi_byte(flen>>8); spi_byte(flen&255);
  for(k=0;k<flen;k=k+1) spi_byte(frame[flen-1-k]);
  spi_end;
  cpu_rd(16'hC002); check(rdv[3:0]==1, "rx count 1");
  check(int2==0, "no int2 when disabled");
  cpu_wr(16'hC00A, 1,0,0); @(posedge clk); check(int2==1, "int2 rx");
  cpu_rd(16'hC004); n = rdv[3:0];
  cpu_rd(n*16'h800); check(rdv==flen, "rx len");
  for(k=0;k<flen;k=k+2) begin cpu_rd(n*16'h800+2+k);
    if(rdv[15:8]!==frame[flen-1-k] || (k+1<flen && rdv[7:0]!==frame[flen-2-k])) begin errors=errors+1; if(errors<10) $display("FAIL rx word %0d %h", k, rdv); end end
  cpu_wr(16'hC006,0,0,0);
  cpu_rd(16'hC002); check(rdv[3:0]==0, "rx acked");
  @(posedge clk); check(int2==0, "int2 off");
  cpu_wr(16'hC00A, 0,0,0);
 end endtask

initial begin
 for(i=0;i<1600;i=i+1) frame[i]=$random;
 #200 reset=0; #200;
 half=26; gap=0;
 mcu_status;  // settles the X state of the simulation
 // info: link + mac
 spi_begin; spi_byte(5); spi_byte(4); spi_byte(1); spi_byte(8'h02); spi_byte(8'h11); spi_byte(8'h22); spi_byte(8'h33); spi_byte(8'h44); spi_byte(8'h55); spi_end;
 cpu_rd(16'hC000); check(rdv==16'h4E50, "id");
 cpu_rd(16'hC010); check(rdv==16'h0211, "mac0"); cpu_rd(16'hC014); check(rdv==16'h4455, "mac2");
 cpu_rd(16'hC002); check(rdv[15]==1, "link");
 // other targets still work with per byte gaps
 gap=1000; spi_begin; spi_byte(0); spi_byte(0); spi_byte(0); check(rx==8'h11,"sys target read"); spi_end;
 test_round(60, 0, 26);       // 19.2 MHz back to back
 test_round(1514, 0, 26);
 test_round(61, 800, 26);     // gaps between bytes
 test_round(1515, 0, 10.4);   // 48 MHz back to back
 // ring full behaviour: put 5 frames, only 4 accepted
 half=26; gap=0;
 for(n=0;n<5;n=n+1) begin spi_begin; spi_byte(5); spi_byte(1); spi_byte(0); spi_byte(64); for(i=0;i<64;i=i+1) spi_byte(i); spi_end; end
 cpu_rd(16'hC002); check(rdv[3:0]==4, "rx full 4");
 mcu_status; check(b0[3]==1, "rx full flag"); check(b1[3:0]==0, "rx free 0");
 iack=1; @(posedge clk); iack=0; @(posedge clk);
 cpu_wr(16'hC006,0,0,0); check(mint==1, "irq on rx not full");
 cpu_wr(16'hC00C,16'h0080,0,0); cpu_rd(16'hC002); check(rdv[3:0]==0 && rdv[7:4]==2, "ring reset");
 $display("DONE errors=%0d", errors); $finish;
end
endmodule
