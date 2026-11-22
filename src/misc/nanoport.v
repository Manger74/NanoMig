// nanoport.v
//
// Network interface for the NanoMig: a Zorro II I/O card (autoconfigured in
// cpu_wrapper.v) with ethernet frame buffers in block ram. The Amiga side is
// served by the SANA-II driver nanoport.device, the frames are moved to and
// from the FPGA Companion via SPI target 5 and bridged into its network
// (WiFi or USB ethernet).
//
// The card sits on the fast cpu path, not on the chip bus: every word access
// is acknowledged after two clk cycles. Only the TG68K is supported.
//
// Card layout (64 KiB, word accesses, byte writes allowed in the TX area):
//   $0000-$7FFF  RX slots, 2 KiB each (RX_SLOTS), read only
//   $8000-$BFFF  TX slots, 2 KiB each (TX_SLOTS), write only
//   $C000-$FFFF  registers
// Slot format: word 0 = frame length in bytes, frame data from offset 2 on.
// The ethernet payload thus starts long word aligned at slot offset 16.
//
// Registers:
//   $C000 R  ID        $4E50 ("NP")
//   $C002 R  STATUS    [15] link up (Companion), [14] online (CTRL[0]),
//                      [7:4] free TX slots, [3:0] pending RX frames
//   $C004 R  PTRS      [7:4] TX tail slot, [3:0] RX head slot
//   $C006 W  RXACK     any write releases the RX head slot
//   $C008 W  TXGO      any write hands the TX tail slot to the Companion
//   $C00A RW INTENA    [0] INT2 while RX frames are pending
//                      [1] INT2 while TX slots are free
//   $C00C RW CTRL      [0] online, [1] promiscuous (passed to the Companion)
//                      writing [7]=1 empties both rings
//   $C010-$C014 R MAC  station address set by the Companion
//   $C016 R  VERSION   [15:12] log2 RX slots, [11:8] log2 TX slots, [7:0] 1
//
// SPI target 5, first byte after the target id is the sub command:
//   0 STATUS  reply (one byte delayed): $A0|flags, rx free|rx tail<<4,
//             tx pending|tx head<<4, CTRL
//             flags: [0] online, [1] promisc, [2] tx pending, [3] rx full
//   1 RX_PUT  len hi, len lo, frame bytes; the slot is committed after the
//             last byte. Ignored when the ring is full.
//   2 TX_GET  the bytes following the sub command return len hi, len lo and
//             the frame bytes of the TX head slot (no extra delay). Served
//             from the spi clock domain, so the MCU may clock the bytes back
//             to back.
//   3 TX_DONE releases the TX head slot
//   4 INFO    flags ([0] link up), mac[0..5]
// The MCU interrupt (sysctrl int_in[5]) is raised whenever the Amiga queued a
// frame, changed CTRL or freed a slot of a full RX ring. int_ack[5] clears it.

module nanoport #(
  parameter RX_BITS = 2,   // 4 receive slots
  parameter TX_BITS = 1    // 2 transmit slots
) (
  input		    clk,
  input		    reset,         // amiga reset, empties rings and CTRL

  // cpu (TG68K fast path)
  input		    cpu_req,
  input		    cpu_we,
  input [15:1]	    cpu_addr,
  input		    cpu_uds_n,
  input		    cpu_lds_n,
  input [15:0]	    cpu_din,
  output [15:0]	    cpu_dout,
  output reg	    cpu_ack,
  output	    int2,

  // MCU, clk domain
  input		    spi_strobe,
  input		    spi_start,
  input [7:0]	    spi_din,
  output reg [7:0]  spi_dout,
  output reg	    mcu_int,
  input		    mcu_iack,

  // MCU, spi clock domain (TX frame read out)
  input		    sck,
  input		    sck_rd,
  input [10:0]	    sck_idx,
  output [7:0]	    sck_q
);

localparam RX_SLOTS = 1 << RX_BITS;
localparam TX_SLOTS = 1 << TX_BITS;
localparam [3:0] RXB4 = RX_BITS;
localparam [3:0] TXB4 = TX_BITS;

