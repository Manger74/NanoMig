/*
    a314_cp.v

    A314 "clockport" interface (Niklas Ekstroem, a314 / clockport_pi_interface, CC0) as a core
    module. The Amiga side is the register block of the CPLD cp_pi_if.v, the "Pi" side is the
    FPGA Companion (via SPI, see a314_host.v). The shared memory is a dual-port RAM.

    Amiga side, 4 byte registers (a314.device addresses them at ClockportAddress + reg*4,
    default $D80001, i.e. byte accesses on odd addresses):

      reg 0  SRAM    read/write RAM[amiga_ptr], pointer + 1 after every access (rd and wr)
      reg 1  IRQ     read:  bit 0 = cp_irq (own interrupt bit; the Pi's bit is not visible)
                     write: bit 7 = 1: set the bits [1:0] that are 1, bit 7 = 0: clear them
                            bit 0 = cp_irq (INT6 to the Amiga), bit 1 = pi_irq (to the Companion)
      reg 2  A_LO    pointer[7:0]   (write only, read gives 0)
      reg 3  A_HI    pointer[15:8]  (write only, read gives 0)

    The pointer is 16 bit like in the CPLD; the RAM is 2**AW bytes (default 8 KB), upper bits of
    the pointer alias. The host side has its own address (no shared pointer needed, the CPLD swaps
    two pointers for the same purpose) and sets/clears the interrupt bits with the same
    byte as the Pi would write to REG_IRQ.

    Bus protocol of the Amiga side: a_sel is high while a cycle to the register block is going
    on, a_reg/a_we/a_din are valid during that time. All side effects (write, pointer increment,
    interrupt bits) happen once, in the clock where a_end is high (the last clock of the cycle,
    like prb_rd of plip_peer). a_dout is valid during the cycle (RAM read data is registered,
    so the pointer must be stable one clock before a_end; it is stable for the whole cycle).
*/

module a314_cp #(
  parameter AW = 13
)(
  input             clk,
  input             reset,

  // Amiga side
  input             a_sel,
  input             a_end,
  input             a_we,
  input [1:0]       a_reg,
  input [7:0]       a_din,
  output reg [7:0]  a_dout,
  output            int6,          // INT6 request (active high), OR to the core's int6

  // host side (FPGA Companion)
  input [AW-1:0]    h_addr,
  input             h_we,
  input [7:0]       h_wdata,
  output reg [7:0]  h_rdata,       // valid one clock after h_addr
  input             h_irq_we,      // the Pi writes REG_IRQ (set/clear like the Amiga)
  input [7:0]       h_irq_data,
  output            pi_irq         // bit read back by the Pi / interrupt to the Companion
);

localparam [1:0] REG_SRAM = 2'd0, REG_IRQ = 2'd1, REG_A_LO = 2'd2, REG_A_HI = 2'd3;

reg [15:0] ptr;
reg        cp_irq_r, pi_irq_r;
assign int6   = cp_irq_r;
assign pi_irq = pi_irq_r;

(* ram_style = "block_ram" *) reg [7:0] mem [0:(1<<AW)-1];
reg [7:0] ram_q;

wire a_act    = a_sel && a_end;
wire a_wr_ram = a_act && a_we && a_reg == REG_SRAM;

// port A: Amiga
always @(posedge clk) begin
  if(a_wr_ram) mem[ptr[AW-1:0]] <= a_din;
  ram_q <= mem[ptr[AW-1:0]];
end

// port B: host
always @(posedge clk) begin
  if(h_we) mem[h_addr] <= h_wdata;
  h_rdata <= mem[h_addr];
end

always @(*) begin
  case(a_reg)
    REG_SRAM: a_dout = ram_q;
    REG_IRQ:  a_dout = { 7'd0, cp_irq_r };
    default:  a_dout = 8'h00;
  endcase
end

reg [1:0] irq_n;
always @(posedge clk) begin
  if(reset) begin
    ptr <= 16'd0;
    cp_irq_r <= 1'b0;
    pi_irq_r <= 1'b0;
  end else begin
    // interrupt bits: the Amiga's write and the host's write may meet, the host's wins
    irq_n = { pi_irq_r, cp_irq_r };
    if(a_act && a_we && a_reg == REG_IRQ)
      irq_n = a_din[7] ? (irq_n | a_din[1:0]) : (irq_n & ~a_din[1:0]);
    if(h_irq_we)
      irq_n = h_irq_data[7] ? (irq_n | h_irq_data[1:0]) : (irq_n & ~h_irq_data[1:0]);
    { pi_irq_r, cp_irq_r } <= irq_n;

    if(a_act) begin
      if(a_we) begin
        if(a_reg == REG_A_LO) ptr[7:0]  <= a_din;
        if(a_reg == REG_A_HI) ptr[15:8] <= a_din;
      end
      if(a_reg == REG_SRAM) ptr <= ptr + 16'd1;     // read and write
    end
  end
end

endmodule
