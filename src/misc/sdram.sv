//
// sdram.sv
//
// sdram controller implementation for the MiSTer SDRAM, the TN20k etc
//
// Copyright (c) 2024 Till Harbaum <till@harbaum.org>
// Copyright (c) 2026 Mateusz Nalewajski <mateusz@nalewajski.pl>
//
// This source file is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This source file is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

// This should work for various RAM sized in 16 or 32 data widths.
//
// Example 1: TN20k internal sdram
// 32 data, 4 dqm, 11 RAS, 2 bank, 8 CAS
//     -> 2^(11+2+8)*(32/8) = 8388608 = 8MB
// address map:  BA:21..20 RAS:19..9 CAS:8..1  data mux: 0
//
// Example 2: MiSTer RAM module
// 16 data, 2 dqm, 13 RAS, 2 bank, 9 CAS
//     -> 2^(13+2+9)*(16/8) = 33554432 = 32MB
// address map:  BA:--  RAS:21..9 CAS:8..0  no data mux

`ifdef YOSYS
`define ITOR(x) $itor(x)
`define RTOI(x) $rtoi(x)
`else
`define ITOR(x) (real'(int'(x)))
`define RTOI(x) (int'(real'(x)))
`endif

`define CEIL(x) `RTOI($ceil(x))

`default_nettype none

module sdram #(
  parameter DATA_WIDTH = 16,
  parameter RAS_WIDTH  = 13,
  parameter CAS_WIDTH  =  9,
  parameter RAM_CLOCK_SPEED  = 85_000_000,
  parameter SYNC_CLOCK_SPEED =  7_080_000,
  parameter CHIP48_BURST = 0,
  parameter SYNC_DELAY = 3,  // delay higher than 4 breaks FX68K build
  parameter ACK_DELAY = 1,
  parameter [20:0] FF_BASE = 21'h1C0000  // field buffer word address ($700000), 128k aligned
) (
  input  wire clk,
  input  wire reset_n,  // init signal after FPGA config to initialize RAM
  output wire ready,    // ram is ready and has been initialized

  inout  wire [DATA_WIDTH-1:0]   sd_data, // 16/32 bit bidirectional data bus
  output reg  [RAS_WIDTH-1:0]    sd_addr, // multiplexed address bus
  output reg  [DATA_WIDTH/8-1:0] sd_dqm,  // two/four byte masks
  output reg  [1:0]              sd_ba,   // four banks

  output reg  sd_cke,  // clock enable
  output wire sd_cs,   // single chip select
  output wire sd_we,   // write enable
  output wire sd_ras,  // row address select
  output wire sd_cas,  // columns address select

  // chipset interface
  input  wire sync,     // chipset synchronization
  input  wire refresh,  // chipset requests a refresh cycle

  input  wire [15:0] din,     // data input from chipset
  output reg  [15:0] dout,    // data output for chipset
  output reg  [47:0] dout48,  // 64-bit read data output for chipset

  input wire [21:0] addr,  // 22 bit word address for 8MB
  input wire  [1:0] ds,    // upper/lower data strobe
  input wire        cs,    // chipset requests read/write
  input wire        we,    // chipset requests write

  // cpu interface
  input  wire [15:0] p2_din,    // data input from cpu
  output reg  [15:0] p2_dout,   // data output to cpu
  output reg  [47:0] p2_dout48, // upper 48 bits of a 64 bit aligned cpu read

  input  wire [22:0] p2_addr,  // 23 bit word address
  input  wire  [1:0] p2_ds,    // upper/lower data strobe
  input  wire        p2_cs,    // cpu requests read/wrie
  input  wire        p2_we,    // cpu requests write
  output wire        p2_ack    // cpu ack

`ifdef ENABLE_FLICKER_FIXER
  ,
  // flicker fixer field buffer, see flickerfix.v. Each job moves ff_len*4
  // words, word n at ff_*_addr+n <-> line buffer ff_*_idx+n, reads in bursts
  // of 8 words (ff_len even), writes in bursts of 4. Only for 32 bit sdram.
  input  wire [6:0]  ff_len,
  input  wire        ff_rd_req,
  input  wire [16:0] ff_rd_addr,
  input  wire [9:0]  ff_rd_idx,
  output reg         ff_rd_ack,
  input  wire        ff_wr_req,
  input  wire [16:0] ff_wr_addr,
  input  wire [9:0]  ff_wr_idx,
  output reg         ff_wr_ack,
  output reg  [9:0]  ff_wb_addr,  // write line buffer, 1 cycle latency
  input  wire [31:0] ff_wb_q,
  output reg  [9:0]  ff_rb_addr,  // read line buffer
  output reg  [31:0] ff_rb_d,
  output reg         ff_rb_we
`endif
);

