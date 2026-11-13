/*
    a314_host.v

    SPI target 6 ("A314") of the MCU interface: host side of a314_cp. The FPGA Companion plays
    the Raspberry Pi of the A314 here: it reads and writes the shared memory and sets/clears the
    interrupt bits. Byte protocol like the other targets (the reply to a byte is set by its
    strobe and shifted out with the next byte, so the reply to byte n+1 is decided by byte n):

    first byte   command, the reply to it is stale
    cmd 0 STATUS reply 1: {7'b0, pi_irq} (reply 1 of every command is the status)
    cmd 1 READ   bytes: addr[15:8], addr[7:0], then N dummy bytes (the first two are needed
                 to fetch the data); reply byte 4+i (counted from the command = byte 0) is
                 RAM[addr + i]
    cmd 2 WRITE  bytes: addr[15:8], addr[7:0], then data bytes -> RAM[addr + i]
    cmd 3 IRQ    byte: value written to REG_IRQ of the Pi side: bit 7 = 1 sets the bits [1:0]
                 that are 1, bit 7 = 0 clears them (bit 0 = INT6 to the Amiga, bit 1 = pi_irq)
    cmd 4 ID     reply 1: status, reply 2: 0xA3, reply 3: version (1), reply 4: RAM size log2 (AW)

    irq is raised when pi_irq rises (the Amiga has called set_pi_irq) and cleared by iack
    (int_ack[6] of sysctrl), like the interrupt of plip_host. pi_irq itself is cleared by the
    Companion with cmd 3 / 0x02 before it takes the work (like a314d does); STATUS shows it.
*/

module a314_host #(
  parameter AW = 13
)(
  input             clk,
  input             reset,

  input             data_strobe,
  input             data_start,
  input [7:0]       data_in,
  output reg [7:0]  data_out,

  output reg        irq,
  input             iack,

  // a314_cp host side
  output reg [AW-1:0] h_addr,
  output reg        h_we,
  output reg [7:0]  h_wdata,
  input [7:0]       h_rdata,
  output reg        h_irq_we,
  output reg [7:0]  h_irq_data,
  input             pi_irq
);

// interrupt to the MCU: raised when the Amiga sets pi_irq, cleared by the acknowledge of sysctrl
// (not a level: the MCU acknowledges first and serves the request later in a task; a line that
// stays active until then would keep its interrupt handler busy forever)
reg pi_irq_d;
always @(posedge clk) begin
  pi_irq_d <= pi_irq;
  if(iack) irq <= 1'b0;
  if(pi_irq && !pi_irq_d) irq <= 1'b1;
  if(reset) irq <= 1'b0;
end

reg [7:0]  command;
reg [1:0]  cnt;                    // index of the byte after the command, saturates at 3
reg [7:0]  addr_hi;                // only the bits below AW are used

always @(posedge clk) begin
  h_we <= 1'b0;
  h_irq_we <= 1'b0;

  // WRITE: the byte is written in the clock after the strobe, then the address moves on
  if(h_we) h_addr <= h_addr + 1'd1;

  if(reset) begin
    command <= 8'hff;
    cnt <= 2'd0;
    h_addr <= {AW{1'b0}};
    data_out <= 8'h00;
  end else if(data_strobe) begin
    if(data_start) begin
      command <= data_in;
      cnt <= 2'd0;
      data_out <= { 7'd0, pi_irq };
    end else begin
      if(cnt != 2'd3) cnt <= cnt + 2'd1;

      case(command)
        8'd0: data_out <= 8'h00;

        8'd1: begin                                   // READ
                if(cnt == 2'd0) begin
                  addr_hi <= data_in;
                  data_out <= 8'h00;
                end else if(cnt == 2'd1) begin
                  h_addr <= { addr_hi[AW-9:0], data_in };
                  data_out <= 8'h00;
                end else begin
                  data_out <= h_rdata;                // RAM[h_addr], set by the strobe two bytes earlier
                  h_addr <= h_addr + 1'd1;
                end
              end

        8'd2: begin                                   // WRITE
                if(cnt == 2'd0) addr_hi <= data_in;
                else if(cnt == 2'd1) h_addr <= { addr_hi[AW-9:0], data_in };
                else begin
                  h_wdata <= data_in;
                  h_we <= 1'b1;
                end
              end

        8'd3: if(cnt == 2'd0) begin
                h_irq_data <= data_in;
                h_irq_we <= 1'b1;
              end

        8'd4: data_out <= (cnt == 2'd0) ? 8'hA3 :
                          (cnt == 2'd1) ? 8'd1 :
                          (cnt == 2'd2) ? AW[7:0] : 8'h00;

        default: data_out <= 8'h00;
      endcase
    end
  end
end

endmodule
