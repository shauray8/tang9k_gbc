// SM83 (Game Boy CPU) - M-cycle accurate core.
// Bus contract: addr/wr/dout/rd describe the *current* M-cycle. They change only on
// a ce edge. Memory must present read data on `din` before the next ce edge
// (synchronous RAM clocked by clk is fine when ce period >= 2 clk).
// Writes should be committed by memory on (ce && wr).
// IF (FF0F) and IE (FFFF) live inside the CPU.
module sm83 (
    input             clk,
    input             rst,
    input             ce,
    input             cgb_mode, // selects documented post-boot CPU state; stable through reset
    input             boot,     // a boot ROM is mapped: start from its power-on state at 0000
    output reg [15:0] addr,
    output reg [7:0]  dout,
    output reg        wr,
    output reg        rd,
    input      [7:0]  din,
    input      [4:0]  irq,     // request pulses: 0 vblank,1 stat,2 timer,3 serial,4 joypad
    output            halted,
    output reg        stop_req, // one clk pulse after executing two-byte STOP
    output     [15:0] pc_dbg
);
    reg [7:0] A, F, B, C, D, E, H, L, IR, Z, W;
    reg [15:0] SP, PC;
    reg [2:0] mc;
    reg IME, ime_delay, halt, intm, haltbug;
    reg [4:0] IF, IE;

    assign halted = halt;
    assign pc_dbg = PC;

    // next bus cycle
    reg [15:0] nA;
    reg [7:0] nD;
    reg nW, nR;

    // Inputs are registered one clk early: the system guarantees >=2 clk between bus/IRQ changes
    // and the next ce, so this is cycle-identical and removes memory->ALU and IRQ->decode paths.
    reg [7:0] din_r;
    reg [4:0] pend_r;
    always @(posedge clk) din_r <= din;
    wire [7:0] din_e = (addr == 16'hFF0F) ? {3'b111, IF} :
                       (addr == 16'hFFFF) ? {3'b000, IE} : din_r;

    wire fZ = F[7], fN = F[6], fH = F[5], fC = F[4];

    function [7:0] getr(input [2:0] i);
        case (i)
            3'd0: getr = B; 3'd1: getr = C; 3'd2: getr = D; 3'd3: getr = E;
            3'd4: getr = H; 3'd5: getr = L; 3'd6: getr = 8'hFF; default: getr = A;
        endcase
    endfunction

    function cond(input [1:0] cc);
        case (cc)
            2'd0: cond = !fZ; 2'd1: cond = fZ; 2'd2: cond = !fC; default: cond = fC;
        endcase
    endfunction

    // 8-bit ALU: returns {Z,N,H,C,result}
    function [11:0] alu(input [2:0] op, input [7:0] a, input [7:0] b, input cin);
        reg sub, carry_in;
        reg [7:0] operand, arithmetic, result;
        reg [4:0] lo, hi;
        begin
            // One nibble-split adder supplies both result and half/full carry.
            // Subtraction uses A + ~B + !borrow; architectural carry then denotes borrow.
            sub = op == 3'd2 || op == 3'd3 || op == 3'd7;
            carry_in = sub ^ ((op == 3'd1 || op == 3'd3) && cin);
            operand = b ^ {8{sub}};
            lo = {1'b0, a[3:0]} + {1'b0, operand[3:0]} + carry_in;
            hi = {1'b0, a[7:4]} + {1'b0, operand[7:4]} + lo[4];
            arithmetic = {hi[3:0], lo[3:0]};
            case (op)
                3'd4: begin result = a & b; alu = {result == 0, 3'b010, result}; end
                3'd5: begin result = a ^ b; alu = {result == 0, 3'b000, result}; end
                3'd6: begin result = a | b; alu = {result == 0, 3'b000, result}; end
                default: alu = {arithmetic == 0, sub, lo[4] ^ sub, hi[4] ^ sub,
                                op == 3'd7 ? a : arithmetic};
            endcase
        end
    endfunction

    // CB rotate/shift group: returns {C,result}; Z computed by caller
    function [8:0] rot(input [2:0] op, input [7:0] v, input cin);
        case (op)
            3'd0: rot = {v[7], v[6:0], v[7]};        // RLC
            3'd1: rot = {v[0], v[0], v[7:1]};        // RRC
            3'd2: rot = {v[7], v[6:0], cin};         // RL
            3'd3: rot = {v[0], cin, v[7:1]};         // RR
            3'd4: rot = {v[7], v[6:0], 1'b0};        // SLA
            3'd5: rot = {v[0], v[7], v[7:1]};        // SRA
            3'd6: rot = {1'b0, v[3:0], v[7:4]};      // SWAP
            default: rot = {v[0], 1'b0, v[7:1]};     // SRL
        endcase
    endfunction

    // full CB op on value: returns {flags4, result, writes_back}
    function [12:0] cbx(input [7:0] op, input [7:0] v, input [7:0] f);
        reg [8:0] r;
        case (op[7:6])
            2'd0: begin r = rot(op[5:3], v, f[4]); cbx = {r[7:0]==0, 1'b0, 1'b0, r[8], r[7:0], 1'b1}; end
            2'd1: cbx = {!v[op[5:3]], 1'b0, 1'b1, f[4], v, 1'b0};
            2'd2: cbx = {f[7:4], v & ~(8'd1 << op[5:3]), 1'b1};
            default: cbx = {f[7:4], v | (8'd1 << op[5:3]), 1'b1};
        endcase
    endfunction

    // locals
    reg [7:0] d, op, v, cbop;
    reg [11:0] ar;
    reg [12:0] cr;
    reg [8:0] rr9;
    reg [15:0] t16, rp;
    reg [16:0] t17;
    reg [4:0] pend;

    task setr(input [2:0] i, input [7:0] val);
        case (i)
            3'd0: B = val; 3'd1: C = val; 3'd2: D = val; 3'd3: E = val;
            3'd4: H = val; 3'd5: L = val; 3'd7: A = val; default: ;
        endcase
    endtask

    function [15:0] getrp(input [1:0] i);
        case (i)
            2'd0: getrp = {B, C}; 2'd1: getrp = {D, E}; 2'd2: getrp = {H, L}; default: getrp = SP;
        endcase
    endfunction

    task setrp(input [1:0] i, input [15:0] val);
        case (i)
            2'd0: {B, C} = val; 2'd1: {D, E} = val; 2'd2: {H, L} = val; default: SP = val;
        endcase
    endtask

    task fetch;   begin nA = PC; nW = 0; nR = 1; mc = 0; end endtask
    task rdm(input [15:0] a); begin nA = a; nW = 0; nR = 1; mc = mc + 1; end endtask
    task wrm(input [15:0] a, input [7:0] dv); begin nA = a; nW = 1; nR = 0; nD = dv; mc = mc + 1; end endtask
    task idle;    begin nA = PC; nW = 0; nR = 0; mc = mc + 1; end endtask
    task imm;     begin rdm(PC); PC = PC + 1; end endtask

    always @(posedge clk) begin
        stop_req <= 0;
        if (rst) begin
            A = cgb_mode ? 8'h11 : 8'h01; F = cgb_mode ? 8'h80 : 8'hB0;
            B = 0; C = cgb_mode ? 8'h00 : 8'h13;
            D = cgb_mode ? 8'hFF : 8'h00; E = cgb_mode ? 8'h56 : 8'hD8;
            H = cgb_mode ? 8'h00 : 8'h01; L = cgb_mode ? 8'h0D : 8'h4D;
            SP = 16'hFFFE; IR = 0; Z = 0; W = 0;   // post-boot-ROM state unless booting
            PC = boot ? 16'h0000 : 16'h0100;
            mc = 0; IME = 0; ime_delay = 0; halt = 0; intm = 0; haltbug = 0; IF = 0; IE = 0;
            addr <= boot ? 16'h0000 : 16'h0100; wr <= 0; rd <= 1; dout <= 0;
        end else begin
            if (ce) begin
                // commit IF/IE writes of the cycle that just ended
                if (wr && addr == 16'hFF0F) IF = dout[4:0];
                if (wr && addr == 16'hFFFF) IE = dout[4:0];
                d = din_e;
                nA = PC; nW = 0; nR = 1; nD = 0;
                pend = pend_r;

                if (intm) begin
                    case (mc)
                        3'd1: begin SP = SP - 1; wrm(SP, PC[15:8]); end
                        3'd2: begin
                            SP = SP - 1; wrm(SP, PC[7:0]);
                            casez (pend)
                                5'b????1: begin PC = 16'h40; IF[0] = 0; end
                                5'b???10: begin PC = 16'h48; IF[1] = 0; end
                                5'b??100: begin PC = 16'h50; IF[2] = 0; end
                                5'b?1000: begin PC = 16'h58; IF[3] = 0; end
                                5'b10000: begin PC = 16'h60; IF[4] = 0; end
                                default:  PC = 16'h0000;
                            endcase
                        end
                        3'd3: idle;
                        default: begin intm = 0; fetch; end
                    endcase
                end else if (mc == 0 && halt && (pend == 0 || IME)) begin
                    if (pend != 0) begin halt = 0; IME = 0; intm = 1; idle; end
                    else fetch;
                end else if (mc == 0 && IME && pend != 0) begin
                    // discard fetched opcode, dispatch interrupt
                    IME = 0; intm = 1; idle;
                end else begin
                    if (mc == 0) begin
                        // HALT with IME=0 resumes on the opcode its last halted cycle fetched,
                        // costing no extra cycle (same timing as a run of NOPs).
                        halt = 0;
                        if (ime_delay) begin IME = 1; ime_delay = 0; end
                        // HALT bug: the byte after HALT is fetched twice (PC does not advance).
                        IR = d; if (haltbug) haltbug = 0; else PC = PC + 1;
                    end
                    op = IR;
                    // Select operands before execution, so immediate and register/memory
                    // instructions share one ALU rather than separate function expansions.
                    ar = alu(op[5:3], A,
                             op[7:6] == 2'b10 && op[2:0] != 3'd6 ? getr(op[2:0]) : d, fC);
                    cbop = mc == 3'd1 ? d : W;
                    cr = cbx(cbop, mc == 3'd1 ? getr(cbop[2:0]) : d, F);
                    casez (op)
                    // ---------------- 0x00-0x3F ----------------
                    8'h00: fetch;
                    8'h10: begin PC = PC + 1; stop_req <= 1; fetch; end
                    8'b00??0001: case (mc) // LD rr,nn
                        0: imm;
                        1: begin Z = d; imm; end
                        default: begin setrp(op[5:4], {d, Z}); fetch; end
                    endcase
                    8'b00??0010: case (mc) // LD (rr),A
                        0: begin
                            case (op[5:4])
                                2'd0: rp = {B, C}; 2'd1: rp = {D, E};
                                default: rp = {H, L};
                            endcase
                            wrm(rp, A);
                            if (op[5:4] == 2'd2) {H, L} = {H, L} + 1;
                            if (op[5:4] == 2'd3) {H, L} = {H, L} - 1;
                        end
                        default: fetch;
                    endcase
                    8'b00??1010: case (mc) // LD A,(rr)
                        0: begin
                            case (op[5:4])
                                2'd0: rp = {B, C}; 2'd1: rp = {D, E};
                                default: rp = {H, L};
                            endcase
                            rdm(rp);
                            if (op[5:4] == 2'd2) {H, L} = {H, L} + 1;
                            if (op[5:4] == 2'd3) {H, L} = {H, L} - 1;
                        end
                        default: begin A = d; fetch; end
                    endcase
                    8'b00??0011: case (mc) // INC rr
                        0: begin setrp(op[5:4], getrp(op[5:4]) + 1); idle; end
                        default: fetch;
                    endcase
                    8'b00??1011: case (mc) // DEC rr
                        0: begin setrp(op[5:4], getrp(op[5:4]) - 1); idle; end
                        default: fetch;
                    endcase
                    8'b00???10?: begin // INC r / DEC r
                        if (op[5:3] == 3'd6) begin
                            case (mc)
                                0: rdm({H, L});
                                1: begin
                                    v = op[0] ? d - 1 : d + 1;
                                    F = {v == 0, op[0], op[0] ? d[3:0] == 4'h0 : d[3:0] == 4'hF, fC, 4'b0};
                                    wrm({H, L}, v);
                                end
                                default: fetch;
                            endcase
                        end else begin
                            d = getr(op[5:3]);
                            v = op[0] ? d - 1 : d + 1;
                            F = {v == 0, op[0], op[0] ? d[3:0] == 4'h0 : d[3:0] == 4'hF, fC, 4'b0};
                            setr(op[5:3], v);
                            fetch;
                        end
                    end
                    8'b00???110: case (mc) // LD r,n
                        0: imm;
                        1: if (op[5:3] == 3'd6) wrm({H, L}, d); else begin setr(op[5:3], d); fetch; end
                        default: fetch;
                    endcase
                    8'h07, 8'h0F, 8'h17, 8'h1F: begin
                        rr9 = rot({1'b0, op[4:3]}, A, fC);
                        A = rr9[7:0]; F = {3'b000, rr9[8], 4'b0};
                        fetch;
                    end
                    8'h08: case (mc) // LD (nn),SP
                        0: imm;
                        1: begin Z = d; imm; end
                        2: begin W = d; wrm({W, Z}, SP[7:0]); end
                        3: wrm({W, Z} + 16'd1, SP[15:8]);
                        default: fetch;
                    endcase
                    8'b00??1001: case (mc) // ADD HL,rr
                        0: begin
                            rp = getrp(op[5:4]);
                            t17 = {H, L} + rp;
                            F = {fZ, 1'b0, ({1'b0, H[3:0], L} + {1'b0, rp[11:0]}) >> 12 != 0, t17[16], 4'b0};
                            {H, L} = t17[15:0];
                            idle;
                        end
                        default: fetch;
                    endcase
                    8'h18, 8'h20, 8'h28, 8'h30, 8'h38: case (mc) // JR
                        0: imm;
                        1: if (op == 8'h18 || cond(op[4:3])) begin PC = PC + {{8{d[7]}}, d}; idle; end else fetch;
                        default: fetch;
                    endcase
                    8'h27: begin // DAA
                        v = A; rr9[8] = fC;
                        if (!fN) begin
                            if (fC || v > 8'h99) begin v = v + 8'h60; rr9[8] = 1; end
                            if (fH || v[3:0] > 4'h9) v = v + 8'h06;
                        end else begin
                            if (fC) v = v - 8'h60;
                            if (fH) v = v - 8'h06;
                        end
                        A = v; F = {v == 0, fN, 1'b0, rr9[8], 4'b0};
                        fetch;
                    end
                    8'h2F: begin A = ~A; F = {fZ, 1'b1, 1'b1, fC, 4'b0}; fetch; end
                    8'h37: begin F = {fZ, 1'b0, 1'b0, 1'b1, 4'b0}; fetch; end
                    8'h3F: begin F = {fZ, 1'b0, 1'b0, !fC, 4'b0}; fetch; end
                    // ---------------- 0x40-0x7F ----------------
                    8'h76: begin
                        if (pend == 0 || IME) halt = 1;
                        else haltbug = 1;   // IME=0 with a pending interrupt: no halt, PC stalls once
                        fetch;
                    end
                    8'b01??????: begin
                        if (op[2:0] == 3'd6) case (mc)
                            0: rdm({H, L});
                            default: begin setr(op[5:3], d); fetch; end
                        endcase
                        else if (op[5:3] == 3'd6) case (mc)
                            0: wrm({H, L}, getr(op[2:0]));
                            default: fetch;
                        endcase
                        else begin setr(op[5:3], getr(op[2:0])); fetch; end
                    end
                    // ---------------- 0x80-0xBF ----------------
                    8'b10??????: begin
                        if (op[2:0] == 3'd6 && mc == 0) rdm({H, L});
                        else begin
                            A = ar[7:0]; F = {ar[11:8], 4'b0};
                            fetch;
                        end
                    end
                    // ---------------- 0xC0-0xFF ----------------
                    8'b11???110: case (mc) // ALU A,n
                        0: imm;
                        default: begin
                            A = ar[7:0]; F = {ar[11:8], 4'b0};
                            fetch;
                        end
                    endcase
                    8'hC0, 8'hC8, 8'hD0, 8'hD8: case (mc) // RET cc
                        0: idle;
                        1: if (cond(op[4:3])) begin rdm(SP); SP = SP + 1; end else fetch;
                        2: begin Z = d; rdm(SP); SP = SP + 1; end
                        3: begin PC = {d, Z}; idle; end
                        default: fetch;
                    endcase
                    8'hC9, 8'hD9: case (mc) // RET / RETI
                        0: begin rdm(SP); SP = SP + 1; end
                        1: begin Z = d; rdm(SP); SP = SP + 1; end
                        2: begin PC = {d, Z}; if (op == 8'hD9) IME = 1; idle; end
                        default: fetch;
                    endcase
                    8'b11??0001: case (mc) // POP
                        0: begin rdm(SP); SP = SP + 1; end
                        1: begin Z = d; rdm(SP); SP = SP + 1; end
                        default: begin
                            if (op[5:4] == 2'd3) begin A = d; F = {Z[7:4], 4'b0}; end
                            else setrp(op[5:4], {d, Z});
                            fetch;
                        end
                    endcase
                    8'b11??0101: case (mc) // PUSH
                        0: begin
                            rp = (op[5:4] == 2'd3) ? {A, F} : getrp(op[5:4]);
                            W = rp[15:8]; Z = rp[7:0];
                            idle;
                        end
                        1: begin SP = SP - 1; wrm(SP, W); end
                        2: begin SP = SP - 1; wrm(SP, Z); end
                        default: fetch;
                    endcase
                    8'hC2, 8'hCA, 8'hD2, 8'hDA, 8'hC3: case (mc) // JP
                        0: imm;
                        1: begin Z = d; imm; end
                        2: begin
                            W = d;
                            if (op == 8'hC3 || cond(op[4:3])) begin PC = {W, Z}; idle; end else fetch;
                        end
                        default: fetch;
                    endcase
                    8'hC4, 8'hCC, 8'hD4, 8'hDC, 8'hCD: case (mc) // CALL
                        0: imm;
                        1: begin Z = d; imm; end
                        2: begin W = d; if (op == 8'hCD || cond(op[4:3])) idle; else fetch; end
                        3: begin SP = SP - 1; wrm(SP, PC[15:8]); end
                        4: begin SP = SP - 1; wrm(SP, PC[7:0]); end
                        default: begin PC = {W, Z}; fetch; end
                    endcase
                    8'b11???111: case (mc) // RST
                        0: idle;
                        1: begin SP = SP - 1; wrm(SP, PC[15:8]); end
                        2: begin SP = SP - 1; wrm(SP, PC[7:0]); PC = {10'b0, op[5:3], 3'b000}; end
                        default: fetch;
                    endcase
                    8'hCB: case (mc)
                        0: imm;
                        1: begin
                            cbop = d; W = d;
                            if (cbop[2:0] == 3'd6) rdm({H, L});
                            else begin
                                F = {cr[12:9], 4'b0};
                                if (cr[0]) setr(cbop[2:0], cr[8:1]);
                                fetch;
                            end
                        end
                        2: begin
                            F = {cr[12:9], 4'b0};
                            if (W[7:6] == 2'd1) fetch; else wrm({H, L}, cr[8:1]);
                        end
                        default: fetch;
                    endcase
                    8'hE0, 8'hF0: case (mc) // LDH (n),A / LDH A,(n)
                        0: imm;
                        1: if (op[4]) rdm({8'hFF, d}); else wrm({8'hFF, d}, A);
                        default: begin if (op[4]) A = d; fetch; end
                    endcase
                    8'hE2, 8'hF2: case (mc) // LD (C),A / LD A,(C)
                        0: if (op[4]) rdm({8'hFF, C}); else wrm({8'hFF, C}, A);
                        default: begin if (op[4]) A = d; fetch; end
                    endcase
                    8'hEA, 8'hFA: case (mc) // LD (nn),A / LD A,(nn)
                        0: imm;
                        1: begin Z = d; imm; end
                        2: if (op[4]) rdm({d, Z}); else wrm({d, Z}, A);
                        default: begin if (op[4]) A = d; fetch; end
                    endcase
                    8'hE8, 8'hF8: case (mc) // ADD SP,e / LD HL,SP+e
                        0: imm;
                        1: begin
                            t16 = SP + {{8{d[7]}}, d};
                            F = {2'b00, ({1'b0, SP[3:0]} + {1'b0, d[3:0]}) > 5'h0F,
                                        ({1'b0, SP[7:0]} + {1'b0, d}) > 9'h0FF, 4'b0};
                            if (op[4]) {H, L} = t16; else SP = t16;
                            idle;
                        end
                        2: if (op[4]) fetch; else idle;
                        default: fetch;
                    endcase
                    8'hF9: case (mc)
                        0: begin SP = {H, L}; idle; end
                        default: fetch;
                    endcase
                    8'hE9: begin PC = {H, L}; fetch; end
                    8'hF3: begin IME = 0; ime_delay = 0; fetch; end
                    8'hFB: begin ime_delay = 1; fetch; end
                    default: fetch; // illegal opcodes: treated as NOP
                    endcase
                end

                addr <= nA; wr <= nW; rd <= nR; dout <= nD;
            end
            IF = IF | irq;
            pend_r <= IE & IF;
        end
    end
endmodule