// ------------------------------------------------------------------ rings
reg [RX_BITS:0] rx_head, rx_tail;   // one bit wider than the slot index
reg [TX_BITS:0] tx_head, tx_tail;

wire [RX_BITS:0] rx_count = rx_tail - rx_head;
wire [TX_BITS:0] tx_used  = tx_tail - tx_head;
wire		 rx_full  = rx_count == RX_SLOTS;
wire [TX_BITS:0] tx_free  = TX_SLOTS - tx_used;

reg [7:0]  ctrl;
reg [1:0]  intena;
reg	   link = 1'b0;   // set by the Companion, kept over amiga resets
reg [47:0] mac  = 48'd0;

// zero extended copies for the status words
wire [3:0] rx_count4 = rx_count;
wire [3:0] rx_free4  = RX_SLOTS - rx_count;
wire [3:0] rx_head4  = rx_head[RX_BITS-1:0];
wire [3:0] rx_tail4  = rx_tail[RX_BITS-1:0];
wire [3:0] tx_free4  = tx_free;
wire [3:0] tx_used4  = tx_used;
wire [3:0] tx_head4  = tx_head[TX_BITS-1:0];
wire [3:0] tx_tail4  = tx_tail[TX_BITS-1:0];

assign int2 = (intena[0] && rx_count != 0) || (intena[1] && tx_free != 0);

// ------------------------------------------------------------------ memories
// RX: written by the MCU byte by byte, read by the cpu as words
reg [7:0] rx_hi [0:(1<<(RX_BITS+10))-1];
reg [7:0] rx_lo [0:(1<<(RX_BITS+10))-1];
// TX: written by the cpu with byte lanes, read by the MCU in the spi domain
reg [7:0] tx_hi [0:(1<<(TX_BITS+10))-1];
reg [7:0] tx_lo [0:(1<<(TX_BITS+10))-1];

// ------------------------------------------------------------------ cpu side
wire cpu_go  = cpu_req && !cpu_ack;
wire sel_reg = cpu_addr[15:14] == 2'b11;
wire sel_tx  = cpu_addr[15:14] == 2'b10;
wire cpu_wr  = cpu_go && cpu_we;

reg [7:0]  rxq_hi, rxq_lo;
reg [15:0] regq;
reg	   regq_sel;

always @(posedge clk)
  {rxq_hi, rxq_lo} <= {rx_hi[cpu_addr[RX_BITS+10:1]], rx_lo[cpu_addr[RX_BITS+10:1]]};

always @(posedge clk) begin
  if(cpu_wr && sel_tx && !cpu_uds_n) tx_hi[cpu_addr[TX_BITS+10:1]] <= cpu_din[15:8];
  if(cpu_wr && sel_tx && !cpu_lds_n) tx_lo[cpu_addr[TX_BITS+10:1]] <= cpu_din[7:0];
end

assign cpu_dout = regq_sel ? regq : {rxq_hi, rxq_lo};

always @(posedge clk) begin
  cpu_ack  <= cpu_go;
  regq_sel <= sel_reg;
  case(cpu_addr[4:1])
    4'h0:    regq <= 16'h4E50;
    4'h1:    regq <= { link, ctrl[0], 6'd0, tx_free4, rx_count4 };
    4'h2:    regq <= { 8'd0, tx_tail4, rx_head4 };
    4'h5:    regq <= { 14'd0, intena };
    4'h6:    regq <= { 8'd0, ctrl };
    4'h8:    regq <= mac[47:32];
    4'h9:    regq <= mac[31:16];
    4'ha:    regq <= mac[15:0];
    4'hb:    regq <= { RXB4, TXB4, 8'h01 };
    default: regq <= 16'h0000;
  endcase
end

// ------------------------------------------------------------------ MCU side
reg [7:0]  sub;
reg [11:0] bcnt;
reg [10:0] len;
reg	   put_ok;

wire rx_we = spi_strobe && !spi_start && sub == 8'd1 && put_ok && !bcnt[11];
wire [RX_BITS+9:0] rx_waddr = { rx_tail[RX_BITS-1:0], bcnt[10:1] };

always @(posedge clk) begin
  if(rx_we && !bcnt[0]) rx_hi[rx_waddr] <= spi_din;
  if(rx_we &&  bcnt[0]) rx_lo[rx_waddr] <= spi_din;
