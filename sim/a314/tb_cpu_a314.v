// A314_FAST: the real TG68K (Verilog translation, sim/TG68KdotC_Kernel.v) in the real
// cpu_wrapper.v runs cpu_a314.s, which accesses the A314 registers like a314.device.
// The clockport accesses take the fast path of cpu_wrapper to a314_cp, everything else
// (program, data) is served by a memory model on the chip bus (TURBO=0) or the RAM
// port (TURBO=7, "turbo chip": chip RAM through ramreq like with the cache).
// Checks: the 64 bytes in the A314 RAM, read back, interrupt bits, pointer, and that
// the chip bus never sees $D8xxxx. Reports the clocks per clockport byte.
`timescale 1ns/1ps
module tb;
parameter TURBO = 0;
reg clk = 0; always #17.6 clk = ~clk;          // 28.4 MHz
reg rst_n = 0;
reg [1:0] phc = 0; always @(posedge clk) phc <= phc + 1'd1;
wire ph2 = phc == 2'd1, ph1 = phc == 2'd3;

// memory model: 64 KB, program image at 0
reg [15:0] mem [0:32767];
integer fd, i, nb;
reg [7:0] b [0:65535];

// chip bus
wire [23:1] chip_addr; wire [15:0] chip_din; wire chip_as, chip_uds, chip_lds, chip_rw;
reg  chip_dtack = 1'b1;
wire [15:0] chip_dout = mem[chip_addr[15:1]];
integer chip_d8 = 0;
always @(posedge clk) begin
  chip_dtack <= chip_as;
  if(!chip_as && chip_addr[23:16] == 8'hd8) chip_d8 = chip_d8 + 1;
  if(!chip_as && !chip_rw && ph1) begin
    if(!chip_uds) mem[chip_addr[15:1]][15:8] <= chip_din[15:8];
    if(!chip_lds) mem[chip_addr[15:1]][7:0]  <= chip_din[7:0];
  end
end

// RAM port: ready two clocks after the request
wire ramreq; wire [28:1] ramaddr; wire [15:0] ramdin; wire ramlds, ramuds;
reg [1:0] rcnt = 0; reg ramready = 0; reg [15:0] ramdout;
wire [1:0] cpustate;
always @(posedge clk) begin
  ramready <= 1'b0;
  if(ramreq && !ramready) begin
    rcnt <= rcnt + 1'd1;
    if(rcnt == 2'd2) begin
      rcnt <= 0; ramready <= 1'b1;
      ramdout <= mem[ramaddr[15:1]];
      if(cpustate == 2'b11) begin
        if(!ramuds) mem[ramaddr[15:1]][15:8] <= ramdin[15:8];
        if(!ramlds) mem[ramaddr[15:1]][7:0]  <= ramdin[7:0];
      end
    end
  end else rcnt <= 0;
end

wire a_sel, a_end, a_we; wire [1:0] a_reg; wire [7:0] a_din, a_dout;
wire cpu_clkena;
cpu_wrapper cpu (
  .reset(rst_n), .reset_out(), .clk(clk), .ph1(ph1), .ph2(ph2),
  .cpucfg(2'b11), .fastramcfg(3'd0), .chipramcfg(2'd0), .slowramcfg(2'd0), .turbocfg(TURBO[2:0]), .bootrom(1'b0),
  .chip_addr(chip_addr), .chip_dout(chip_dout), .chip_din(chip_din), .chip_as(chip_as),
  .chip_uds(chip_uds), .chip_lds(chip_lds), .chip_rw(chip_rw), .chip_dtack(chip_dtack), .chip_ipl(3'b111),
  .ramreq(ramreq), .ramaddr(ramaddr), .ramdin(ramdin), .ramdout(ramdout), .ramready(ramready),
  .ramlds(ramlds), .ramuds(ramuds), .ramshared(),
  .a314_sel(a_sel), .a314_end(a_end), .a314_we(a_we), .a314_reg(a_reg), .a314_din(a_din), .a314_dout(a_dout),
  .cpustate(cpustate), .cacr(), .nmi_addr(), .cpu_clkena(cpu_clkena));

wire int6, pi_irq; wire [7:0] h_rdata;
a314_cp A314 (.clk(clk), .reset(~rst_n),
  .a_sel(a_sel), .a_end(a_end), .a_we(a_we), .a_reg(a_reg), .a_din(a_din), .a_dout(a_dout), .int6(int6),
  .h_addr(13'd0), .h_we(1'b0), .h_wdata(8'd0), .h_rdata(h_rdata), .h_irq_we(1'b0), .h_irq_data(8'd0), .pi_irq(pi_irq));

// clockport bytes: count and time between them
integer n_acc = 0, n_sram = 0; time t_first = 0, t_last = 0;
always @(posedge clk) if(a_end) begin
  n_acc = n_acc + 1;
  if(a_reg == 0) begin
    if(n_sram == 64) t_first = $time;           // start of the read loop
    n_sram = n_sram + 1;
    t_last = $time;
  end
end

integer errors = 0;
task check(input c, input [8*80-1:0] msg); begin
  if(c) $display("ok   %0s", msg); else begin $display("FAIL %0s", msg); errors = errors + 1; end
end endtask

// the VERILATOR port list of cpu_wrapper leaves berr and skipFetch of the kernel open
// (verilator takes 0); connect them like the synthesized VHDL kernel
initial begin
  force cpu.cpu_inst_p.berr = 1'b0;
  force cpu.skip_fetch_i = cpu.cpu_inst_p.skipFetch;
end

initial begin
  for(i = 0; i < 65536; i = i + 1) b[i] = 0;
  fd = $fopen("cpu_a314.bin", "rb"); nb = $fread(b, fd); $fclose(fd);
  for(i = 0; i < 32768; i = i + 1) mem[i] = {b[2*i], b[2*i+1]};
  repeat(20) @(posedge clk); rst_n = 1;
  for(i = 0; i < 400000 && mem[16'h1046 >> 1] != 16'hf00d; i = i + 1) @(posedge clk);
  check(mem[16'h1044 >> 1] == 16'h600d && mem[16'h1046 >> 1] == 16'hf00d, "program ran to the end");
  if(errors) $display("     done = %h %h after %0d clocks", mem[16'h1044 >> 1], mem[16'h1046 >> 1], i);
  begin : cmp
    integer e1, e2, k; reg [7:0] srcb; e1 = 0; e2 = 0;
    for(k = 0; k < 64; k = k + 1) begin
      srcb = b[lbl_src + k];
      if(A314.mem[16'h123 + k] !== srcb) e1 = e1 + 1;
      if((k[0] ? mem[(16'h1000 + k) >> 1][7:0] : mem[(16'h1000 + k) >> 1][15:8]) !== srcb) e2 = e2 + 1;
    end
    check(e1 == 0, "64 bytes written into the A314 RAM at $0123 (pointer auto increment)");
    check(e2 == 0, "64 bytes read back by the CPU");
  end
  check(mem[16'h1040 >> 1] == 16'h0100, "IRQ register: cp_irq 1 after set, 0 after clear");
  check(mem[16'h1042 >> 1][15:8] == 8'h00, "A_LO reads 0");
  check(pi_irq == 1'b1 && int6 == 1'b0, "pi_irq set, int6 cleared");
  check(A314.ptr == 13'h123 + 64, "pointer after the read loop");
  check(n_sram == 128, "exactly 128 SRAM accesses (no double side effects)");
  check(chip_d8 == 0, "no $D8xxxx access on the chip bus");
  $display("clockport read loop: %0d clocks per byte (%0d ns)", (t_last - t_first) / 63 / 35, (t_last - t_first) / 63);
  if(errors == 0) $display("PASS (TURBO=%0d)", TURBO); else $display("FAIL (%0d errors)", errors);
  $finish;
end

localparam lbl_src = 'h200;                    // src: in cpu_a314.s
endmodule
