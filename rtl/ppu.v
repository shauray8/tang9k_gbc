// DMG PPU. One dot per ce_t. ce marks M-cycle boundaries (subset of clk, coincident with a CPU bus edge).
// VRAM: single BSRAM port shared with the CPU (CPU locked out in mode 3, as on hardware).
// OAM: 4 x 64x8 distributed RAM banks -> one whole sprite entry per dot during OAM scan.
// Sprites are fetched during mode 2 (VRAM otherwise idle) and merged with a per-sprite
// stall in mode 3 (single merge unit).
module ppu (
    input             clk,
    input             rst,
    input             ce_t,
    input             ce,
    input      [15:0] cpu_addr,
    input             cpu_wr,      // already qualified with ce
    input      [7:0]  cpu_din,
    output reg [7:0]  cpu_dout,
    input             vram_sel,
    input             oam_sel,
    input             reg_sel,
    input             dma_act,
    input             dma_we,
    input      [7:0]  dma_idx,
    input      [7:0]  dma_data,
    output reg        irq_vblank,
    output reg        irq_stat,
    output reg        pix_we,
    output reg [1:0]  pix,
    output reg [7:0]  pix_x,
    output     [7:0]  pix_y,
    output reg        vsync,       // pulse at start of frame (LY=0, dot 0) while LCD on
    output            lcd_on
);
    // ---------------- registers ----------------
    reg [7:0] LCDC, SCY, SCX, LYC, BGP, OBP0, OBP1, WY, WX;
    reg [3:0] STATW;              // STAT bits 6..3
    reg [7:0] ly;
    reg [8:0] dot;
    reg [1:0] mode;
    assign pix_y = ly;
    assign lcd_on = LCDC[7];

    wire cpu_vram_ok = mode != 2'd3;
    wire cpu_oam_ok  = !mode[1] && !dma_act;

    // ---------------- VRAM ----------------
    reg [7:0] vram [0:8191];
    reg [12:0] v_addr;
    reg v_we;
    reg [7:0] v_q;
    always @(posedge clk) begin
        if (v_we) vram[v_addr] <= cpu_din;
        v_q <= vram[v_addr];
    end
    reg cpu_slot1, cpu_slot2;     // clk after ce: CPU read issue; clk after that: capture
    reg [7:0] cpu_vq;
    wire cpu_vwr = cpu_wr && vram_sel && cpu_vram_ok;
    wire cpu_vrd = cpu_slot1 && vram_sel && cpu_vram_ok;
    wire cpu_owns = cpu_vwr || cpu_vrd;
    reg [12:0] ppu_va;            // driven combinationally below
    reg ppu_vreq;
    wire ppu_gnt = ce_t && ppu_vreq && !cpu_owns;
    always @(*) begin
        v_we = cpu_vwr;
        v_addr = cpu_owns ? cpu_addr[12:0] : ppu_va;
    end
    reg ppu_iss;                  // previous clk was a granted PPU issue
    reg [7:0] ppu_vhold;
    wire [7:0] ppu_vd = ppu_iss ? v_q : ppu_vhold;
    always @(posedge clk) begin
        cpu_slot1 <= ce;
        cpu_slot2 <= cpu_slot1 && cpu_vrd;
        if (cpu_slot2) cpu_vq <= v_q;
        ppu_iss <= ppu_gnt;
        if (ppu_iss) ppu_vhold <= v_q;
    end

    // ---------------- OAM (distributed) ----------------
    reg [7:0] oam0 [0:63], oam1 [0:63], oam2 [0:63], oam3 [0:63];
    wire oam_cpu_we = cpu_wr && oam_sel && cpu_oam_ok;
    wire [7:0] oam_wi = dma_we ? dma_idx : cpu_addr[7:0];
    wire [7:0] oam_wd = dma_we ? dma_data : cpu_din;
    always @(posedge clk) if (dma_we || oam_cpu_we) case (oam_wi[1:0])
        2'd0: oam0[oam_wi[7:2]] <= oam_wd;
        2'd1: oam1[oam_wi[7:2]] <= oam_wd;
        2'd2: oam2[oam_wi[7:2]] <= oam_wd;
        default: oam3[oam_wi[7:2]] <= oam_wd;
    endcase
    reg [5:0] scan_i;
    wire [5:0] oam_ri = mode == 2'd2 ? scan_i : cpu_addr[7:2];
    wire [7:0] o_y = oam0[oam_ri], o_x = oam1[oam_ri], o_t = oam2[oam_ri], o_a = oam3[oam_ri];

    // ---------------- CPU reads ----------------
    wire lyc_eq = ly == LYC;
    always @(*) begin
        cpu_dout = 8'hFF;
        if (vram_sel) cpu_dout = cpu_vram_ok ? cpu_vq : 8'hFF;
        else if (oam_sel) begin
            if (cpu_oam_ok) case (cpu_addr[1:0])
                2'd0: cpu_dout = o_y; 2'd1: cpu_dout = o_x; 2'd2: cpu_dout = o_t; default: cpu_dout = o_a;
            endcase
        end else case (cpu_addr[3:0])
            4'h0: cpu_dout = LCDC;
            4'h1: cpu_dout = {1'b1, STATW, lyc_eq, LCDC[7] ? mode : 2'd0};
            4'h2: cpu_dout = SCY;
            4'h3: cpu_dout = SCX;
            4'h4: cpu_dout = ly;
            4'h5: cpu_dout = LYC;
            4'h7: cpu_dout = BGP;
            4'h8: cpu_dout = OBP0;
            4'h9: cpu_dout = OBP1;
            4'hA: cpu_dout = WY;
            4'hB: cpu_dout = WX;
            default: cpu_dout = 8'hFF;
        endcase
    end

    // ---------------- sprite slots ----------------
    reg [7:0] s_x  [0:9];
    reg [12:0] s_ad[0:9];         // {tile, row-in-object, yflip}; size applied at fetch (mode 3) like hw
    reg [7:0] s_lo [0:9], s_hi[0:9];
    reg [2:0] s_at [0:9];         // {prio, xflip, pal}
    reg [3:0] s_cnt, s_fp;        // slots found, fetch pointer
    reg s_fhi;                    // fetching hi byte
    reg s_pend;                   // a sprite byte read is outstanding
    reg [3:0] s_pslot; reg s_phi;
    reg [9:0] s_done;
    wire s_busy = s_fp != s_cnt || s_pend;

    wire [3:0] sh = LCDC[2] ? 4'd15 : 4'd7;
    wire [8:0] yrel = {1'b0, ly} + 9'd16 - {1'b0, o_y};
    wire s_hit = yrel <= {5'd0, sh};
    // fetch-time address for slot s_fp (uses current LCDC.2)
    wire [12:0] f_sad = s_ad[s_fp];
    wire [3:0] f_srow = f_sad[0] ? sh - f_sad[4:1] : f_sad[4:1];
    wire [7:0] f_stile = LCDC[2] ? {f_sad[12:6], f_srow[3]} : f_sad[12:5];

    function [7:0] rev(input [7:0] v);
        rev = {v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]};
    endfunction

    // ---------------- BG / window fetcher ----------------
    reg [2:0] fstep;
    reg [4:0] ftx;               // tile column counter
    reg [7:0] f_tile, f_lo;
    reg [7:0] l_lo, l_hi; reg l_valid;
    reg [7:0] sh_lo, sh_hi; reg [3:0] sh_cnt;
    reg [7:0] px;                // 0..167, screen x = px-8
    reg [2:0] discard;
    reg win_mode, win_line_used, wy_hit;
    reg [7:0] wly;
    reg [15:0] sfifo;            // 8 x 2-bit colour (MSB first)
    reg [7:0] sf_pal, sf_pri;    // per pixel attributes (bit7 = next out)

    wire [7:0] bgy = ly + SCY;
    wire [2:0] fy = win_mode ? wly[2:0] : bgy[2:0];
    wire [9:0] map_off = win_mode ? {wly[7:3], ftx} : {bgy[7:3], SCX[7:3] + ftx};
    wire map_sel = win_mode ? LCDC[6] : LCDC[3];
    wire [12:0] map_addr = {2'b11, map_sel, map_off};
    wire [12:0] tdat_addr = {LCDC[4] ? 1'b0 : ~f_tile[7], f_tile[7], f_tile[6:0], fy, 1'b0};

    // sprite to merge this dot: lowest slot whose x == px
    reg [3:0] m_s; reg m_hit;
    integer k;
    always @(*) begin
        m_hit = 0; m_s = 0;
        for (k = 9; k >= 0; k = k - 1)
            if (k < s_cnt && !s_done[k] && s_x[k] == px) begin m_hit = 1; m_s = k; end
    end
    wire spr_on = LCDC[1];

    // STAT interrupt line
    wire stat_line = LCDC[7] && ((STATW[3] && lyc_eq) || (STATW[2] && mode == 2'd2) ||
                                 (STATW[1] && mode == 2'd1) || (STATW[0] && mode == 2'd0));
    reg stat_prev;

    reg [1:0] bgc, spc, col;
    reg [7:0] pal;
    reg [7:0] mlo, mhi;
    integer j;

    always @(posedge clk) begin
        irq_vblank <= 0; irq_stat <= 0; pix_we <= 0; vsync <= 0;
        if (rst) begin
            LCDC <= 8'h91; STATW <= 0; SCY <= 0; SCX <= 0; LYC <= 0;
            BGP <= 8'hFC; OBP0 <= 8'hFF; OBP1 <= 8'hFF; WY <= 0; WX <= 0;
            ly <= 0; dot <= 0; mode <= 2'd2; stat_prev <= 0;
            s_cnt <= 0; s_fp <= 0; s_fhi <= 0; s_pend <= 0;
            wy_hit <= 0; wly <= 0;
        end else begin
            // register writes (at ce)
            if (cpu_wr && reg_sel) case (cpu_addr[3:0])
                4'h0: LCDC <= cpu_din;
                4'h1: STATW <= cpu_din[6:3];
                4'h2: SCY <= cpu_din;
                4'h3: SCX <= cpu_din;
                4'h5: LYC <= cpu_din;
                4'h7: BGP <= cpu_din;
                4'h8: OBP0 <= cpu_din;
                4'h9: OBP1 <= cpu_din;
                4'hA: WY <= cpu_din;
                4'hB: WX <= cpu_din;
                default: ;
            endcase

            if (ce_t) begin
                stat_prev <= stat_line;
                if (stat_line && !stat_prev) irq_stat <= 1;
            end

            if (!LCDC[7]) begin
                ly <= 0; dot <= 0; mode <= 2'd0;
            end else if (ce_t) begin
                // ---------------- dot / line counters ----------------
                if (dot == 9'd455) begin
                    dot <= 0;
                    if (win_line_used) wly <= wly + 1;
                    if (ly == 8'd153) begin
                        ly <= 0; mode <= 2'd2; wly <= 0; wy_hit <= 0; vsync <= 1;
                    end else begin
                        ly <= ly + 1;
                        if (ly == 8'd143) begin mode <= 2'd1; irq_vblank <= 1; end
                        else if (ly < 8'd143) mode <= 2'd2;
                    end
                    s_cnt <= 0; s_fp <= 0; s_fhi <= 0; s_pend <= 0; scan_i <= 0;
                end else dot <= dot + 1;

                // ---------------- mode 2: OAM scan + sprite fetch ----------------
                if (mode == 2'd2) begin
                    if (dot == 0) begin
                        if (ly == WY) wy_hit <= 1;
                        win_line_used <= 0;
                    end
                    if (!dot[0] && dot < 9'd80) begin
                        if (s_hit && s_cnt < 4'd10) begin
                            s_x[s_cnt]  <= o_x;
                            s_ad[s_cnt] <= {o_t, yrel[3:0], o_a[6]};
                            s_at[s_cnt] <= {o_a[7], o_a[5], o_a[4]};
                            s_cnt <= s_cnt + 1;
                        end
                    end else if (dot[0]) scan_i <= scan_i + 1;
                end

                // sprite pattern fetch: runs in mode 2 and early mode 3 until all slots fetched
                if (s_pend) begin
                    if (s_phi) s_hi[s_pslot] <= s_at[s_pslot][1] ? rev(ppu_vd) : ppu_vd;
                    else       s_lo[s_pslot] <= s_at[s_pslot][1] ? rev(ppu_vd) : ppu_vd;
                end
                s_pend <= 0;

                // ---------------- mode 3 ----------------
                if (mode == 2'd2 && dot == 9'd79) begin
                    mode <= 2'd3;
                    fstep <= 0; ftx <= 0; l_valid <= 0; sh_cnt <= 0; px <= 0;
                    discard <= SCX[2:0]; win_mode <= 0; s_done <= 0;
                    sfifo <= 0; sf_pal <= 0; sf_pri <= 0;
                end

                if (mode == 2'd3 && !s_busy) begin
                    // BG fetcher (only after sprite fetch has drained)
                    case (fstep)
                        3'd0: if (ppu_gnt) fstep <= 1;
                        3'd1: begin f_tile <= ppu_vd; fstep <= 2; end
                        3'd2: if (ppu_gnt) fstep <= 3;
                        3'd3: begin f_lo <= ppu_vd; fstep <= 4; end
                        3'd4: if (ppu_gnt) fstep <= 5;
                        3'd5: begin l_lo <= f_lo; l_hi <= ppu_vd; l_valid <= 1; fstep <= 6; end
                        default: if (!l_valid) begin fstep <= 0; ftx <= ftx + 1; end
                    endcase

                    if (spr_on && m_hit) begin
                        // merge sprite into sprite FIFO; costs this dot
                        mlo = s_lo[m_s]; mhi = s_hi[m_s];
                        for (j = 0; j < 8; j = j + 1)
                            if (sfifo[15-2*j -: 2] == 2'd0 && {mhi[7-j], mlo[7-j]} != 2'd0) begin
                                sfifo[15-2*j -: 2] <= {mhi[7-j], mlo[7-j]};
                                sf_pal[7-j] <= s_at[m_s][0];
                                sf_pri[7-j] <= s_at[m_s][2];
                            end
                        s_done[m_s] <= 1;
                    end else if (px < 8'd8) begin
                        px <= px + 1;
                        sfifo <= {sfifo[13:0], 2'b00}; sf_pal <= sf_pal << 1; sf_pri <= sf_pri << 1;
                        if (sh_cnt == 0 && l_valid) begin
                            sh_lo <= l_lo; sh_hi <= l_hi; sh_cnt <= 8; l_valid <= 0;
                        end
                    end else if (LCDC[5] && wy_hit && !win_mode && WX < 8'd167 && px >= WX + 8'd1) begin
                        // window start: restart fetcher on the window map
                        win_mode <= 1; win_line_used <= 1; fstep <= 0; ftx <= 0;
                        l_valid <= 0; sh_cnt <= 0; discard <= 0;
                    end else if (sh_cnt != 0) begin
                        sh_lo <= sh_lo << 1; sh_hi <= sh_hi << 1;
                        if (sh_cnt == 4'd1 && l_valid) begin
                            sh_lo <= l_lo; sh_hi <= l_hi; sh_cnt <= 8; l_valid <= 0;
                        end else sh_cnt <= sh_cnt - 1;
                        if (discard != 0) discard <= discard - 1;
                        else begin
                            bgc = LCDC[0] ? {sh_hi[7], sh_lo[7]} : 2'd0;
                            spc = sfifo[15:14];
                            if (spr_on && spc != 0 && !(sf_pri[7] && bgc != 0)) begin
                                pal = sf_pal[7] ? OBP1 : OBP0; col = spc;
                            end else begin
                                pal = BGP; col = bgc;
                            end
                            pix <= pal[2*col +: 2];
                            pix_x <= px - 8'd8; pix_we <= 1;
                            sfifo <= {sfifo[13:0], 2'b00}; sf_pal <= sf_pal << 1; sf_pri <= sf_pri << 1;
                            px <= px + 1;
                            if (px == 8'd167) mode <= 2'd0;
                        end
                    end else if (sh_cnt == 0 && l_valid) begin
                        sh_lo <= l_lo; sh_hi <= l_hi; sh_cnt <= 8; l_valid <= 0;
                    end
                end
            end

            // advance sprite fetch pointer on grant
            if (ppu_gnt && s_fp != s_cnt && mode == 2'd3 && LCDC[7]) begin
                s_pend <= 1; s_pslot <= s_fp; s_phi <= s_fhi;
                s_fhi <= !s_fhi;
                if (s_fhi) s_fp <= s_fp + 1;
            end
        end
    end
    // PPU VRAM request (combinational from current state; granted on a tick unless the CPU owns the port)
    always @(*) begin
        ppu_vreq = 0; ppu_va = map_addr;
        if (LCDC[7] && mode == 2'd3 && s_fp != s_cnt) begin
            ppu_vreq = 1; ppu_va = {1'b0, f_stile, f_srow[2:0], s_fhi};
        end else if (LCDC[7] && mode == 2'd3 && !s_busy) case (fstep)
            3'd0: begin ppu_vreq = 1; ppu_va = map_addr; end
            3'd2: begin ppu_vreq = 1; ppu_va = tdat_addr; end
            3'd4: begin ppu_vreq = 1; ppu_va = tdat_addr | 13'd1; end
            default: ;
        endcase
    end
endmodule