end

// TX read out, clocked by the spi clock. The slot index only changes
// with TX_DONE, i.e. between SPI transactions.
reg [7:0] txq_hi, txq_lo;
reg	  txq_sel;
always @(posedge sck) begin
  if(sck_rd) begin
    txq_hi  <= tx_hi[{ tx_head[TX_BITS-1:0], sck_idx[10:1] }];
    txq_lo  <= tx_lo[{ tx_head[TX_BITS-1:0], sck_idx[10:1] }];
    txq_sel <= sck_idx[0];
  end
end
assign sck_q = txq_sel ? txq_lo : txq_hi;

wire [7:0] st0 = { 4'hA, rx_full, tx_used != 0, ctrl[1:0] };
wire [7:0] st1 = { rx_tail4, rx_free4 };
wire [7:0] st2 = { tx_head4, tx_used4 };

// ------------------------------------------------------------------ control
reg reset_d = 1'b0;
initial mcu_int = 1'b0;
always @(posedge clk) reset_d <= reset;

always @(posedge clk) begin
  if(reset) begin
    rx_head <= 0;
    rx_tail <= 0;
    tx_head <= 0;
    tx_tail <= 0;
    ctrl    <= 8'h00;
    intena  <= 2'b00;
    // the interrupt is a level: holding it during reset would keep the
    // Companion busy and it could never release a reset it started itself
    if(mcu_iack) mcu_int <= 1'b0;
    put_ok  <= 1'b0;
    sub     <= 8'hff;
  end else begin
    if(mcu_iack) mcu_int <= 1'b0;
    if(reset_d)  mcu_int <= 1'b1;   // once after reset: the Amiga went offline

    // MCU bytes
    if(spi_strobe) begin
      if(spi_start) begin
	sub      <= spi_din;
	bcnt     <= 12'd0;
	spi_dout <= st0;
	put_ok   <= !rx_full;
	if(spi_din == 8'd3 && tx_used != 0)      // TX_DONE
	  tx_head <= tx_head + 1'd1;
      end else begin
	if(!bcnt[11]) bcnt <= bcnt + 12'd1;

	if(sub == 8'd0) begin                   // STATUS
	  if(bcnt == 12'd0) spi_dout <= st1;
	  if(bcnt == 12'd1) spi_dout <= st2;
	  if(bcnt == 12'd2) spi_dout <= ctrl;
	end

	if(sub == 8'd1 && put_ok) begin         // RX_PUT
	  if(bcnt == 12'd0) len[10:8] <= spi_din[2:0];
	  if(bcnt == 12'd1) len[7:0]  <= spi_din;
	  if(bcnt >= 12'd15 && bcnt == { 1'b0, len } + 12'd1) begin
	    rx_tail <= rx_tail + 1'd1;
	    put_ok  <= 1'b0;
	  end
	end

	if(sub == 8'd4) begin                   // INFO
	  if(bcnt == 12'd0) link <= spi_din[0];
	  if(bcnt >= 12'd1 && bcnt <= 12'd6)
	    mac <= { mac[39:0], spi_din };
	end
      end
    end

    // cpu register writes, after the MCU side so that a ring reset wins
    // over a pointer update of the MCU in the same cycle
    if(cpu_wr && sel_reg) begin
      case(cpu_addr[4:1])
	4'h3: if(rx_count != 0) begin           // RXACK
	   rx_head <= rx_head + 1'd1;
	   if(rx_full) mcu_int <= 1'b1;
	end
	4'h4: if(tx_free != 0) begin            // TXGO
	   tx_tail <= tx_tail + 1'd1;
	   mcu_int <= 1'b1;
	end
	4'h5: intena <= cpu_din[1:0];
	4'h6: begin
	   ctrl <= { 1'b0, cpu_din[6:0] };
	   mcu_int <= 1'b1;
	   if(cpu_din[7]) begin
	      rx_head <= 0;
	      rx_tail <= 0;
	      tx_head <= 0;
	      tx_tail <= 0;
	      put_ok  <= 1'b0;
	   end
	end
	default: ;
      endcase
    end
  end
end

endmodule
