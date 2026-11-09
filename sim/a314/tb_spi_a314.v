`timescale 1ns/100ps
// a314_cp + a314_host + the real mcu_spi.v at bit level (19.2 MHz): the Companion (SPI master) as
// the Pi of the A314, the Amiga side as in tb_a314_cp.v. SPI target 6.
module tb_spi_a314;
    integer sp_gap = 100;       // ns between two bytes (0 = block transfer)
    integer sp_half = 26;      // ns, 19.2 MHz
    parameter CYC = 40, GAP = 3;
    localparam AW = 13;
    localparam [1:0] REG_SRAM = 0, REG_IRQ = 1, REG_ADDR_LO = 2, REG_ADDR_HI = 3;

    reg clk = 0, rst = 1;
    always #17.5 clk = ~clk;

    integer errors = 0, checks = 0;
    task check(input ok, input [8*48-1:0] msg);
        begin checks = checks + 1;
              if (!ok) begin errors = errors + 1; $display("ERROR: %0s (t=%0t)", msg, $time); end end
    endtask
    task clk1; begin @(posedge clk); #1; end endtask

    // ---- DUT: core side
    reg        a_sel = 0, a_end = 0, a_we = 0;
    reg  [1:0] a_reg = 0;
    reg  [7:0] a_din = 0;
    wire [7:0] a_dout;
    wire       int6, pi_irq, irq;
    wire [AW-1:0] h_addr; wire h_we, h_irq_we; wire [7:0] h_wdata, h_irq_data, h_rdata;

    a314_cp #(.AW(AW)) cp (
        .clk(clk), .reset(rst),
        .a_sel(a_sel), .a_end(a_end), .a_we(a_we), .a_reg(a_reg), .a_din(a_din), .a_dout(a_dout),
        .int6(int6),
        .h_addr(h_addr), .h_we(h_we), .h_wdata(h_wdata), .h_rdata(h_rdata),
        .h_irq_we(h_irq_we), .h_irq_data(h_irq_data), .pi_irq(pi_irq)
    );

    reg        ss = 0, sck = 0, mosi = 0;
    initial begin #50 ss = 1; end            // first rising edge of SS (resets the bit counters)
    wire       miso, a314_strobe, mcu_start;
    wire [7:0] mcu_dout, a314_din;
    wire       s_sys, s_hid, s_osd, s_sdc;
    mcu_spi mcu (
        .clk(clk), .reset(rst),
        .spi_io_ss(ss), .spi_io_clk(sck), .spi_io_din(mosi), .spi_io_dout(miso),
        .mcu_sys_strobe(s_sys), .mcu_hid_strobe(s_hid), .mcu_osd_strobe(s_osd), .mcu_sdc_strobe(s_sdc),
        .mcu_a314_strobe(a314_strobe),
        .mcu_start(mcu_start), .mcu_dout(mcu_dout),
        .mcu_sys_din(8'h00), .mcu_hid_din(8'h00), .mcu_osd_din(8'h00), .mcu_sdc_din(8'h00),
        .mcu_a314_din(a314_din)
    );
    a314_host #(.AW(AW)) host (
        .clk(clk), .reset(rst),
        .data_strobe(a314_strobe), .data_start(mcu_start), .data_in(mcu_dout), .data_out(a314_din),
        .irq(irq),
        .h_addr(h_addr), .h_we(h_we), .h_wdata(h_wdata), .h_rdata(h_rdata),
        .h_irq_we(h_irq_we), .h_irq_data(h_irq_data), .pi_irq(pi_irq)
    );

    // ---- Amiga bus
    task acc(input we, input [1:0] r, input [7:0] d, output [7:0] v);
        begin
            a_sel = 1; a_we = we; a_reg = r; a_din = d;
            repeat (CYC - 1) clk1;
            a_end = 1; v = a_dout; clk1;
            a_sel = 0; a_end = 0; a_we = 0; a_din = 8'hxx;
            repeat (GAP) clk1;
        end
    endtask
    task wreg(input [1:0] r, input [7:0] d); reg [7:0] dummy; begin acc(1, r, d, dummy); end endtask
    task rreg(input [1:0] r, output [7:0] v); begin acc(0, r, 8'hxx, v); end endtask
    task set_ptr(input [15:0] a); begin wreg(REG_ADDR_LO, a[7:0]); wreg(REG_ADDR_HI, a[15:8]); end endtask

    // ---- SPI master (Companion)
    reg [7:0] rep;
    reg [7:0] rx [0:2047];
    reg [7:0] tx [0:2047];
    reg open_tr = 0;
    task bits(input [7:0] b);
        integer i;
        begin
            for (i = 7; i >= 0; i = i - 1) begin
                #(sp_half) sck = 1; mosi = b[i];
                #(sp_half) rep[i] = miso; sck = 0;
            end
            #(sp_gap);
        end
    endtask
    task xfer(input [7:0] b, input first);
        begin
            if (first) begin
                if (open_tr) begin ss = 1; #200; end
                ss = 0; open_tr = 1; #100;
                bits(8'd6);                           // target A314
            end
            bits(b);
        end
    endtask
    task spi_end; begin ss = 1; open_tr = 0; #200; end endtask

    reg [7:0] st;
    task spi_status; begin xfer(8'd0, 1); xfer(8'd0, 0); st = rep; spi_end; end endtask
    task spi_irq(input [7:0] v); begin xfer(8'd3, 1); xfer(v, 0); spi_end; clk1; clk1; end endtask
    task spi_read(input [15:0] a, input integer n);            // -> rx[0..n-1]
        integer i;
        begin
            xfer(8'd1, 1); xfer(a[15:8], 0); xfer(a[7:0], 0); xfer(8'd0, 0);
            for (i = 0; i < n; i = i + 1) begin xfer(8'd0, 0); rx[i] = rep; end
            spi_end;
        end
    endtask
    task spi_write(input [15:0] a, input integer n);           // tx[0..n-1] ->
        integer i;
        begin
            xfer(8'd2, 1); xfer(a[15:8], 0); xfer(a[7:0], 0);
            for (i = 0; i < n; i = i + 1) xfer(tx[i], 0);
            spi_end; clk1; clk1;
        end
    endtask

    integer i, n;
    reg [7:0] v, v2;
    integer t0;

    initial begin
        repeat (4) clk1; rst = 0; clk1;

        $display("S1 id and status");
        xfer(8'd4, 1); xfer(0, 0); xfer(0, 0); v = rep; xfer(0, 0); v2 = rep; xfer(0, 0); spi_end;
        check(v === 8'hA3 && v2 === 8'd1 && rep === AW, "ID A3, version 1, AW");
        spi_status; check(st === 8'h00, "status idle");

        $display("S2 probe through SPI (Companion side) and Amiga side");
        wreg(REG_ADDR_HI, 8'h02); wreg(REG_ADDR_LO, 8'd6); wreg(REG_SRAM, 8'h99); wreg(REG_SRAM, 8'hbd);
        spi_read(16'd518, 2); check(rx[0] === 8'h99 && rx[1] === 8'hbd, "Companion reads 99 BD at 518");
        spi_read(16'd0, 1);   // restart at address 0 after a read of two bytes: address is set by every command
        tx[0] = 8'h5a; spi_write(16'd520, 1); set_ptr(520); rreg(REG_SRAM, v); check(v === 8'h5a, "single byte write");

        $display("S3 interrupt bits");
        wreg(REG_IRQ, 8'h82);
        check(irq === 1'b1 && int6 === 1'b0, "set_pi_irq -> irq line");
        spi_status; check(st === 8'h01, "STATUS shows pi_irq");
        spi_irq(8'h02);
        check(irq === 1'b0, "Companion clears pi_irq");
        spi_irq(8'h81);
        check(int6 === 1'b1 && irq === 1'b0, "Companion raises INT6");
        rreg(REG_IRQ, v); check(v === 8'h01, "Amiga sees the interrupt");
        wreg(REG_IRQ, 8'h01); check(int6 === 1'b0, "Amiga clears it");
        spi_irq(8'h81); spi_irq(8'h01); check(int6 === 1'b0, "Companion can clear INT6 too");

        $display("S4 frame Amiga -> Companion (1514 bytes)");
        set_ptr(520); for (i = 0; i < 1514; i = i + 1) wreg(REG_SRAM, (i * 7 + 3) & 8'hff);
        t0 = $time; spi_read(16'd520, 1514);
        $display("   SPI read of 1514 bytes: %0d us", ($time - t0) / 1000);
        n = 0; for (i = 0; i < 1514; i = i + 1) if (rx[i] !== ((i * 7 + 3) & 8'hff)) n = n + 1;
        check(n == 0, "frame arrives at the Companion");

        $display("S5 frame Companion -> Amiga (1514 bytes), last buffer at the end of the RAM");
        for (i = 0; i < 1514; i = i + 1) tx[i] = (i * 13 + 5) & 8'hff;
        t0 = $time; spi_write(16'd8192 - 16'd1518, 1514);
        $display("   SPI write of 1514 bytes: %0d us", ($time - t0) / 1000);
        set_ptr(16'd8192 - 16'd1518);
        n = 0; for (i = 0; i < 1514; i = i + 1) begin rreg(REG_SRAM, v); if (v !== tx[i]) n = n + 1; end
        check(n == 0, "frame arrives at the Amiga");

        $display("S6 ring: CONNECT 'ethernet' from the Amiga, answer from the Companion");
        set_ptr(16'd512); for (i = 0; i < 4; i = i + 1) wreg(REG_SRAM, 8'h00);     // clear_cap
        // Amiga: header len 8, type 4, stream 1 + name at a2r offset 0
        set_ptr(16'd0);
        wreg(REG_SRAM, 8'd8); wreg(REG_SRAM, 8'd4); wreg(REG_SRAM, 8'd1);
        for (i = 0; i < 8; i = i + 1) wreg(REG_SRAM, "ethernet" >> (8 * (7 - i)));
        set_ptr(16'd514); wreg(REG_SRAM, 8'd11);        // a2r_tail
        wreg(REG_IRQ, 8'h82);
        check(irq === 1'b1, "irq line");
        spi_read(16'd512, 4);                           // r2a_tail, a2r_head, a2r_tail, r2a_head
        check(rx[1] === 8'd0 && rx[2] === 8'd11, "cap seen by the Companion");
        spi_read(16'd0, 11);
        n = 0; for (i = 0; i < 8; i = i + 1) if (rx[3 + i] !== ("ethernet" >> (8 * (7 - i)) & 8'hff)) n = n + 1;
        check(rx[0] === 8'd8 && rx[1] === 8'd4 && rx[2] === 8'd1 && n == 0, "CONNECT packet");
        tx[0] = 8'd11; spi_write(16'd513, 1);           // a2r_head = 11
        spi_irq(8'h02);
        check(irq === 1'b0, "pi_irq cleared");
        tx[0] = 8'd1; tx[1] = 8'd5; tx[2] = 8'd1; tx[3] = 8'd0;   // CONNECT_RESPONSE, result 0
        spi_write(16'd256, 4);
        tx[0] = 8'd4; spi_write(16'd512, 1);            // r2a_tail = 4
        spi_irq(8'h81);
        check(int6 === 1'b1, "INT6");
        rreg(REG_IRQ, v); check(v === 8'h01, "IntServer");
        wreg(REG_IRQ, 8'h01);
        set_ptr(16'd512); rreg(REG_SRAM, v); check(v === 8'd4, "Amiga reads r2a_tail");
        set_ptr(16'd256); n = 0;
        for (i = 0; i < 4; i = i + 1) begin
            rreg(REG_SRAM, v);
            if (v !== (i == 0 ? 8'd1 : i == 1 ? 8'd5 : i == 2 ? 8'd1 : 8'd0)) n = n + 1;
        end
        check(n == 0, "CONNECT_RESPONSE at the Amiga");

        $display("S7 Companion reads while the Amiga writes elsewhere");
        for (i = 0; i < 600; i = i + 1) tx[i] = (i ^ 8'h5a) & 8'hff;
        spi_write(16'd1000, 600);
        fork
            begin : amiga_p
                set_ptr(16'd4000);
                for (i = 0; i < 100; i = i + 1) wreg(REG_SRAM, i + 1);
            end
            begin : comp_p
                spi_read(16'd1000, 600);
            end
        join
        n = 0; for (i = 0; i < 600; i = i + 1) if (rx[i] !== ((i ^ 8'h5a) & 8'hff)) n = n + 1;
        check(n == 0, "Companion read undisturbed");
        spi_read(16'd4000, 100); n = 0;
        for (i = 0; i < 100; i = i + 1) if (rx[i] !== ((i + 1) & 8'hff)) n = n + 1;
        check(n == 0, "Amiga write undisturbed");

        if (errors == 0) $display("PASS (%0d checks)", checks); else $display("FAIL: %0d errors", errors);
        $finish;
    end
    initial begin #3000000000; $display("FAIL: time limit"); $finish; end
endmodule
