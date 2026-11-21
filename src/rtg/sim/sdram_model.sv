// pin level behavioural model of the 8MB tang nano 20k sdram (2 banks, 11 row, 8 col, 32 bit, CL2)
// models only what the controller needs, flags protocol violations
`timescale 1ns/1ps
module sdram_model (
  input  wire        clk,
  input  wire        cke, cs_n, ras_n, cas_n, we_n,
  input  wire [10:0] addr,
  input  wire [1:0]  ba,
  input  wire [3:0]  dqm,
  input  wire [31:0] dq_in,    // value driven by controller (only valid when dq_oe)
  input  wire        dq_oe,    // controller drives bus
  output reg  [31:0] dq_out,
  output reg         dq_drv    // model drives bus
);
  reg [31:0] mem [0:(1<<21)-1];
  reg [10:0] row [0:1];
  reg        open_ [0:1];
  reg [2:0]  bl;
  reg [2:0]  cl;
  integer    errors = 0;
  integer    reads = 0, writes = 0, refreshes = 0;
  // read pipeline
  reg        rd_pend;   // read command seen, data starts next edge
  reg [20:0] rd_base;
  reg [1:0]  rd_start;
  reg [2:0]  rd_beat;
  reg        rd_act;
  wire [2:0] cmd = {ras_n, cas_n, we_n};
  localparam NOP=3'b111, ACT=3'b011, RD=3'b101, WR=3'b100, PRE=3'b010, REF=3'b001, MRS=3'b000, BST=3'b110;
  integer i;
  initial begin
        open_[0]=0; open_[1]=0; dq_drv=0; dq_out=0; rd_pend=0; rd_act=0; bl=0; cl=2;
  end
  function [20:0] wa(input [1:0] b, input [7:0] col);
    wa = {b, row[b], col};
  endfunction
  always @(posedge clk) if (cke) begin
    // data output pipeline: command at edge E1, beat0 is driven after E2, beat k after E(2+k)
    dq_drv <= 0;
    if (rd_act) begin
      dq_out <= mem[{rd_base[20:2], 2'(rd_start + rd_beat[1:0])}];
      dq_drv <= 1;
      if (rd_beat == (bl==0 ? 0 : (1<<bl)-1)) rd_act <= 0; else rd_beat <= rd_beat + 1;
    end
    if (!cs_n) begin
      case (cmd)
        ACT: begin
          if (open_[ba]) begin errors=errors+1; $display("%t SDRAM: ACTIVE to open bank %0d", $time, ba); end
          open_[ba] <= 1; row[ba] <= addr;
        end
        RD: begin
          if (!open_[ba]) begin errors=errors+1; $display("%t SDRAM: READ closed bank", $time); end
          reads = reads + 1;
          // start address aligned to burst, sequential
          rd_base <= wa(ba, addr[7:0]);
          rd_start <= addr[1:0];
          rd_act <= 1; rd_beat <= 0;
          if (addr[10]) open_[ba] <= 0;
        end
        WR: begin
          if (!open_[ba]) begin errors=errors+1; $display("%t SDRAM: WRITE closed bank", $time); end
          writes = writes + 1;
          if (!dq_oe) begin errors=errors+1; $display("%t SDRAM: WRITE without data", $time); end
          if (!dqm[0]) mem[wa(ba,addr[7:0])][7:0]   <= dq_in[7:0];
          if (!dqm[1]) mem[wa(ba,addr[7:0])][15:8]  <= dq_in[15:8];
          if (!dqm[2]) mem[wa(ba,addr[7:0])][23:16] <= dq_in[23:16];
          if (!dqm[3]) mem[wa(ba,addr[7:0])][31:24] <= dq_in[31:24];
          if (addr[10]) open_[ba] <= 0;
        end
        PRE: begin if (addr[10]) begin open_[0]<=0; open_[1]<=0; end else open_[ba]<=0; end
        REF: begin
          refreshes = refreshes + 1;
          if (open_[0]|open_[1]) begin errors=errors+1; $display("%t SDRAM: REFRESH with open bank", $time); end
        end
        MRS: begin bl <= addr[2:0]==3'b000 ? 0 : addr[2:0]==3'b001 ? 1 : addr[2:0]==3'b010 ? 2 : 3; cl <= addr[6:4]; end
        default: ;
      endcase
    end
  end
endmodule
