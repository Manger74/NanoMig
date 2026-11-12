module amigaclks (
	// System clocks
	input clk_in,
	output clk_7m,
	output clk_28m,
	output clk_85m,
	output clk_sdram,
	output locked,
	// video clocks
	// 2'b01: 28.5MHz pixel clock (native Amiga video, default)
	// 2'b10: 39.9MHz pixel clock (800x600@60)
	// 2'b11: 74.1MHz pixel clock (1280x720@60)
	// 2'b00: 57MHz pixel clock (former RTG setting)
	input [1:0] vidmode,
	output clk_tmds,
	output clk_pixel,
	output video_locked
);


// Video clocks
wire clk_28_i;

assign clk_28m = clk_28_i;

rPLL sysclk_inst (
    .CLKOUT(clk_85m),
    .LOCK(locked),
    .CLKOUTP(clk_sdram),
    .CLKOUTD(clk_7m),
    .CLKOUTD3(clk_28_i),
    .RESET(1'b0),
    .RESET_P(1'b0),
    .CLKIN(clk_in),
    .CLKFB(1'b0),
    .FBDSEL(6'b0000000),
    .IDSEL(6'b0000000),
    .ODSEL(6'b0000000),
    .PSDA(4'b0000),
    .DUTYDA(4'b0000),
    .FDLY(4'b0000)
);

defparam sysclk_inst.FCLKIN = "27";
defparam sysclk_inst.DYN_IDIV_SEL = "false";
defparam sysclk_inst.IDIV_SEL = 5;
defparam sysclk_inst.DYN_FBDIV_SEL = "false";
defparam sysclk_inst.FBDIV_SEL = 18;
defparam sysclk_inst.DYN_ODIV_SEL = "false";
defparam sysclk_inst.ODIV_SEL = 8;
defparam sysclk_inst.PSDA_SEL = "1100";
defparam sysclk_inst.DYN_DA_EN = "false";
defparam sysclk_inst.DUTYDA_SEL = "1000";
defparam sysclk_inst.CLKOUT_FT_DIR = 1'b1;
defparam sysclk_inst.CLKOUTP_FT_DIR = 1'b1;
defparam sysclk_inst.CLKOUT_DLY_STEP = 0;
defparam sysclk_inst.CLKOUTP_DLY_STEP = 0;
defparam sysclk_inst.CLKFB_SEL = "internal";
defparam sysclk_inst.CLKOUT_BYPASS = "false";
defparam sysclk_inst.CLKOUTP_BYPASS = "false";
defparam sysclk_inst.CLKOUTD_BYPASS = "false";
defparam sysclk_inst.DYN_SDIV_SEL = 12;
defparam sysclk_inst.CLKOUTD_SRC = "CLKOUT";
defparam sysclk_inst.CLKOUTD3_SRC = "CLKOUT";
defparam sysclk_inst.DEVICE = "GW2AR-18C";


// Dynamic divider codes of the tmds rPLL (input 28.5MHz, IDIV=1):
//   FBDSEL = 64 - FBDIV   (x5 = 111011, x10 = 110110 are the codes already used
//                          here, x7 and x13 follow the same rule)
//   ODSEL  = 111110 -> ODIV 4, 111111 -> ODIV 2
// TMDS clock = 28.5MHz * FBDIV, VCO = TMDS clock * ODIV (must stay in 500..1250MHz)
//
//   vidmode  FBDIV ODIV   VCO     TMDS     pixel (TMDS/5)
//     01       5    4    570.0   142.5     28.50
//     00      10    2    570.0   285.0     57.00
//     10       7    4    798.0   199.5     39.90
//     11      13    2    741.0   370.5     74.10
reg [5:0] fbdsel;
reg [5:0] odsel;

always @(*) begin
    case (vidmode)
        2'b00:   begin fbdsel = 6'b110110; odsel = 6'b111111; end
        2'b10:   begin fbdsel = 6'b111001; odsel = 6'b111110; end
        2'b11:   begin fbdsel = 6'b110011; odsel = 6'b111111; end
        default: begin fbdsel = 6'b111011; odsel = 6'b111110; end   // 2'b01 native
    endcase
end

// The rPLL has to be reset after its dynamic dividers have been changed. The
// reset is derived from clk_28 which does not depend on the tmds PLL. The
// power-up value matches the native setting the PLL is generated for.
reg [1:0] vidmode_q = 2'b01;
reg [4:0] tmds_rst_cnt = 5'd0;
wire      tmds_reset = (tmds_rst_cnt != 5'd0);

always @(posedge clk_28_i) begin
    vidmode_q <= vidmode;
    if (vidmode_q != vidmode)       tmds_rst_cnt <= 5'd31;
    else if (tmds_rst_cnt != 5'd0)  tmds_rst_cnt <= tmds_rst_cnt - 5'd1;
end

wire clk_tmds_i;
wire tmds_lock_i;

// tmds/pixel clocks are only usable once the PLL is locked again after a mode change
assign video_locked = tmds_lock_i & ~tmds_reset;

assign clk_tmds = clk_tmds_i;

CLKDIV clkdiv_inst (
    .CLKOUT(clk_pixel),
    .HCLKIN(clk_tmds_i),
    .RESETN(1'b1),
    .CALIB(1'b0)
);

defparam clkdiv_inst.DIV_MODE = "5";
defparam clkdiv_inst.GSREN = "false";

rPLL tmdsclk_inst (
    .CLKOUT(clk_tmds_i),
    .LOCK(tmds_lock_i),
    .CLKOUTP(),
    .CLKOUTD(),
    .CLKOUTD3(),
    .RESET(tmds_reset),
    .RESET_P(1'b0),
    .CLKIN(clk_28_i),
    .CLKFB(1'b0),
    .FBDSEL(fbdsel),
    .IDSEL(6'b0000000),
    .ODSEL(odsel),
    .PSDA(4'b0000),
    .DUTYDA(4'b0000),
    .FDLY(4'b0000)
);

defparam tmdsclk_inst.FCLKIN = "28.5";
defparam tmdsclk_inst.DYN_IDIV_SEL = "false";
defparam tmdsclk_inst.IDIV_SEL = 0;
defparam tmdsclk_inst.DYN_FBDIV_SEL = "true";
defparam tmdsclk_inst.FBDIV_SEL = 4;
defparam tmdsclk_inst.DYN_ODIV_SEL = "true";
defparam tmdsclk_inst.ODIV_SEL = 4;
defparam tmdsclk_inst.PSDA_SEL = "0000";
defparam tmdsclk_inst.DYN_DA_EN = "true";
defparam tmdsclk_inst.DUTYDA_SEL = "1000";
defparam tmdsclk_inst.CLKOUT_FT_DIR = 1'b1;
defparam tmdsclk_inst.CLKOUTP_FT_DIR = 1'b1;
defparam tmdsclk_inst.CLKOUT_DLY_STEP = 0;
defparam tmdsclk_inst.CLKOUTP_DLY_STEP = 0;
defparam tmdsclk_inst.CLKFB_SEL = "internal";
defparam tmdsclk_inst.CLKOUT_BYPASS = "false";
defparam tmdsclk_inst.CLKOUTP_BYPASS = "false";
defparam tmdsclk_inst.CLKOUTD_BYPASS = "false";
defparam tmdsclk_inst.DYN_SDIV_SEL = 2;
defparam tmdsclk_inst.CLKOUTD_SRC = "CLKOUT";
defparam tmdsclk_inst.CLKOUTD3_SRC = "CLKOUT";
defparam tmdsclk_inst.DEVICE = "GW2AR-18C";

endmodule

