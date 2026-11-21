/*
    mcu_spi.v
 
    SPI version of MCU interface 
*/

module mcu_spi (
  input        clk,
  input        reset,

  // SPI interface to MCU
  input        spi_io_ss,
  input        spi_io_clk,
  input        spi_io_din,
  output reg   spi_io_dout,

  // byte interface to the various core components
  output       mcu_sys_strobe, // byte strobe for system control target  
  output       mcu_hid_strobe, // byte strobe for HID target  
  output       mcu_osd_strobe, // byte strobe for OSD target
  output       mcu_sdc_strobe, // byte strobe for SD card target
  output       mcu_start,
  input  [7:0] mcu_sys_din,
  input  [7:0] mcu_hid_din,
  input  [7:0] mcu_osd_din,
  input  [7:0] mcu_sdc_din,
`ifdef ENABLE_NANOPORT
  // network card (nanoport.v), target 5
  output       mcu_net_strobe,
  input  [7:0] mcu_net_din,
  // TX frame read out in the spi clock domain (sub command 2)
  output       net_sck_rd,
  output [10:0] net_sck_idx,
  input  [7:0] net_sck_q,
`endif
  output [7:0] mcu_dout
);
   
// SPI runs in MODE1 
// -> idle state of data is low
// -> data is setup on rising clock edge
// -> data is read on falling clock edge

// bit/byte counter
reg [3:0] spi_cnt;

reg [7:0] spi_data_in;
reg [6:0] spi_sr_in;
reg spi_data_in_ready;

`ifdef ENABLE_NANOPORT
// Bulk reads with back to back bytes cannot be served from the clk domain:
// the reply byte would change while it is being shifted out. The nanoport
// TX data is therefore fetched and shifted entirely in the spi clock domain.
reg [11:0] net_bcnt;   // byte index within the transaction
reg	   net_tgt;    // byte 0 was target 5
reg	   net_get;    // byte 1 was sub command 2 (TX_GET)
reg [6:0]  net_sr;
assign net_sck_rd  = (net_get || (net_tgt && net_bcnt == 12'd1)) && spi_cnt[2:0] == 3'd4;
assign net_sck_idx = net_bcnt[10:0] - 11'd1;
`endif

// read data on falling edge of spi clock
always @(negedge spi_io_clk or posedge spi_io_ss) begin
    if(spi_io_ss) begin
        spi_cnt <= 4'd0;
`ifdef ENABLE_NANOPORT
        net_bcnt <= 12'd0;
        net_tgt <= 1'b0;
        net_get <= 1'b0;
`endif
    end else begin
        // lower 3 bits cound bits, upper 8 bits count bytes
        spi_cnt <= spi_cnt + 4'd1;

        // shift bit in
        spi_sr_in <= { spi_sr_in[5:0], spi_io_din };

        // byte ready?
        if(spi_cnt[2:0] == 3'd7) begin
            // latch byte and raise ready flag
            spi_data_in <= { spi_sr_in, spi_io_din };
            spi_data_in_ready <= 1'b1;
`ifdef ENABLE_NANOPORT
            if(!net_bcnt[11]) net_bcnt <= net_bcnt + 12'd1;
            if(net_bcnt == 12'd0) net_tgt <= ({ spi_sr_in, spi_io_din } == 8'd5);
            if(net_bcnt == 12'd1) net_get <= net_tgt && ({ spi_sr_in, spi_io_din } == 8'd2);
`endif
        end

        // Clear data ready at bit 3. If the reading side
        // runs at 32 Mhz, this will work up to 64 MHz
        // SPI clock. At higher clocks the word width must 
        // be increased.
        if(spi_cnt[2:0] == 3'd3)
            spi_data_in_ready <= 1'b0;
    end
end // always @ (negedge spi_io_clk or posedge spi_io_ss)
   
// bring received byte into local clock domain
  
reg spi_in_strobe;
reg [7:0] spi_target;
assign mcu_sys_strobe = spi_in_strobe && spi_target == 8'd0;
assign mcu_hid_strobe = spi_in_strobe && spi_target == 8'd1;
assign mcu_osd_strobe = spi_in_strobe && spi_target == 8'd2; 
assign mcu_sdc_strobe = spi_in_strobe && spi_target == 8'd3; 
`ifdef ENABLE_NANOPORT
assign mcu_net_strobe = spi_in_strobe && spi_target == 8'd5;
`endif

reg [3:0] spi_in_cnt;
reg [7:0] spi_in_data;
assign mcu_start = spi_in_cnt == 2;  
assign mcu_dout = spi_in_data;
     
always @(posedge clk) begin
   reg [1:0] spi_data_in_readyD;
   spi_data_in_readyD <= { spi_data_in_readyD[0], spi_data_in_ready };
   
   if(spi_io_ss)
      spi_in_cnt <= 4'd0;
   
   if(spi_data_in_readyD == 2'b01) begin
      // incoming SPI byte is now in local clock domain

      // first byte is target id. Else send external trigger
      if(spi_in_cnt == 4'd0)
        spi_target <= spi_data_in;
      else begin      
        spi_in_strobe <= 1'b1;
        spi_in_data <= spi_data_in;
      end
	 
      if(spi_in_cnt != 4'd15)
        spi_in_cnt <= spi_in_cnt + 4'd1;
   end else
     spi_in_strobe <= 1'b0;
end

wire [7:0] in_byte = 
	   (spi_target == 8'd0)?mcu_sys_din:
	   (spi_target == 8'd1)?mcu_hid_din:
	   (spi_target == 8'd2)?mcu_osd_din:
	   (spi_target == 8'd3)?mcu_sdc_din:
`ifdef ENABLE_NANOPORT
	   (spi_target == 8'd5)?mcu_net_din:
`endif
	   8'h00;   
   
// setup data on rising edge of spi clock
always @(posedge spi_io_clk or posedge spi_io_ss) begin
    if(spi_io_ss) begin
       spi_io_dout <= 1'b0; // bl616 EN_CHIP fix
    end else begin
`ifdef ENABLE_NANOPORT
       if(net_get) begin
	  // byte n carries TX data byte n-2, fetched at bit 4 of byte n-1
	  if(spi_cnt[2:0] == 3'd0) begin
	     spi_io_dout <= net_sck_q[7];
	     net_sr <= net_sck_q[6:0];
	  end else begin
	     spi_io_dout <= net_sr[6];
	     net_sr <= { net_sr[5:0], 1'b0 };
	  end
       end else
`endif
       spi_io_dout <= in_byte[~spi_cnt[2:0]];
    end
end

endmodule // osd_u8g2
