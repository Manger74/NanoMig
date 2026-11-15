`timescale 1ns/100ps
// Testbench for a314_cp: the Amiga side replays the register sequences of a314.device
// (pi_if_cp.c: probe, clear_cap, update_restart_counter, read_pi_cap, write_amiga_cap,
// write_to_a2r, read_from_r2a, IntServer, a314base_write_mem/read_mem), the host side plays
// the Companion. A cycle on the Amiga side is CYC clocks long (slow clockport access),
// side effects at the last one (a_end).
module tb_a314_cp;
    parameter CYC = 40;
    parameter GAP = 3;
    localparam AW = 13;
    localparam [1:0] REG_SRAM = 0, REG_IRQ = 1, REG_ADDR_LO = 2, REG_ADDR_HI = 3;
    localparam [15:0] A2R_BASE = 0, R2A_BASE = 256, CAP_BASE = 512;

    reg clk = 0, rst = 1;
    always #17.5 clk = ~clk;

    reg        a_sel = 0, a_end = 0, a_we = 0;
    reg  [1:0] a_reg = 0;
    reg  [7:0] a_din = 0;
    wire [7:0] a_dout;
    wire       int6, pi_irq;
    reg  [AW-1:0] h_addr = 0;
    reg        h_we = 0, h_irq_we = 0;
    reg  [7:0] h_wdata = 0, h_irq_data = 0;
    wire [7:0] h_rdata;

    a314_cp #(.AW(AW)) dut (
        .clk(clk), .reset(rst),
        .a_sel(a_sel), .a_end(a_end), .a_we(a_we), .a_reg(a_reg), .a_din(a_din), .a_dout(a_dout),
        .int6(int6),
        .h_addr(h_addr), .h_we(h_we), .h_wdata(h_wdata), .h_rdata(h_rdata),
        .h_irq_we(h_irq_we), .h_irq_data(h_irq_data), .pi_irq(pi_irq)
    );

    integer errors = 0, checks = 0;
    task check(input ok, input [8*48-1:0] msg);
        begin
            checks = checks + 1;
            if (!ok) begin errors = errors + 1; $display("ERROR: %0s (t=%0t)", msg, $time); end
        end
    endtask
    task clk1; begin @(posedge clk); #1; end endtask

    // ---------------------------------------------------------------- Amiga bus
    reg [7:0] q;
    task acc(input we, input [1:0] r, input [7:0] d, output [7:0] v);
        begin
            a_sel = 1; a_we = we; a_reg = r; a_din = d;
            repeat (CYC - 1) clk1;
            a_end = 1; v = a_dout;
            clk1;
            a_sel = 0; a_end = 0; a_we = 0; a_din = 8'hxx;
            repeat (GAP) clk1;
        end
    endtask
    task wreg(input [1:0] r, input [7:0] d); reg [7:0] dummy; begin acc(1, r, d, dummy); end endtask
    task rreg(input [1:0] r, output [7:0] v); begin acc(0, r, 8'hxx, v); end endtask
    task set_ptr(input [15:0] a); begin wreg(REG_ADDR_LO, a[7:0]); wreg(REG_ADDR_HI, a[15:8]); end endtask

    // ---------------------------------------------------------------- host (Companion)
    task h_wr(input [AW-1:0] a, input [7:0] d);
        begin h_addr = a; h_wdata = d; h_we = 1; clk1; h_we = 0; end
    endtask
    task h_rd(input [AW-1:0] a, output [7:0] v);
        begin h_addr = a; clk1; v = h_rdata; end       // data valid one clock after the address
    endtask
    task h_irq(input [7:0] d); begin h_irq_data = d; h_irq_we = 1; clk1; h_irq_we = 0; end endtask

    // ---------------------------------------------------------------- driver model
    reg [7:0] buffer [0:2047];      // data of the driver / of the host
    reg [7:0] cap_r2a_tail, cap_a2r_head, cap_a2r_tail, cap_r2a_head;   // struct ComAreaPtrs of the Amiga

    task probe(output found);
        reg [7:0] v;
        begin
            found = 0;
            wreg(REG_ADDR_HI, CAP_BASE >> 8); wreg(REG_ADDR_LO, 6);
            wreg(REG_SRAM, 8'h99); wreg(REG_SRAM, 8'hbd);
            wreg(REG_ADDR_LO, 7);
            rreg(REG_SRAM, v);
            if (v == 8'hbd) begin
                wreg(REG_ADDR_LO, 6);
                rreg(REG_SRAM, v);
                if (v == 8'h99) found = 1;
            end
        end
    endtask

    task read_pi_cap;
        begin set_ptr(CAP_BASE + 0); rreg(REG_SRAM, cap_r2a_tail); rreg(REG_SRAM, cap_a2r_head); end
    endtask
    task write_amiga_cap;
        begin set_ptr(CAP_BASE + 2); wreg(REG_SRAM, cap_a2r_tail); wreg(REG_SRAM, cap_r2a_head); end
    endtask

    task write_mem(input [15:0] address, input integer length);      // a314base_write_mem, data in buffer
        integer i;
        begin set_ptr(address); for (i = 0; i < length; i = i + 1) wreg(REG_SRAM, buffer[i]); end
    endtask
    task read_mem(input [15:0] address, input integer length);        // a314base_read_mem -> buffer
        integer i; reg [7:0] v;
        begin set_ptr(address); for (i = 0; i < length; i = i + 1) begin rreg(REG_SRAM, v); buffer[i] = v; end end
    endtask

    task write_to_a2r(input [7:0] typ, input [7:0] sid, input [7:0] length);   // payload in buffer
        reg [7:0] offset; integer i; reg [7:0] hdr [0:2];
        begin
            hdr[0] = length; hdr[1] = typ; hdr[2] = sid;
            offset = cap_a2r_tail;
            set_ptr(A2R_BASE + offset);
            for (i = 0; i < 3; i = i + 1) begin
                wreg(REG_SRAM, hdr[i]); offset = offset + 1;
                if (offset == 0) set_ptr(A2R_BASE);
            end
            for (i = 0; i < length; i = i + 1) begin
                wreg(REG_SRAM, buffer[i]); offset = offset + 1;
                if (offset == 0) set_ptr(A2R_BASE);
            end
            cap_a2r_tail = offset;
        end
    endtask
    task read_from_r2a(input [7:0] offset_in, input integer length);        // -> buffer
        reg [7:0] offset, v; integer i;
        begin
            offset = offset_in;
            set_ptr(R2A_BASE + offset);
            for (i = 0; i < length; i = i + 1) begin
                rreg(REG_SRAM, v); buffer[i] = v; offset = offset + 1;
                if (offset == 0) set_ptr(R2A_BASE);
            end
        end
    endtask

    // ---------------------------------------------------------------- Companion model of the rings
    reg [7:0] h_cap [0:3];         // r2a_tail, a2r_head, a2r_tail, r2a_head
    reg [7:0] h_pkt [0:255];
    reg [7:0] h_len, h_typ, h_sid;
    task h_read_cap; integer i; begin for (i = 0; i < 4; i = i + 1) h_rd(CAP_BASE + i, h_cap[i]); end endtask
    // take one packet out of A2R (head -> tail), advance a2r_head, clear the Pi's interrupt bit
    task h_take_a2r;
        reg [7:0] head, v; integer i;
        begin
            h_read_cap;
            head = h_cap[1];
            check(head != h_cap[2], "a2r not empty");
            h_rd(A2R_BASE + head, h_len); head = head + 1;
            h_rd(A2R_BASE + head, h_typ); head = head + 1;
            h_rd(A2R_BASE + head, h_sid); head = head + 1;
            for (i = 0; i < h_len; i = i + 1) begin h_rd(A2R_BASE + head, v); h_pkt[i] = v; head = head + 1; end
            h_wr(CAP_BASE + 1, head);
            h_irq(8'h02);                                     // clear pi_irq (bit 7 = 0)
        end
    endtask
    // put a packet (h_pkt) into R2A, advance r2a_tail, interrupt the Amiga
    task h_put_r2a(input [7:0] typ, input [7:0] sid, input [7:0] length);
        reg [7:0] tail; integer i;
        begin
            h_read_cap;
            tail = h_cap[0];
            h_wr(R2A_BASE + tail, length); tail = tail + 1;
            h_wr(R2A_BASE + tail, typ);    tail = tail + 1;
            h_wr(R2A_BASE + tail, sid);    tail = tail + 1;
            for (i = 0; i < length; i = i + 1) begin h_wr(R2A_BASE + tail, h_pkt[i]); tail = tail + 1; end
            h_wr(CAP_BASE + 0, tail);
            h_irq(8'h81);                                     // set cp_irq -> INT6
        end
    endtask

    integer i, j, n;
    reg found;
    reg [7:0] v, v2;
    reg [15:0] adr;

    initial begin
        for (i = 0; i < 2048; i = i + 1) buffer[i] = 0;
        repeat (4) clk1; rst = 0; clk1;

        // ---- T1: reset state
        $display("T1 reset state");
        check(int6 === 1'b0 && pi_irq === 1'b0, "irq low after reset");
        rreg(REG_IRQ, v); check(v === 8'h00, "REG_IRQ reads 0 after reset");

        // ---- T2: probe_pi_interface_once
        $display("T2 probe");
        probe(found); check(found, "probe finds the interface");
        h_rd(CAP_BASE + 6, v); h_rd(CAP_BASE + 7, v2);
        check(v === 8'h99 && v2 === 8'hbd, "host sees probe bytes at 518/519");

        // ---- T3: clear_cap (4 writes of 0 at CAP_BASE), update_restart_counter
        $display("T3 cap + restart counter");
        for (i = 0; i < 4; i = i + 1) h_wr(CAP_BASE + i, 8'hff);
        set_ptr(CAP_BASE); for (i = 0; i < 4; i = i + 1) wreg(REG_SRAM, 8'h00);
        for (i = 0; i < 4; i = i + 1) begin h_rd(CAP_BASE + i, v); check(v === 8'h00, "clear_cap"); end
        h_wr(CAP_BASE + 4, 8'h41);                       // restart counter of the previous run
        set_ptr(CAP_BASE + 4); rreg(REG_SRAM, v); check(v === 8'h41, "old restart counter read");
        set_ptr(CAP_BASE + 4); wreg(REG_SRAM, v + 1); wreg(REG_SRAM, 8'ha3); wreg(REG_SRAM, 8'h14);
        h_rd(CAP_BASE + 4, v); check(v === 8'h42, "counter + 1");
        h_rd(CAP_BASE + 5, v); check(v === 8'ha3, "0xA3");
        h_rd(CAP_BASE + 6, v); check(v === 8'h14, "0x14 (overwrites the probe)");
        h_rd(CAP_BASE + 7, v); check(v === 8'hbd, "byte 519 untouched");

        // ---- T4: interrupt bits like the CPLD
        $display("T4 irq semantics");
        wreg(REG_IRQ, 8'h82);                            // set_pi_irq
        check(pi_irq === 1'b1 && int6 === 1'b0, "set_pi_irq: only bit 1");
        rreg(REG_IRQ, v); check(v === 8'h00, "Amiga does not see the Pi's bit (spurious)");
        h_irq(8'h81);                                    // Pi: interrupt the Amiga
        check(int6 === 1'b1 && pi_irq === 1'b1, "cp_irq set, pi_irq untouched");
        rreg(REG_IRQ, v); check(v === 8'h01, "REG_IRQ reads 1");
        rreg(REG_IRQ, v); check(v === 8'h01, "reading does not clear");
        wreg(REG_IRQ, 8'h01);                            // IntServer / clear_amiga_irq
        check(int6 === 1'b0 && pi_irq === 1'b1, "clear_amiga_irq clears cp_irq only");
        wreg(REG_IRQ, 8'h80);                            // set with empty mask
        check(int6 === 1'b0 && pi_irq === 1'b1, "set with mask 0 changes nothing");
        wreg(REG_IRQ, 8'h00);
        check(int6 === 1'b0 && pi_irq === 1'b1, "clear with mask 0 changes nothing");
        h_irq(8'h02);
        check(pi_irq === 1'b0, "Pi clears pi_irq");
        wreg(REG_IRQ, 8'h83); check(int6 === 1'b1 && pi_irq === 1'b1, "set both");
        wreg(REG_IRQ, 8'h03); check(int6 === 1'b0 && pi_irq === 1'b0, "clear both");
        wreg(REG_IRQ, 8'hfc); check(int6 === 1'b0 && pi_irq === 1'b0, "bits 7..2 do nothing else");

        // ---- T5: auto-increment exactly once per access
        $display("T5 auto-increment");
        for (i = 0; i < 8; i = i + 1) h_wr(1000 + i, 8'h10 + i);
        set_ptr(1000);
        rreg(REG_SRAM, v);   check(v === 8'h10, "read 1000");
        rreg(REG_IRQ, v);    rreg(REG_ADDR_LO, v); rreg(REG_ADDR_HI, v);
        check(v === 8'h00, "ADDR regs read 0");
        rreg(REG_SRAM, v);   check(v === 8'h11, "IRQ/ADDR reads do not move the pointer");
        wreg(REG_IRQ, 8'h01);
        rreg(REG_SRAM, v);   check(v === 8'h12, "IRQ write does not move the pointer");
        // long cycle: a_sel high for 300 clocks, one side effect
        a_sel = 1; a_we = 0; a_reg = REG_SRAM; repeat (300) clk1;
        a_end = 1; v = a_dout; clk1; a_sel = 0; a_end = 0; repeat (GAP) clk1;
        check(v === 8'h13, "long cycle reads 1003");
        rreg(REG_SRAM, v);   check(v === 8'h14, "pointer moved once (1004)");
        // a_end without a_sel: ignored
        a_we = 1; a_reg = REG_SRAM; a_din = 8'hee; a_end = 1; repeat (3) clk1; a_end = 0; a_we = 0;
        h_rd(1005, v); check(v === 8'h15, "a_end without a_sel does not write");
        rreg(REG_SRAM, v);   check(v === 8'h15, "and does not move the pointer");
        // writes increment too
        set_ptr(1100); wreg(REG_SRAM, 8'hA1); wreg(REG_SRAM, 8'hA2); wreg(REG_SRAM, 8'hA3);
        h_rd(1100, v); h_rd(1101, v2); check(v === 8'hA1 && v2 === 8'hA2, "write 1100/1101");
        h_rd(1102, v); check(v === 8'hA3, "write 1102");
        h_wr(1103, 8'hB4); rreg(REG_SRAM, v); check(v === 8'hB4, "pointer now 1103");
        // only the low pointer byte
        set_ptr(16'h01ff); wreg(REG_ADDR_LO, 8'h10); h_wr(8'h10 + 256, 8'h77);
        rreg(REG_SRAM, v); check(v === 8'h77, "A_LO write keeps A_HI");
        // carry from the low byte into the high byte
        h_wr(16'h0100, 8'h5a); h_wr(16'h00ff, 8'h5b);
        set_ptr(16'h00ff); rreg(REG_SRAM, v); rreg(REG_SRAM, v2);
        check(v === 8'h5b && v2 === 8'h5a, "pointer carries into the high byte");

        // ---- T6: alias and wrap of the 16 bit pointer (RAM = 8 KB)
        $display("T6 alias");
        h_wr(5, 8'hC5);
        set_ptr(16'h2005); rreg(REG_SRAM, v); check(v === 8'hC5, "$2005 aliases 5");
        set_ptr(16'hffff); wreg(REG_SRAM, 8'h3c);
        h_rd(13'h1fff, v); check(v === 8'h3c, "write at $ffff lands at $1fff");
        rreg(REG_SRAM, v); h_rd(0, v2); check(v === v2, "pointer wraps $ffff -> 0");

        // ---- T7: both ports at the same time
        $display("T7 concurrent host access");
        for (i = 0; i < 16; i = i + 1) h_wr(2000 + i, i);
        set_ptr(2000);
        fork
            begin : amiga_p
                for (i = 0; i < 16; i = i + 1) begin rreg(REG_SRAM, v); buffer[i] = v; end
            end
            begin : host_p
                for (j = 0; j < 400; j = j + 1) begin h_wr(3000 + (j % 16), j); h_rd(3000 + (j % 16), v2); end
            end
        join
        n = 0; for (i = 0; i < 16; i = i + 1) if (buffer[i] !== i) n = n + 1;
        check(n == 0, "amiga reads undisturbed by host traffic");
        n = 0; for (i = 0; i < 16; i = i + 1) begin h_rd(3000 + i, v2); if (v2 !== ((384 + i) % 256)) n = n + 1; end
        check(n == 0, "host writes landed");

        // ---- T8: driver sequence A2R / R2A with wrap of the 256 byte rings
        $display("T8 rings");
        cap_a2r_tail = 8'd250; cap_r2a_head = 8'd250;       // near the end, packets wrap
        h_wr(CAP_BASE + 1, 8'd250); h_wr(CAP_BASE + 0, 8'd250);   // a2r_head, r2a_tail
        // CONNECT "ethernet" (type 4, stream 1)
        for (i = 0; i < 8; i = i + 1) buffer[i] = "ethernet" >> (8 * (7 - i));
        write_to_a2r(8'd4, 8'd1, 8'd8);
        write_amiga_cap;
        wreg(REG_IRQ, 8'h82);                               // set_pi_irq
        check(pi_irq === 1'b1, "Companion interrupt raised");
        check(cap_a2r_tail == 8'd5, "a2r_tail wrapped (250 + 11 = 261)");
        h_take_a2r;
        check(h_len == 8 && h_typ == 4 && h_sid == 1, "CONNECT header across the wrap");
        n = 0; for (i = 0; i < 8; i = i + 1) if (h_pkt[i] !== ("ethernet" >> (8 * (7 - i)) & 8'hff)) n = n + 1;
        check(n == 0, "service name across the wrap");
        check(pi_irq === 1'b0, "pi_irq cleared by the host");
        // CONNECT_RESPONSE (type 5) with result 0 -> Amiga
        h_pkt[0] = 8'd0;
        h_put_r2a(8'd5, 8'd1, 8'd1);
        check(int6 === 1'b1, "INT6 raised by the host");
        // IntServer: read IRQ, nonzero -> write 1 to clear, then the task reads the cap
        rreg(REG_IRQ, v); check(v === 8'h01, "IntServer sees the interrupt");
        wreg(REG_IRQ, 8'h01); check(int6 === 1'b0, "IntServer clears INT6");
        read_pi_cap;
        check(cap_r2a_tail == 8'd254 && cap_a2r_head == 8'd5, "cap: r2a_tail 254, a2r_head 5");
        read_from_r2a(cap_r2a_head, 4);
        check(buffer[0] == 1 && buffer[1] == 5 && buffer[2] == 1 && buffer[3] == 0, "CONNECT_RESPONSE read");
        cap_r2a_head = cap_r2a_head + 4; write_amiga_cap;
        h_read_cap; check(h_cap[3] == 8'd254, "host sees r2a_head");
        // DATA (type 6) of 40 bytes: header + payload wraps the R2A ring
        for (i = 0; i < 40; i = i + 1) h_pkt[i] = 8'h80 + i;
        h_put_r2a(8'd6, 8'd1, 8'd40);                       // 254 + 43 = 297 -> wraps at 256
        rreg(REG_IRQ, v); check(v === 8'h01, "IntServer, second packet");
        wreg(REG_IRQ, 8'h01);
        read_pi_cap; read_from_r2a(cap_r2a_head, 43);
        check(buffer[0] == 40 && buffer[1] == 6 && buffer[2] == 1, "DATA header across the wrap");
        n = 0; for (i = 0; i < 40; i = i + 1) if (buffer[3 + i] !== 8'h80 + i) n = n + 1;
        check(n == 0, "DATA payload across the wrap");
        check(cap_r2a_tail == 8'd41, "r2a_tail wrapped (297 - 256)");

        // ---- T9: frames of 1514 bytes (RX/TX buffer of a314eth) in the RAM
        $display("T9 frames");
        for (i = 0; i < 1514; i = i + 1) buffer[i] = (i * 7 + 3) & 8'hff;
        write_mem(16'd520, 1514);
        n = 0; for (i = 0; i < 1514; i = i + 1) begin h_rd(520 + i, v); if (v !== ((i * 7 + 3) & 8'hff)) n = n + 1; end
        check(n == 0, "TX frame arrives at the host");
        adr = 16'd8192 - 16'd1518;                          // last buffer at the end of the RAM
        for (i = 0; i < 1514; i = i + 1) h_wr(adr + i, (i * 13 + 5) & 8'hff);
        for (i = 0; i < 1514; i = i + 1) buffer[i] = 0;
        read_mem(adr, 1514);
        n = 0; for (i = 0; i < 1514; i = i + 1) if (buffer[i] !== ((i * 13 + 5) & 8'hff)) n = n + 1;
        check(n == 0, "RX frame arrives at the Amiga");
        // the frames do not overlap the CAP/ring area
        h_rd(CAP_BASE + 4, v); check(v === 8'h42, "CAP untouched by the frames");

        // ---- T10: reset
        $display("T10 reset");
        h_irq(8'h83); check(int6 === 1'b1 && pi_irq === 1'b1, "both set before reset");
        set_ptr(16'h0123);
        rst = 1; clk1; clk1; rst = 0; clk1;
        check(int6 === 1'b0 && pi_irq === 1'b0, "irq cleared by reset");
        h_wr(0, 8'h6e);
        rreg(REG_SRAM, v); check(v === 8'h6e, "pointer 0 after reset");
        h_rd(520, v); check(v === 8'h03, "RAM kept over the reset");

        if (errors == 0) $display("PASS (%0d checks)", checks); else $display("FAIL: %0d errors", errors);
        $finish;
    end
    initial begin #2000000000; $display("FAIL: time limit"); $finish; end
endmodule
