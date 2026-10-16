/*
    uart_port.v

    Bridge between the serial port of the Amiga (paula_uart, bit level)
    and the "port" interface of the FPGA Companion (byte level, see
    sysctrl.v command 7). The companion offers a virtual Hayes/AT modem
    on that port, exactly as it does for the MFP of the MiSTeryNano.

    Frames are 8N1, the bit timing for the receive direction is derived
    from the SERPER register of paula, so the bridge follows whatever baud
    rate the Amiga software selects.

    amiga -> mcu: paula hands over each byte when it starts to send it
                  (tx_byte/tx_push) and the byte goes into a fifo. While
                  that fifo is full the transmitter of paula is held back
                  (hold), so no data is lost.
    mcu -> amiga: bytes from the mcu fifo are sent as frames to rxd of
                  paula. The next byte is not sent before the previous
                  one has been read by the Amiga (rbf cleared), so
                  the receiver never overruns.

    AT_MODEM_LITE: small variant for tight builds. Instead of the fifos
    there is a single byte buffer per direction. Nothing is lost, as
    paula is held back while the tx byte is not yet read by the mcu and
    the mcu is told that there is no room while the rx byte is pending,
    but each byte needs one access of the mcu.
*/

module uart_port (
  input             clk,        // 28 MHz system clock
  input             clk7_en,    // 7 MHz enable, bit times are counted in these
  input             reset,

  // paula side
  input [14:0]      serper,     // SERPER, bit time is 2*serper+2 clk7 cycles
  input             rbf,        // receive buffer full (intreq[11])
  input [7:0]       tx_byte,    // byte paula starts to send ...
  input             tx_push,    // ... valid for one clk while this is high
  output            rxd,        // serial data to paula
  output            hold,       // tx fifo is full, paula must not start a frame

  // mcu side (same names as in MiSTeryNano atarist.v)
  output [31:0]     serial_status,
  output [7:0]      serial_tx_available,  // bytes waiting for the mcu
  input             serial_tx_strobe,
  output [7:0]      serial_tx_data,
  output [7:0]      serial_rx_available,  // free bytes in fifo to paula
  input             serial_rx_strobe,
  input [7:0]       serial_rx_data
);

`ifdef AT_MODEM_LITE

// ------------------------------------------------------------------
// amiga -> mcu: one byte
// ------------------------------------------------------------------

reg [7:0] tx_reg;
reg       tx_full;

assign hold = tx_full;
assign serial_tx_available = { 7'd0, tx_full };
assign serial_tx_data = tx_reg;

always @(posedge clk) begin
  if(reset) tx_full <= 1'b0;
  else begin
    if(serial_tx_strobe) tx_full <= 1'b0;   // mcu has read the byte
    if(tx_push) begin                       // only while !hold
      tx_reg <= tx_byte;
      tx_full <= 1'b1;
    end
  end
end

// ------------------------------------------------------------------
// mcu -> amiga: the byte is stored directly in the frame shift register
// ------------------------------------------------------------------

reg [9:0]  rx_sr;             // stop, 8 data bits, start (lsb first out)
reg [3:0]  rx_bits;
reg [15:0] rx_cnt;
reg        rx_full;           // byte pending or being sent
reg        rx_busy;

assign rxd = rx_busy ? rx_sr[0] : 1'b1;
assign serial_rx_available = { 7'd0, !rx_full };

always @(posedge clk) begin
  if(reset) begin
    rx_full <= 1'b0;
    rx_busy <= 1'b0;
  end else begin
    if(serial_rx_strobe && !rx_full) begin
      rx_sr <= { 1'b1, serial_rx_data, 1'b0 };
      rx_full <= 1'b1;
    end

    if(clk7_en) begin
      if(!rx_busy) begin
        // don't start while the baud rate is unset (serper == 0)
        if(rx_full && (serper != 15'd0) && !rbf) begin
          rx_bits <= 4'd10;
          rx_cnt <= { serper, 1'b1 };
          rx_busy <= 1'b1;
        end
      end else if(rx_cnt == 16'd0) begin
        rx_sr <= { 1'b1, rx_sr[9:1] };
        rx_cnt <= { serper, 1'b1 };
        rx_bits <= rx_bits - 4'd1;
        if(rx_bits == 4'd1) begin
          rx_busy <= 1'b0;
          rx_full <= 1'b0;
        end
      end else
        rx_cnt <= rx_cnt - 16'd1;
    end
  end
end

`else

