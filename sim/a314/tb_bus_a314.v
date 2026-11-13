`timescale 1ns/100ps
// Integration test: the real gary.v, minimig_m68k_bridge.v and amiga_clk.v + a314_cp, wiring taken
// verbatim from minimig.v (minimig_a314_glue.vh). The CPU side is driven with 68000 bus cycles and
// with the chip bus cycles of the TG68K (state machine of cpu_wrapper.v: AS falls at ph1, rises at
// ph2, the address of the next access appears right after AS has risen).
module tb_bus_a314;
    reg clk = 0;
    always #17.5 clk = ~clk;
    reg reset_n = 0, reset = 1;

    wire clk7_en, clk7n_en, c1, c3, cck;
    wire [9:0] eclk;
    amiga_clk ac (.clk_28(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3),
                  .cck(cck), .eclk(eclk), .reset_n(reset_n));
    wire ph1 = !c1 &&  c3;         // as in nanomig.v
    wire ph2 =  c1 && !c3;

    // ---- CPU side
    reg        _as = 1, _uds = 1, _lds = 1, r_w = 1;
    reg [23:1] cpu_addr = 0;
    reg [15:0] cpu_wdata = 0;
    wire       _dtack, cpu_rd, cpu_hwr, cpu_lwr, rd_cyc, cpu_cyc;
    wire [23:1] cpu_address_out;
    wire [15:0] cpu_data_out, cpu_dq, cpu_data_in, gary_data_out;
    reg        dbr = 0;            // Agnus has the bus

    wire sel_a314, sel_reg, sel_cia, dbs, xbs;
    wire [3:0] sel_chip; wire [2:0] sel_slow; wire sel_kick;
    gary GARY1 (
        .cpu_address_in(cpu_address_out), .dma_address_in(20'd0), .ram_address_out(),
        .cpu_data_out(cpu_data_out), .cpu_data_in(gary_data_out),
        .custom_data_out(16'h0000), .custom_data_in(), .ram_data_out(16'h0000), .ram_data_in(),
        .a1k(1'b0), .bootrom(1'b0), .clk(clk), .reset(reset),
        .cpu_rd(cpu_rd), .cpu_hwr(cpu_hwr), .cpu_lwr(cpu_lwr), .cpu_hlt(1'b0),
        .ovl(1'b0), .dbr(dbr), .dbwe(1'b0), .dbs(dbs), .xbs(xbs),
        .memory_config(4'b0101), .ecs(1'b1), .hdc_ena(1'b1),
        .ram_rd(), .ram_hwr(), .ram_lwr(),
        .sel_reg(sel_reg), .sel_chip(sel_chip), .sel_slow(sel_slow), .sel_kick(sel_kick),
        .sel_kick256kmirror(), .sel_cia(sel_cia), .sel_cia_a(), .sel_cia_b(), .sel_rtg(),
        .sel_ide(), .sel_gayle(), .sel_a314(sel_a314), .rom_readonly()
    );

    minimig_m68k_bridge br (
        .clk(clk), .clk7_en(clk7_en), .clk7n_en(clk7n_en), .c1(c1), .c3(c3), .eclk(eclk),
        .vpa(sel_cia), .dbr(dbr), .dbs(dbs), .xbs(xbs), .nrdy(1'b0), .bls(), .cck(cck),
        .memory_config(4'd0), ._as(_as), ._lds(_lds), ._uds(_uds), .r_w(r_w), ._dtack(_dtack),
        .rd(cpu_rd), .hwr(cpu_hwr), .lwr(cpu_lwr), .address(cpu_addr), .address_out(cpu_address_out),
        .data(cpu_dq), .cpudatain(cpu_wdata), .data_out(cpu_data_out), .data_in(cpu_data_in),
        .rd_cyc(rd_cyc), .cyc(cpu_cyc));

    // ---- host side
    reg  [12:0] a314_h_addr = 0;
    reg         a314_h_we = 0, a314_h_irq_we = 0;
    reg  [7:0]  a314_h_wdata = 0, a314_h_irq_data = 0;
    wire [7:0]  a314_h_rdata;
    wire        a314_pi_irq, int6_a314;

    `include "minimig_a314_glue.vh"

    assign cpu_data_in = gary_data_out | a314_out;     // data multiplexer of minimig.v

    // ---- helpers
    integer errors = 0, checks = 0;
    task check(input ok, input [8*56-1:0] msg);
        begin checks = checks + 1;
              if (!ok) begin errors = errors + 1; $display("ERROR: %0s (t=%0t)", msg, $time); end end
    endtask
    task clk1; begin @(posedge clk); #1; end endtask
    task clk7w; begin @(posedge clk); while (!clk7_en) @(posedge clk); #1; end endtask
    task wph1; begin @(posedge clk); while (!ph1) @(posedge clk); #1; end endtask
    task wph2; begin @(posedge clk); while (!ph2) @(posedge clk); #1; end endtask

    integer n_acc = 0, n_end = 0, n_selreg = 0;
    always @(posedge clk) if (a314_end) n_end = n_end + 1;
    // a cycle to $D8xxxx must never reach the custom chip registers
    always @(posedge clk) if (sel_reg && cpu_address_out[23:16] == 8'hD8) n_selreg = n_selreg + 1;

    reg tg = 0;                    // 0 = 68000 cycles, 1 = TG68K chip bus cycles
    integer DLY = 2;               // 68000: the CPU takes the data DLY clocks after DTACK
    reg [23:0] nxt = 24'hD80001;   // TG68K: address that shows up after AS has risen
    reg [7:0] cv;

    task cyc68k(input [23:0] a, input rw, input [7:0] wd);
        integer t;
        begin
            clk7w; cpu_addr = a[23:1]; r_w = rw; cpu_wdata = a[0] ? {~wd, wd} : {wd, ~wd};
            clk7w; _as = 0;
            if (rw) begin _uds = a[0]; _lds = ~a[0]; end
            else begin clk7w; _uds = a[0]; _lds = ~a[0]; end
            t = 0; clk7w;
            while (_dtack !== 1'b0 && t < 200) begin clk7w; t = t + 1; end
            if (t >= 200) check(0, "no DTACK");
            repeat (DLY) clk7w;
            cv = a[0] ? cpu_dq[7:0] : cpu_dq[15:8];
            _as = 1; _uds = 1; _lds = 1;
            clk7w; r_w = 1;
        end
    endtask
    task cyctg(input [23:0] a, input rw, input [7:0] wd);
        integer t; reg waitm;
        begin
            cpu_addr = a[23:1]; cpu_wdata = a[0] ? {~wd, wd} : {wd, ~wd};
            wph1; _as = 0; r_w = rw; _uds = a[0]; _lds = ~a[0];          // stage 0 -> 1
            wph1;                                                         // stage 1 -> 2
            t = 0; waitm = 1;
            while (waitm && t < 200) begin wph2; waitm = _dtack; wph1; t = t + 1; end   // stage 2 -> 3
            if (t >= 200) check(0, "no DTACK (tg)");
            wph2; cv = a[0] ? cpu_dq[7:0] : cpu_dq[15:8];
            _as = 1; r_w = 1; _uds = 1; _lds = 1;                        // stage 3
            clk1; cpu_addr = nxt[23:1]; cpu_wdata = 16'hDEAD;            // chipready: the CPU moves on
            wph1; wph2;                                                   // ready, stage 0
        end
    endtask
    task cyc(input [23:0] a, input rw, input [7:0] wd);
        begin if (tg) cyctg(a, rw, wd); else cyc68k(a, rw, wd);
              if (a[23:16] == 8'hD8) n_acc = n_acc + 1; end
    endtask

    localparam [23:0] CP = 24'hD80001;
    task settle; begin repeat (6) clk1; end endtask    // side effects come when the cycle has ended
    task wreg(input [1:0] r, input [7:0] d); begin cyc(CP + (r << 2), 0, d); settle; end endtask
    task rreg(input [1:0] r, output [7:0] v); begin cyc(CP + (r << 2), 1, 0); v = cv; end endtask
    task set_ptr(input [15:0] a); begin wreg(2, a[7:0]); wreg(3, a[15:8]); end endtask

    task h_wr(input [12:0] a, input [7:0] d); begin a314_h_addr = a; a314_h_wdata = d; a314_h_we = 1; clk1; a314_h_we = 0; end endtask
    task h_rd(input [12:0] a, output [7:0] v); begin a314_h_addr = a; clk1; v = a314_h_rdata; end endtask
    task h_irq(input [7:0] d); begin a314_h_irq_data = d; a314_h_irq_we = 1; clk1; a314_h_irq_we = 0; end endtask

    integer i, n;
    reg [7:0] v, v2;

    task suite;
        begin
            // probe of a314.device
            wreg(3, 8'h02); wreg(2, 8'd6); wreg(0, 8'h99); wreg(0, 8'hbd);
            wreg(2, 8'd7); rreg(0, v); wreg(2, 8'd6); rreg(0, v2);
            check(v === 8'hbd && v2 === 8'h99, "probe");
            h_rd(518, v); h_rd(519, v2); check(v === 8'h99 && v2 === 8'hbd, "probe bytes in the RAM");

            // block write and read, pointer + 1 exactly once per access
            set_ptr(600); for (i = 0; i < 300; i = i + 1) wreg(0, (i * 5 + 1) & 8'hff);
            n = 0; for (i = 0; i < 300; i = i + 1) begin h_rd(600 + i, v); if (v !== ((i * 5 + 1) & 8'hff)) n = n + 1; end
            check(n == 0, "300 bytes written through the port");
            h_rd(900, v); h_wr(900, 8'h5c);
            for (i = 0; i < 300; i = i + 1) h_wr(1000 + i, (i * 3 + 7) & 8'hff);
            set_ptr(1000); n = 0;
            for (i = 0; i < 300; i = i + 1) begin rreg(0, v); if (v !== ((i * 3 + 7) & 8'hff)) n = n + 1; end
            check(n == 0, "300 bytes read through the port");
            // mixed accesses do not move the pointer
            set_ptr(1000); rreg(0, v); rreg(1, v2); wreg(1, 8'h00); rreg(0, v2);
            check(v === 8'h07 && v2 === 8'h0a, "IRQ accesses between two SRAM reads");

            // interrupt bits
            wreg(1, 8'h82); check(a314_pi_irq === 1'b1 && int6_a314 === 1'b0, "set_pi_irq");
            rreg(1, v); check(v === 8'h00, "Amiga reads 0 (spurious)");
            h_irq(8'h81); check(int6_a314 === 1'b1, "INT6");
            rreg(1, v); check(v === 8'h01, "Amiga reads its interrupt");
            wreg(1, 8'h01); check(int6_a314 === 1'b0 && a314_pi_irq === 1'b1, "clear_amiga_irq");
            h_irq(8'h02); check(a314_pi_irq === 1'b0, "Pi clears its bit");

            // accesses to other addresses in between: nothing happens to the A314
            set_ptr(1000); rreg(0, v);
            cyc(24'hDFF006, 1, 0); cyc(24'hDC0001, 1, 0); cyc(24'hD70001, 0, 8'h55); cyc(24'hD90001, 0, 8'h66);
            cyc(24'hBFE001, 1, 0);
            rreg(0, v2); check(v === 8'h07 && v2 === 8'h0a, "other addresses do not touch the pointer");

            // back to back, no pause between the cycles (the byte loops of the driver)
            cyc(CP + 8, 0, 8'h40); cyc(CP + 12, 0, 8'h06);                 // pointer = 1600
            for (i = 0; i < 200; i = i + 1) cyc(CP, 0, (i * 11 + 2) & 8'hff);
            cyc(CP + 8, 0, 8'h40); cyc(CP + 12, 0, 8'h06); n = 0;
            for (i = 0; i < 200; i = i + 1) begin cyc(CP, 1, 0); if (cv !== ((i * 11 + 2) & 8'hff)) n = n + 1; end
            check(n == 0, "200 bytes back to back, written and read");
            cyc(CP + 8, 0, 8'h41); cyc(CP + 12, 0, 8'h06); cyc(CP, 1, 0); v = cv; cyc(CP + 8, 0, 8'h43); cyc(CP, 1, 0);
            check(v === 8'h0d && cv === 8'h23, "pointer write directly followed by a read");

            // even address (upper data strobe) works the same
            set_ptr(1200); cyc(24'hD80000, 0, 8'h3d); settle; h_rd(1200, v); check(v === 8'h3d, "write through the even address");
            set_ptr(1200); cyc(24'hD80000, 1, 0); check(cv === 8'h3d, "read through the even address");
        end
    endtask

    initial begin
        repeat (8) clk1; reset_n = 1; repeat (8) clk1; reset = 0; repeat (4) clk1;

        $display("B1 68000 cycles, data taken 2 clocks after DTACK");
        tg = 0; DLY = 2; suite;
        $display("B2 68000 cycles, slow (6 clocks)");
        DLY = 6; suite;
        $display("B3 TG68K chip bus cycles, next address is the SRAM register");
        tg = 1; nxt = 24'hD80001; suite;
        $display("B4 TG68K chip bus cycles, next address is the IRQ register / another device");
        nxt = 24'hD80005; suite;
        nxt = 24'hDFF09C; suite;
        $display("B5 TG68K cycles while Agnus has the bus now and then");
        nxt = 24'hD80001;
        fork
            begin : agnus repeat (4000) begin repeat (7) clk1; dbr = 1; repeat (3) clk1; dbr = 0; end end
            begin suite; disable agnus; end
        join
        dbr = 0;

        settle; check(n_end == n_acc, "one end pulse per access to $D8xxxx");
        check(n_selreg == 0, "$D8xxxx never selects the custom registers");
        $display("   accesses %0d, end pulses %0d, custom register selects at $D8 %0d", n_acc, n_end, n_selreg);
        if (errors == 0) $display("PASS (%0d checks)", checks); else $display("FAIL: %0d errors", errors);
        $finish;
    end
    initial begin #2000000000; $display("FAIL: time limit"); $finish; end
endmodule