localparam WIDTH32 = (DATA_WIDTH == 32);

// 000 = 1, 001 = 2, 010 = 4, 011 = 8
localparam BURST_LENGTH   = CHIP48_BURST ? 3'b010 : 3'b000;
localparam ACCESS_TYPE    = 1'b0;    // 0 = sequential, 1 = interleaved
localparam CAS_LATENCY    = 3'd2;    // 2/3 allowed
localparam OP_MODE        = 2'b00;   // only 00 (standard operation) allowed
localparam NO_WRITE_BURST = 1'b1;    // 0 = write burst enabled, 1 = only single access write

localparam MODE = {3'b0, NO_WRITE_BURST, OP_MODE, CAS_LATENCY, ACCESS_TYPE, BURST_LENGTH};

// expand to from 22 to 32 address bits internally to be able to drive bigger rams as well
// and shift one bit for 32 bit data bus as addr[0] is used to multiplex between
// both 16 bit data words
localparam ADDR_BASE = WIDTH32 ? 1 : 0;

wire [31:0]    addr32 = { {(10+ADDR_BASE){1'b0}},    addr[21:ADDR_BASE]};
wire [31:0] p2_addr32 = { {( 9+ADDR_BASE){1'b0}}, p2_addr[22:ADDR_BASE]};

reg addr_0;

localparam real CLOCK_PERIOD_NANO_SEC = 1.0e9 / `ITOR(RAM_CLOCK_SPEED);
localparam real SYNC_PERIOD_NANO_SEC  = 1.0e9 / `ITOR(SYNC_CLOCK_SPEED);

localparam real SETTING_INHIBIT_DELAY_MICRO_SEC = 100;

// tRFC - Min autorefresh period
localparam real SETTING_T_RFC_MIN_AUTOREFRESH_PERIOD_NANO_SEC = 60;

// tRP - Min precharge command period
localparam real SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC = 15;

// 8,192 refresh commands every 64ms = 7.8125us, which we round to 7500ns to make sure we hit them all
localparam real SETTING_REFRESH_TIMER_NANO_SEC = 7500;

// Number of cycles for autorefresh duration
localparam CLOCK_CYCLES_FOR_AUTOREFRESH =
    `CEIL(SETTING_T_RFC_MIN_AUTOREFRESH_PERIOD_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

// Number of cycles after reset until we clear command inhibit and start operation
// We add 100 cycles for good measure
localparam CLOCK_CYCLES_UNTIL_INIT_PRECHARGE = 100 +
    `CEIL(SETTING_INHIBIT_DELAY_MICRO_SEC * 1000.0 / CLOCK_PERIOD_NANO_SEC);

// Number of cycles after reset until we are done with precharge
// We add 10 cycles for good measure
localparam CLOCK_CYCLES_UNTIL_INIT_PRECHARGE_END = 10 + CLOCK_CYCLES_UNTIL_INIT_PRECHARGE +
    `CEIL(SETTING_T_RP_MIN_PRECHARGE_CMD_PERIOD_NANO_SEC / CLOCK_PERIOD_NANO_SEC);

localparam CLOCK_CYCLES_UNTIL_REFRESH1_END = CLOCK_CYCLES_UNTIL_INIT_PRECHARGE_END + CLOCK_CYCLES_FOR_AUTOREFRESH;
localparam CLOCK_CYCLES_UNTIL_REFRESH2_END = CLOCK_CYCLES_UNTIL_REFRESH1_END + CLOCK_CYCLES_FOR_AUTOREFRESH;

// tMRD = 2 - Min number of clock cycles between mode set and normal usage
localparam CLOCK_CYCLES_UNTIL_INIT_DONE = CLOCK_CYCLES_UNTIL_REFRESH2_END + 2;

localparam INIT_COUNTER_MAX   = CLOCK_CYCLES_UNTIL_INIT_DONE;
localparam INIT_COUNTER_WIDTH = $clog2(INIT_COUNTER_MAX + 1);

reg [INIT_COUNTER_WIDTH-1:0] init_counter = 0;

// Number of sync cycles between each autorefresh command
localparam SYNC_CYCLES_PER_REFRESH =
    `CEIL(SETTING_REFRESH_TIMER_NANO_SEC / SYNC_PERIOD_NANO_SEC);

localparam REFRESHCNT_MAX       = SYNC_CYCLES_PER_REFRESH;
localparam REFRESHCNT_MAX_WIDTH = $clog2(REFRESHCNT_MAX + 1);

reg [REFRESHCNT_MAX_WIDTH-1:0] refreshcnt;

// ---------------------------------------------------------------------
// ------------------------ cycle state machine ------------------------
// ---------------------------------------------------------------------

localparam STATE_INIT       = 0;
localparam STATE_RAS        = 1;  // first state in cycle
localparam STATE_RAS_WAIT_0 = 2;
localparam STATE_CAS        = 3;
localparam STATE_CAS_WAIT_0 = 4;
localparam STATE_CAS_WAIT_1 = 5;
localparam STATE_READ_0     = 6;
localparam STATE_READ_1     = 7;
localparam STATE_READ_2     = 8;
localparam STATE_READ_3     = 9;
localparam STATE_LAST       = STATE_READ_3;

localparam STATE_WIDTH = $clog2(STATE_LAST + 1);

reg [STATE_WIDTH-1:0] state;

wire                  sync_i;
reg  [SYNC_DELAY-1:0] sync_d;

always @(posedge clk, negedge reset_n) begin
  if (!reset_n)
    sync_d <= 0;
  else
    sync_d <= {sync_d[SYNC_DELAY-2:0], sync};
end

assign sync_i = sync_d[SYNC_DELAY-1] && !sync_d[SYNC_DELAY-2];
assign ready  = (state != STATE_INIT);

always @(posedge clk, negedge reset_n) begin
  if (!reset_n) begin
    init_counter <= 0;
    state        <= STATE_INIT;

  end else begin
    case (state)
      STATE_INIT: begin
        init_counter <= init_counter + 1;

        if (init_counter == CLOCK_CYCLES_UNTIL_INIT_DONE[INIT_COUNTER_WIDTH-1:0])
          state <= STATE_RAS;
      end
      STATE_RAS:
        if (sync_i) state <= STATE_RAS_WAIT_0;
      STATE_RAS_WAIT_0:
        state <= STATE_CAS;
      STATE_CAS:
        state <= STATE_CAS_WAIT_0;
      STATE_CAS_WAIT_0:
        state <= STATE_CAS_WAIT_1;
      STATE_CAS_WAIT_1:
        state <= STATE_READ_0;
      STATE_READ_0:
        state <= STATE_READ_1;
      STATE_READ_1:
        state <= STATE_READ_2;
      STATE_READ_2:
        state <= STATE_READ_3;
      STATE_READ_3:
        state <= STATE_RAS;
    endcase
  end
end

// ---------------------------------------------------------------------
// ------------------ generate ram control signals ---------------------
// ---------------------------------------------------------------------

// all possible commands
localparam CMD_NOP             = 3'b111;
localparam CMD_ACTIVE          = 3'b011;
localparam CMD_READ            = 3'b101;
localparam CMD_WRITE           = 3'b100;
localparam CMD_BURST_TERMINATE = 3'b110;
localparam CMD_PRECHARGE       = 3'b010;
localparam CMD_AUTO_REFRESH    = 3'b001;
localparam CMD_LOAD_MODE       = 3'b000;

reg [2:0] sd_cmd;   // current command sent to sd ram

// drive control signals according to current command
assign sd_cs  = 1'b0;
assign sd_ras = sd_cmd[2];
assign sd_cas = sd_cmd[1];
assign sd_we  = sd_cmd[0];

reg  [15:0] ram_din;
reg         ram_we;
reg   [1:0] ram_ds;

wire [15:0] ram_dout_lo;
wire [15:0] ram_dout_hi;
wire [15:0] ram_dout;

reg                 sd_dq;
reg [RAS_WIDTH-1:0] sd_addr_cas;

reg p2_ack_i;

`ifdef ENABLE_FLICKER_FIXER
// ---- flicker fixer job engine ----
// One burst per 7 MHz slot, ff_t counts the slot cycles, ACTIVE is on the
// bus in cycle 1, column commands one cycle after they are set:
//   write: 4 single WRITEs set in cycles 2..5, the last with auto precharge
//   read, burst length 1: 8 single READs set in cycles 2..9
//   read, burst length 4: 2 READs set in cycles 2 and 6
// The last READ carries auto precharge, so the bank is idle again in cycle
// 13, in time for the ACTIVE of the next slot. Read data is sampled in
// cycles 5..12, cycle 12 is already the decision cycle of the next slot.
// Mode register and the other ports are not affected.
reg  [1:0]  ff_rqS, ff_wqS;
reg  [6:0]  ff_rcnt, ff_wcnt;    // bursts done in the current job
reg         ff_cyc;              // current slot belongs to the flicker fixer
reg  [3:0]  ff_t;
reg         ff_cwe;              // ... and writes
reg  [CAS_WIDTH-3:0] ff_col;     // column / 4
reg            [1:0] ff_ba;      // bank of the job, the RAS state loads sd_ba with port requests
reg  [7:0]  ff_ix;               // line buffer index / 4
reg  [31:0] ff_wd;               // write data

wire        ff_rpend = ff_rqS[1] != ff_rd_ack;
wire        ff_wpend = ff_wqS[1] != ff_wr_ack;
wire        ff_wsel  = !ff_rpend;  // reads first, they are needed for display
wire [9:0]  ff_off   = ff_wsel ? {1'b0, ff_wcnt, 2'b00} : {ff_rcnt, 3'b000};
wire [16:0] ff_w     = (ff_wsel ? ff_wr_addr : ff_rd_addr) + {7'd0, ff_off};
wire [9:0]  ff_i     = (ff_wsel ? ff_wr_idx  : ff_rd_idx ) + ff_off;
wire [31:0] ff_a32   = {11'd0, FF_BASE | {4'd0, ff_w}};

// column address of beat b (0..7, reads are 8 word aligned)
function [RAS_WIDTH-1:0] ff_cas(input [2:0] b, input ap);
  begin
    ff_cas = {RAS_WIDTH{1'b0}};
    ff_cas[CAS_WIDTH-1:0] = {ff_col[CAS_WIDTH-3:1], ff_col[0] | b[2], b[1:0]};
    ff_cas[10] = ap;
  end
endfunction

always @(posedge clk, negedge reset_n) begin
  if (!reset_n) begin
    ff_rqS <= 2'b00;    ff_wqS <= 2'b00;
    ff_rd_ack <= 1'b0;  ff_wr_ack <= 1'b0;
    ff_rcnt <= 7'd0;    ff_wcnt <= 7'd0;
  end else begin
    ff_rqS <= {ff_rqS[0], ff_rd_req};
    ff_wqS <= {ff_wqS[0], ff_wr_req};
    if (ff_cyc && ff_t == 4'd8) begin   // before the next slot is decided
      if (ff_cwe) begin
        if (ff_wcnt == ff_len - 7'd1) begin ff_wcnt <= 7'd0; ff_wr_ack <= ~ff_wr_ack; end
        else ff_wcnt <= ff_wcnt + 7'd1;
      end else begin
        if (ff_rcnt == {1'b0, ff_len[6:1]} - 7'd1) begin ff_rcnt <= 7'd0; ff_rd_ack <= ~ff_rd_ack; end
        else ff_rcnt <= ff_rcnt + 7'd1;
      end
    end
  end
end
`endif

generate
  if (WIDTH32) begin
    assign ram_dout_lo = sd_data[15: 0];
    assign ram_dout_hi = sd_data[31:16];
    assign ram_dout    = (addr_0 ? ram_dout_lo : ram_dout_hi);
`ifdef ENABLE_FLICKER_FIXER
    assign sd_data     = sd_dq ? (ff_cyc ? ff_wd : {ram_din, ram_din}) : {DATA_WIDTH{1'bz}};
`else
    assign sd_data     = sd_dq ? {ram_din, ram_din} : {DATA_WIDTH{1'bz}};
`endif

  end else begin
    assign ram_dout_lo = sd_data;
    assign ram_dout_hi = sd_data;
    assign ram_dout    = sd_data;
    assign sd_data     = sd_dq ? ram_din : {DATA_WIDTH{1'bz}};
  end
endgenerate

localparam PORT_1       = 2'd0;
localparam PORT_2       = 2'd1;
localparam PORT_REFRESH = 2'd2;
localparam PORT_IDLE    = 2'd3;

reg [1:0] sdram_port;

always @(posedge clk, negedge reset_n) begin
  if (!reset_n)
    sd_cke <= 0;
  else
    sd_cke <= 1;
end

always @(posedge clk) begin
  sd_cmd <= CMD_NOP;
  sd_dq  <= 0;
`ifdef ENABLE_FLICKER_FIXER
  ff_rb_we <= 1'b0;
  if (ff_cyc) begin
    ff_t <= ff_t + 4'd1;
    if (ff_t == 4'd12) ff_cyc <= 1'b0;  // a new slot started below overrides this
  end
`endif

  case (state)
    STATE_INIT: begin
      sdram_port <= PORT_IDLE;
`ifdef ENABLE_FLICKER_FIXER
      ff_cyc     <= 1'b0;
      ff_t       <= 4'd0;
`endif
      refreshcnt <= SYNC_CYCLES_PER_REFRESH[REFRESHCNT_MAX_WIDTH-1:0];

      if (init_counter == CLOCK_CYCLES_UNTIL_INIT_PRECHARGE[INIT_COUNTER_WIDTH-1:0]) begin
        sd_cmd <= CMD_PRECHARGE;
        sd_addr[10] <= 1'b1;
      end else if (init_counter == CLOCK_CYCLES_UNTIL_INIT_PRECHARGE_END[INIT_COUNTER_WIDTH-1:0]) begin
        sd_cmd <= CMD_AUTO_REFRESH;
      end else if (init_counter == CLOCK_CYCLES_UNTIL_REFRESH1_END[INIT_COUNTER_WIDTH-1:0]) begin
        sd_cmd <= CMD_AUTO_REFRESH;
      end else if (init_counter == CLOCK_CYCLES_UNTIL_REFRESH2_END[INIT_COUNTER_WIDTH-1:0]) begin
        sd_cmd  <= CMD_LOAD_MODE;
        sd_addr <= MODE;
      end
    end
    STATE_RAS: begin
      if (cs) begin
        sd_addr <= addr32[RAS_WIDTH+CAS_WIDTH-1:CAS_WIDTH];

        sd_addr_cas[RAS_WIDTH-1:0] <= {RAS_WIDTH{1'b0}};
        sd_addr_cas[CAS_WIDTH-1:0] <= addr32[CAS_WIDTH-1:0];
        sd_addr_cas[10] <= 1'b1;  // precharge

        sd_ba <= addr32[RAS_WIDTH+CAS_WIDTH+1:RAS_WIDTH+CAS_WIDTH];

        ram_ds  <= ds;
        ram_we  <= we;
        ram_din <= din;

        addr_0  <= addr[0];

      end else if (p2_cs) begin
        sd_addr <= p2_addr32[RAS_WIDTH+CAS_WIDTH-1:CAS_WIDTH];

        sd_addr_cas[RAS_WIDTH-1:0] <= {RAS_WIDTH{1'b0}};
        sd_addr_cas[CAS_WIDTH-1:0] <= p2_addr32[CAS_WIDTH-1:0];
        sd_addr_cas[10] <= 1'b1;  // precharge

        sd_ba <= p2_addr32[RAS_WIDTH+CAS_WIDTH+1:RAS_WIDTH+CAS_WIDTH];

        ram_ds  <= p2_ds;
        ram_we  <= p2_we;
        ram_din <= p2_din;

        addr_0 <= p2_addr[0];
      end

      if (sync_i) begin
        if (refreshcnt != 0)
          refreshcnt <= refreshcnt - 1;

        if (cs && !refresh) begin
          sdram_port <= PORT_1;
          sd_cmd     <= CMD_ACTIVE;

        end else if (refreshcnt == 0 || (cs && refresh)) begin
          sdram_port <= PORT_REFRESH;
          sd_cmd     <= CMD_NOP;

          refreshcnt <= SYNC_CYCLES_PER_REFRESH[REFRESHCNT_MAX_WIDTH-1:0];

`ifdef ENABLE_FLICKER_FIXER
        end else if (ff_rpend || ff_wpend) begin
          // above the cpu: the fixer has a deadline every line
          ff_cyc     <= 1'b1;
          ff_t       <= 4'd1;
          ff_cwe     <= ff_wsel;
          ff_col     <= ff_a32[CAS_WIDTH-1:2];
          ff_ix      <= ff_i[9:2];
          sd_addr    <= ff_a32[RAS_WIDTH+CAS_WIDTH-1:CAS_WIDTH];
          sd_ba      <= ff_a32[RAS_WIDTH+CAS_WIDTH+1:RAS_WIDTH+CAS_WIDTH];
          ff_ba      <= ff_a32[RAS_WIDTH+CAS_WIDTH+1:RAS_WIDTH+CAS_WIDTH];
          sd_cmd     <= CMD_ACTIVE;
`endif
        end else if (p2_cs) begin
          sdram_port <= PORT_2;
          sd_cmd     <= CMD_ACTIVE;
        end
      end
`ifdef ENABLE_FLICKER_FIXER
      ff_wb_addr <= {ff_i[9:2], 2'd0};   // first write word, read latency 1
`endif
    end

    STATE_CAS: begin
      sd_addr <= sd_addr_cas;

      case (sdram_port)
        PORT_1: begin
          sd_cmd <= ram_we ? CMD_WRITE : CMD_READ;
          if (ram_we) begin
            sd_dq <= 1;
          end
        end
        PORT_2: begin
          sd_cmd <= ram_we ? CMD_WRITE : CMD_READ;
          if (ram_we) begin
            sd_dq <= 1;
          end
        end
        PORT_REFRESH: begin
          sd_cmd <= CMD_AUTO_REFRESH;
        end
        default: ;
      endcase
    end
    STATE_READ_0: begin
      case (sdram_port)
        PORT_1 : begin
          dout <= ram_dout;
        end
        PORT_2 : begin
          p2_dout <= ram_dout;
        end
        default: ;
      endcase
    end
    STATE_LAST: begin
      sdram_port <= PORT_IDLE;
    end
    default: ;
  endcase

`ifdef ENABLE_FLICKER_FIXER
  if (ff_cyc) begin
    if (ff_cwe) begin
      // write line buffer, 1 cycle latency, word n on the bus in cycle n+3
      if (ff_t <= 4'd3) ff_wb_addr <= {ff_ix, 2'(ff_t)};
      if (ff_t >= 4'd2 && ff_t <= 4'd5) begin
        sd_cmd  <= CMD_WRITE;
        sd_addr <= ff_cas(3'(ff_t - 4'd2), ff_t == 4'd5);
        sd_ba   <= ff_ba;
        ff_wd   <= ff_wb_q;
        sd_dq   <= 1'b1;
      end
    end else begin
      if (CHIP48_BURST ? (ff_t == 4'd2 || ff_t == 4'd6) : (ff_t >= 4'd2 && ff_t <= 4'd9)) begin
        sd_cmd  <= CMD_READ;
        sd_addr <= ff_cas(3'(ff_t - 4'd2), CHIP48_BURST ? ff_t == 4'd6 : ff_t == 4'd9);
        // burst length 1: the READ of cycle 9 is set in the RAS state, which
        // already loads sd_ba for a waiting port request
        sd_ba   <= ff_ba;
      end
      // read data, CAS latency 2
      if (ff_t >= 4'd5) begin
        ff_rb_d    <= sd_data;
        ff_rb_addr <= {ff_ix[7:1], ff_ix[0] | (ff_t >= 4'd9), 2'(ff_t - 4'd5)};
        ff_rb_we   <= 1'b1;
      end
    end
  end
`endif
end

generate
  if (WIDTH32) begin
    always @(posedge clk) begin
      sd_dqm <= 0;

      case (state)
        STATE_CAS: begin
          case (sdram_port)
            PORT_1: if (ram_we) sd_dqm <= (addr_0 ? {2'b11, ram_ds} : {ram_ds, 2'b11});
            PORT_2: if (ram_we) begin
              p2_ack_i <= ~p2_ack_i;
              sd_dqm <= (addr_0 ? {2'b11, ram_ds} : {ram_ds, 2'b11});
            end
            default: ;
          endcase
        end
        STATE_READ_0: begin
          case (sdram_port)
            PORT_1: dout48[47:32] <= ram_dout_lo;
            PORT_2: begin
              if (!ram_we && !CHIP48_BURST) p2_ack_i <= ~p2_ack_i;
              p2_dout48[47:32] <= ram_dout_lo;
            end
            default: ;
          endcase
        end
        STATE_READ_1: begin
          case (sdram_port)
            PORT_1: begin
              if (addr_0)
                dout48[47:16] <= {ram_dout_hi, ram_dout_lo};
              else
                dout48[31: 0] <= {ram_dout_hi, ram_dout_lo};
            end
            PORT_2: begin
              if (addr_0)
                p2_dout48[47:16] <= {ram_dout_hi, ram_dout_lo};
              else
                p2_dout48[31: 0] <= {ram_dout_hi, ram_dout_lo};
            end
            default: ;
          endcase
        end
        STATE_READ_2: begin
          case (sdram_port)
            PORT_1: begin
              if (addr_0)
                dout48[15:0] <= {ram_dout_hi};
              else
                /* no-op */;
            end
            PORT_2: begin
              if (!ram_we && CHIP48_BURST) p2_ack_i <= ~p2_ack_i;
              if (addr_0)
                p2_dout48[15:0] <= {ram_dout_hi};
              else
                /* no-op */;
            end
            default: ;
          endcase
        end
        default: ;
      endcase
    end

  end else begin
    always @(posedge clk) begin
      sd_dqm <= 0;

      case (state)
        STATE_CAS: begin
          case (sdram_port)
            PORT_1: if (ram_we) sd_dqm <= ram_ds;
            PORT_2: if (ram_we) begin
              sd_dqm <= ram_ds;
              p2_ack_i <= ~p2_ack_i;
            end
            default: ;
          endcase
        end
        STATE_READ_0: begin
          case (sdram_port)
            PORT_1: ;
            PORT_2: if (!ram_we && !CHIP48_BURST) p2_ack_i <= ~p2_ack_i;
            default: ;
          endcase
        end
        STATE_READ_1: begin
          case (sdram_port)
            PORT_1: dout48[47:32] <= ram_dout;
            PORT_2: p2_dout48[47:32] <= ram_dout;
            default: ;
          endcase
        end
        STATE_READ_2: begin
          case (sdram_port)
            PORT_1: dout48[31:16] <= ram_dout;
            PORT_2: p2_dout48[31:16] <= ram_dout;
            default: ;
          endcase
        end
        STATE_READ_3: begin
          case (sdram_port)
            PORT_1: dout48[15: 0] <= ram_dout;
            PORT_2: begin
              if (!ram_we && CHIP48_BURST) p2_ack_i <= ~p2_ack_i;
              p2_dout48[15: 0] <= ram_dout;
            end
            default: ;
          endcase
        end
        default: ;
      endcase
    end
  end
endgenerate

generate
  if (ACK_DELAY == 1) begin
    reg p2_ack_d;

    always @(posedge clk)
      p2_ack_d <= p2_ack_i;

    assign p2_ack = p2_ack_d;

  end else if (ACK_DELAY > 1) begin
    reg [ACK_DELAY-1:0] p2_ack_d;

    always @(posedge clk)
      p2_ack_d <= {p2_ack_d[ACK_DELAY-2:0], p2_ack_i};

    assign p2_ack = p2_ack_d[ACK_DELAY-1];

  end else begin
    assign p2_ack = p2_ack_i;
  end
endgenerate

endmodule
`default_nettype wire
// vim:ts=2 sw=2 tw=120 et