// ------------------------------------------------------------------
// amiga -> mcu
// ------------------------------------------------------------------

// 8 entries (7 usable) are enough as paula is held back when full
localparam DEPTH = 3;

wire       tx_full;
wire [DEPTH-1:0] tx_used;

assign hold = tx_full;
assign serial_tx_available = { {(8-DEPTH){1'b0}}, tx_used };

io_fifo #(.DEPTH(DEPTH)) tx_fifo (
  .reset      ( reset ),

  .in_clk     ( clk ),
  .in         ( tx_byte ),
  .in_strobe  ( 1'b0 ),
  .in_enable  ( tx_push ),

  .out_clk    ( clk ),
  .out        ( serial_tx_data ),
  .out_strobe ( serial_tx_strobe ),
  .out_enable ( 1'b0 ),

  .space      (  ),
  .used       ( tx_used ),
  .empty      (  ),
  .full       ( tx_full )
);

// ------------------------------------------------------------------
// mcu -> amiga
// ------------------------------------------------------------------

wire [7:0] rx_byte;
wire       rx_empty;
reg        rx_pop;

wire [DEPTH-1:0] rx_space;
assign serial_rx_available = { {(8-DEPTH){1'b0}}, rx_space };

io_fifo #(.DEPTH(DEPTH)) rx_fifo (
  .reset      ( reset ),

  .in_clk     ( clk ),
  .in         ( serial_rx_data ),
  .in_strobe  ( serial_rx_strobe ),
  .in_enable  ( 1'b0 ),

  .out_clk    ( clk ),
  .out        ( rx_byte ),
  .out_strobe ( 1'b0 ),
  .out_enable ( rx_pop ),

  .space      ( rx_space ),
  .empty      ( rx_empty ),
  .full       (  )
);

reg [9:0]  rx_sr = 10'h3ff;   // stop, 8 data bits, start (lsb first out)
reg [3:0]  rx_bits;
reg [15:0] rx_cnt;
reg        rx_busy;

assign rxd = rx_sr[0];

// don't start while the baud rate is unset (serper == 0)
wire rx_start = !rx_busy && !rx_empty && (serper != 15'd0) && !rbf;

always @(posedge clk) begin
  rx_pop <= 1'b0;

  if(reset) begin
    rx_sr <= 10'h3ff;
    rx_busy <= 1'b0;
  end else if(clk7_en) begin
    if(rx_start) begin
      rx_sr <= { 1'b1, rx_byte, 1'b0 };
      rx_bits <= 4'd10;
      rx_cnt <= { serper, 1'b1 };
      rx_busy <= 1'b1;
      rx_pop <= 1'b1;
    end else if(rx_busy) begin
      if(rx_cnt == 16'd0) begin
        rx_sr <= { 1'b1, rx_sr[9:1] };
        rx_cnt <= { serper, 1'b1 };
        rx_bits <= rx_bits - 4'd1;
        if(rx_bits == 4'd1) rx_busy <= 1'b0;
      end else
        rx_cnt <= rx_cnt - 16'd1;
    end
  end
end

`endif

// bit rate is not reported (0x800001 = "unsupported" as in the MiSTeryNano mfp),
// the frame format is fixed to 8N1
wire [23:0] bitrate = 24'h800001;
assign serial_status = { bitrate[7:0], bitrate[15:8], bitrate[23:16],
                         4'd8, 2'd0, 2'd0 };

endmodule
