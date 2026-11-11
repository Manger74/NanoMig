module sprite_ram #(
  parameter BRAM = 0   // 1: one block ram instead of 8 distributed RAM16 (DENISE_SPRITE_BRAM)
) (
  // Port write
  input  wire        clk,
  input  wire        wea,
  input  wire  [3:0] addra,
  input  wire [15:0] dina,

  // Port read
  input  wire  [2:0] addrb,
  output wire [31:0] doutb
);

// The low half (bit 15:0) holds the DATA (A) words, the high half the DATB
// (B) words. The shifter loads shifta (A) from doutb[15:0] and shiftb (B)
// from doutb[31:16], so A has to be in the low half

generate if (BRAM) begin : g_bram

// 8x32 block ram, the two 16 bit halves are written separately (byte
// enables). Same latency as below: address in, data one clock later
(* ram_style = "block", syn_ramstyle = "block_ram" *)
reg [31:0] mem [0:7];
reg [31:0] q;
assign doutb = q;

always @(posedge clk) begin
  if (wea && !addra[0])
    mem[addra[3:1]][15:0]  <= dina;
  if (wea &&  addra[0])
    mem[addra[3:1]][31:16] <= dina;
end

always @(posedge clk)
  q <= mem[addrb];

end else begin : g_dist

reg [15:0] mem0 [0:7];
reg [15:0] mem1 [0:7];

reg [2:0] addrb_r;

assign doutb = {mem1[addrb_r], mem0[addrb_r]};

always @(posedge clk) begin
  if (wea && !addra[0])
    mem0[addra[3:1]] <= dina;
  if (wea &&  addra[0])
    mem1[addra[3:1]] <= dina;
end

always @(posedge clk) begin
  addrb_r <= addrb;
end

end endgenerate

endmodule
