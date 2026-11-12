// DMG/CGB PPU. One dot per ce_t. ce marks M-cycle boundaries (subset of clk, coincident with a CPU bus edge).
// VRAM: 2 x 8 KiB on a single BSRAM port shared with the CPU (CPU locked out in mode 3, as on hardware).
// The CPU reaches the bank chosen by VBK (FF4F, CGB mode only). In CGB mode the renderer reads the
// BG/window attribute map from bank 1 and tile data from the bank chosen by the tile/object attribute.
// OAM: 4 x 64x8 distributed RAM banks -> one whole sprite entry per dot during OAM scan.
// Sprites are fetched at the start of mode 3 and merged with a per-sprite stall (single merge unit).
// Colour RAM (FF68-FF6B): 4 x 32x8 distributed RAMs with one shared read port: the renderer owns it in
// mode 3 (when CPU data accesses are blocked, as on hardware) and the CPU otherwise.
// Outputs: pix = DMG shade through BGP/OBP0/OBP1 (both modes); pix_rgb = CGB colour RAM RGB555
// {B,G,R} in CGB mode, a grey rendering of the DMG shade otherwise.
module ppu (
    input             clk,
    input             rst,
    input             ce_t,
    input             ce,
    input             cgb_mode,
    input             cgb_hw,     // physical CGB register availability, independent of compatibility mode
    input             cgb_post_boot, // bypassed CGB boot-ROM palette-index state
    input             dmg_color,   // CGB running a DMG cart: shades index palette RAM 0 (BG), 0/1 (OBJ)
    input             boot,        // power-on through a boot ROM: LCD starts off
    input      [15:0] cpu_addr,
    input             cpu_wr,      // already qualified with ce
    input      [7:0]  cpu_din,
    output reg [7:0]  cpu_dout,
    input             vram_sel,
    input             vram_dma,    // CGB DMA owns VRAM even during mode 3
    input             oam_dma_vram, // OAM DMA source is VRAM: read oam_dma_addr through the CPU port
    input      [12:0] oam_dma_addr,
    output     [7:0]  oam_dma_vq,
    input             oam_sel,
    input             reg_sel,     // FF40-FF45, FF47-FF4B, FF4F, FF68-FF6C
    input             dma_act,
    input             dma_we,
    input      [7:0]  dma_idx,
    input      [7:0]  dma_data,
    output reg        irq_vblank,
    output reg        irq_stat,
    output reg        pix_we,
    output reg [1:0]  pix,
    output reg [14:0] pix_rgb,
    output reg [7:0]  pix_x,
    output     [7:0]  pix_y,
    output reg        vsync,       // pulse at start of frame (LY=0, dot 0) while LCD on
    output            lcd_on,
    output            hblank
);
    // ---------------- registers ----------------
    reg [7:0] LCDC, SCY, SCX, LYC, BGP, OBP0, OBP1, WY, WX;
    reg [3:0] STATW;              // STAT bits 6..3
    reg vbk;                      // FF4F VRAM bank (CGB mode only)
    reg [6:0] bcps, ocps;         // FF68/FF6A {auto-increment, address}
    reg opri;                     // FF6C: stored only; the priority mode is latched by the boot ROM (CGB: OAM order)
    reg [7:0] ly;
    reg [8:0] dot;
    reg [1:0] mode;
    reg lyc_match;               // comparison clock stops with LCD off; STAT bit 2 is retained
    assign pix_y = ly;
    assign lcd_on = LCDC[7];
    assign hblank = LCDC[7] && ly < 8'd144 && mode == 2'd0;

    wire cpu_vram_ok = mode != 2'd3;
    wire cpu_oam_ok  = !mode[1] && !dma_act;
    wire cpu_pal_ok  = mode != 2'd3;

    // ---------------- VRAM ----------------
    reg [7:0] vram [0:16383];
    reg [13:0] v_addr;
    reg v_we;
    reg [7:0] v_q;
    always @(posedge clk) begin
        if (v_we) vram[v_addr] <= cpu_din;
        v_q <= vram[v_addr];
    end
    reg cpu_slot1, cpu_slot2;     // clk after ce: CPU read issue; clk after that: capture
    reg [7:0] cpu_vq;
    wire cpu_vwr = cpu_wr && vram_sel && (cpu_vram_ok || vram_dma);
    wire cpu_vrd = cpu_slot1 && (vram_sel || oam_dma_vram) && cpu_vram_ok;
    wire cpu_owns = cpu_vwr || cpu_vrd;
    reg [13:0] ppu_va;            // driven combinationally below: {bank, offset}
    reg ppu_vreq;
    wire ppu_gnt = ce_t && ppu_vreq && !cpu_owns;
    always @(*) begin
        v_we = cpu_vwr;
        v_addr = cpu_owns ? {vbk & cgb_mode, oam_dma_vram ? oam_dma_addr : cpu_addr[12:0]} : ppu_va;
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
    assign oam_dma_vq = cpu_vq;

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

    // ---------------- sprite slots ----------------
    reg [7:0] s_x  [0:9];
    reg [12:0] s_ad[0:9];         // {tile, row-in-object, yflip}; size applied at fetch (mode 3) like hw
    reg [7:0] s_lo [0:9], s_hi[0:9];
    reg [6:0] s_at [0:9];         // {prio, xflip, DMG pal, CGB bank, CGB pal[2:0]}
    reg [3:0] s_cnt, s_seen, s_fp; // 10-hit OAM limit; only X<168 entries need pattern fetches
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
    reg [7:0] f_tile, f_lo, f_attr;
    reg [7:0] l_lo, l_hi; reg [3:0] l_at; reg l_valid;
    reg [7:0] sh_lo, sh_hi; reg [3:0] sh_at; reg [3:0] sh_cnt;   // *_at = {BG priority, CGB palette}
    reg [7:0] px;                // 0..167, screen x = px-8
    reg [6:0] obj_penalty;        // exact mode-3 OBJ stalls accumulated left-to-right
    reg [5:0] obj_tile;
    reg obj_tile_valid;
    reg [2:0] discard;
    reg win_mode, win_line_used, wy_hit;
    reg [7:0] wly;
    reg [15:0] sfifo;            // 8 x 2-bit colour (MSB first)
    reg [23:0] sf_pal;           // 8 x 3-bit CGB palette
    reg [7:0] sf_dp;             // per pixel DMG OBP0/OBP1 select (shade output in both modes)
    reg [31:0] sf_oam;           // 8 x 4-bit slot (= OAM order) for CGB object priority
    reg [7:0] sf_pri;            // per pixel OBJ-behind-BG flag (bit7 = next out)

    wire [7:0] bgy = ly + SCY;
    wire [2:0] fy = win_mode ? wly[2:0] : bgy[2:0];
    wire [9:0] map_off = win_mode ? {wly[7:3], ftx} : {bgy[7:3], SCX[7:3] + ftx};
    wire map_sel = win_mode ? LCDC[6] : LCDC[3];
    wire [12:0] map_addr = {2'b11, map_sel, map_off};
    // CGB attribute {prio, yflip, xflip, -, bank, pal}: read from bank 1 in step 1, arrives in step 2
    // (where it already steers the low-byte address) and is held in f_attr afterwards.
    wire [7:0] cur_attr = !cgb_mode ? 8'd0 : fstep == 3'd2 ? ppu_vd : f_attr;
    wire [2:0] fya = cur_attr[6] ? ~fy : fy;
    wire [13:0] tdat_addr = {cur_attr[3], LCDC[4] ? 1'b0 : ~f_tile[7], f_tile[7], f_tile[6:0], fya, 1'b0};

    // sprite to merge this dot: lowest slot whose x == px
    reg [3:0] m_s; reg m_hit;
    integer k;
    always @(*) begin
        m_hit = 0; m_s = 0;
        for (k = 9; k >= 0; k = k - 1)
            if (k < s_cnt && !s_done[k] && s_x[k] == px) begin m_hit = 1; m_s = k; end
    end
    wire spr_on = LCDC[1];
    wire [8:0] obj_pos = {1'b0, s_x[m_s]} + {1'b0, SCX};
    wire [5:0] obj_tile_now = obj_pos[8:3];
    wire [2:0] obj_phase = obj_pos[2:0];
    wire [3:0] obj_wait = obj_phase < 5 ? 5 - obj_phase : 0;
    wire [8:0] mode3_last = 9'd251 + {6'd0, SCX[2:0]} + obj_penalty +
                            (win_line_used ? 9'd6 : 9'd0);

    // ---------------- pixel mixer (head of the BG shifter and sprite FIFO) ----------------
    // DMG: LCDC.0 blanks BG/window; OBJ wins unless its behind-BG flag is set and BG colour != 0.
    // CGB: BG always drawn; LCDC.0 clear = OBJ always on top; otherwise BG colour 1-3 wins if
    // either the BG attribute or the OAM attribute priority bit is set.
    wire [1:0] r_bgc = (cgb_mode || LCDC[0]) ? {sh_hi[7], sh_lo[7]} : 2'd0;
    wire [1:0] r_spc = sfifo[15:14];
    wire r_obj = spr_on && r_spc != 2'd0 &&
                 (r_bgc == 2'd0 || (cgb_mode ? !LCDC[0] || (!sh_at[3] && !sf_pri[7]) : !sf_pri[7]));
    wire [1:0] r_col = r_obj ? r_spc : r_bgc;
    wire [7:0] r_dpal = r_obj ? (sf_dp[7] ? OBP1 : OBP0) : BGP;
    wire [1:0] r_shade = r_dpal[{r_col, 1'b0} +: 2];
    reg [4:0] r_grey;
    always @(*) case (r_shade)
        2'd0: r_grey = 5'd31; 2'd1: r_grey = 5'd21; 2'd2: r_grey = 5'd10; default: r_grey = 5'd0;
    endcase

    // ---------------- colour RAM (CGB) ----------------
    reg [7:0] bcr_lo [0:31], bcr_hi [0:31], ocr_lo [0:31], ocr_hi [0:31];
    integer pi;
    initial for (pi = 0; pi < 32; pi = pi + 1) begin   // boot ROM leaves every BG colour white
        bcr_lo[pi] = 8'hFF; bcr_hi[pi] = 8'h7F;
    end
    wire bcpd_wr = cgb_mode && cpu_wr && reg_sel && cpu_addr[7:0] == 8'h69;
    wire ocpd_wr = cgb_mode && cpu_wr && reg_sel && cpu_addr[7:0] == 8'h6B;
    always @(posedge clk) if (cpu_pal_ok) begin
        if (bcpd_wr && !bcps[0]) bcr_lo[bcps[5:1]] <= cpu_din;
        if (bcpd_wr &&  bcps[0]) bcr_hi[bcps[5:1]] <= cpu_din;
        if (ocpd_wr && !ocps[0]) ocr_lo[ocps[5:1]] <= cpu_din;
        if (ocpd_wr &&  ocps[0]) ocr_hi[ocps[5:1]] <= cpu_din;
    end
    // In DMG-compatibility mode the boot ROM's palettes colour the DMG shades:
    // BG shade n -> BG palette 0 colour n, OBJ shade n -> OBJ palette OBP0/OBP1 colour n.
    wire [4:0] bcr_ri = mode != 2'd3 ? bcps[5:1] : dmg_color ? {3'd0, r_shade} : {sh_at[2:0], r_bgc};
    wire [4:0] ocr_ri = mode != 2'd3 ? ocps[5:1] : dmg_color ? {2'd0, sf_dp[7], r_shade} : {sf_pal[23:21], r_spc};
    wire [7:0] bcr_lq = bcr_lo[bcr_ri], bcr_hq = bcr_hi[bcr_ri];
    wire [7:0] ocr_lq = ocr_lo[ocr_ri], ocr_hq = ocr_hi[ocr_ri];
    wire [14:0] r_rgb = !(cgb_mode || dmg_color) ? {r_grey, r_grey, r_grey} :
                        r_obj ? {ocr_hq[6:0], ocr_lq} : {bcr_hq[6:0], bcr_lq};

    // ---------------- CPU reads ----------------
    wire lyc_eq = lyc_match;
    always @(*) begin
        cpu_dout = 8'hFF;
        if (vram_sel) cpu_dout = cpu_vram_ok ? cpu_vq : 8'hFF;
        else if (oam_sel) begin
            if (cpu_oam_ok) case (cpu_addr[1:0])
                2'd0: cpu_dout = o_y; 2'd1: cpu_dout = o_x; 2'd2: cpu_dout = o_t; default: cpu_dout = o_a;
            endcase
        end else if (cpu_addr[5]) begin          // FF68-FF6C
            if (cgb_hw) case (cpu_addr[3:0])
                4'h8: cpu_dout = {bcps[6], 1'b1, bcps[5:0]};
                4'h9: cpu_dout = cgb_mode && cpu_pal_ok ? (bcps[0] ? bcr_hq : bcr_lq) : 8'hFF;
                4'hA: cpu_dout = {ocps[6], 1'b1, ocps[5:0]};
                4'hB: cpu_dout = cgb_mode && cpu_pal_ok ? (ocps[0] ? ocr_hq : ocr_lq) : 8'hFF;
                4'hC: cpu_dout = cgb_mode ? {7'h7F, opri} : 8'hFF;
                default: ;
            endcase
        end else case (cpu_addr[3:0])            // FF40-FF4F
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
            4'hF: cpu_dout = cgb_hw ? {7'h7F, vbk} : 8'hFF;
            default: cpu_dout = 8'hFF;
        endcase
    end

    // STAT interrupt line
    // The FPGA is CGB hardware even while a DMG cart selects compatibility mode.
    wire cgb_pre_vblank_m2 = ly == 8'd143 && dot >= 9'd452;
    wire stat_line = (STATW[3] && lyc_eq) ||
                     (LCDC[7] && ((STATW[2] && (mode == 2'd2 || cgb_pre_vblank_m2)) ||
                                  (STATW[1] && mode == 2'd1) ||
                                  (STATW[0] && mode == 2'd0)));
    reg stat_prev;
    reg [2:0] vb_delay;

    reg [7:0] mlo, mhi;
    reg [1:0] mc;
    integer j;

    always @(posedge clk) begin
        irq_vblank <= 0; irq_stat <= 0; pix_we <= 0; vsync <= 0;
        if (rst) begin
            LCDC <= boot ? 8'h00 : 8'h91; STATW <= 0; SCY <= 0; SCX <= 0; LYC <= 0; vbk <= 0;
            BGP <= 8'hFC; OBP0 <= 8'hFF; OBP1 <= 8'hFF; WY <= 0; WX <= 0;
            bcps <= cgb_post_boot ? 7'h48 : 0; ocps <= cgb_post_boot ? 7'h50 : 0; opri <= 0;
            ly <= 0; dot <= 0; mode <= 2'd2; lyc_match <= 1; stat_prev <= 0; vb_delay <= 0;
            obj_penalty <= 0; obj_tile_valid <= 0;
            s_cnt <= 0; s_seen <= 0; s_fp <= 0; s_fhi <= 0; s_pend <= 0;
            wy_hit <= 0; wly <= 0;
        end else begin
            // register writes (at ce)
            if (cpu_wr && reg_sel) begin
                if (cpu_addr[5]) begin                  // FF68-FF6C
                    // BCPD/OCPD writes auto-increment even when blocked in mode 3; reads never do
                    if (cgb_hw) case (cpu_addr[3:0])
                        4'h8: bcps <= {cpu_din[7], cpu_din[5:0]};
                        4'h9: if (cgb_mode && bcps[6]) bcps[5:0] <= bcps[5:0] + 6'd1;
                        4'hA: ocps <= {cpu_din[7], cpu_din[5:0]};
                        4'hB: if (cgb_mode && ocps[6]) ocps[5:0] <= ocps[5:0] + 6'd1;
                        4'hC: if (cgb_mode) opri <= cpu_din[0];
                        default: ;
                    endcase
                end else case (cpu_addr[3:0])           // FF40-FF4F
                    4'h0: begin
                        LCDC <= cpu_din;
                        // Restarting the LCD restarts the comparison clock at LY=0.
                        // Turning it off deliberately retains the previous comparison bit.
                        if (!LCDC[7] && cpu_din[7]) lyc_match <= LYC == 0;
                    end
                    4'h1: STATW <= cpu_din[6:3];
                    4'h2: SCY <= cpu_din;
                    4'h3: SCX <= cpu_din;
                    4'h5: LYC <= cpu_din;
                    4'h7: BGP <= cpu_din;
                    4'h8: OBP0 <= cpu_din;
                    4'h9: OBP1 <= cpu_din;
                    4'hA: WY <= cpu_din;
                    4'hB: WX <= cpu_din;
                    4'hF: if (cgb_hw) vbk <= cpu_din[0];
                    default: ;
                endcase
            end

            if (ce_t) begin
                stat_prev <= stat_line;
                if (stat_line && !stat_prev) irq_stat <= 1;
                if (vb_delay != 0) begin
                    vb_delay <= vb_delay - 1'b1;
                    if (vb_delay == 1) irq_vblank <= 1;
                end
            end

            if (!LCDC[7]) begin
                ly <= 0; dot <= 0; mode <= 2'd0; vb_delay <= 0;
            end else if (ce_t) begin
                // While running, the coincidence clock follows LY/LYC. At a line boundary
                // compare the LY value that becomes visible on this same dot.
                if (dot == 9'd455)
                    lyc_match <= (ly == 8'd153 ? 8'd0 : ly + 1'b1) == LYC;
                else
                    lyc_match <= ly == LYC;
                // ---------------- dot / line counters ----------------
                if (dot == 9'd455) begin
                    dot <= 0;
                    if (win_line_used) wly <= wly + 1;
                    if (ly == 8'd153) begin
                        ly <= 0; mode <= 2'd2; wly <= 0; wy_hit <= 0; vsync <= 1;
                    end else begin
                        ly <= ly + 1;
                        if (ly == 8'd143) begin mode <= 2'd1; vb_delay <= 3'd1; end
                        else if (ly < 8'd143) mode <= 2'd2;
                    end
                    s_cnt <= 0; s_seen <= 0; s_fp <= 0; s_fhi <= 0; s_pend <= 0; scan_i <= 0;
                end else dot <= dot + 1;

                // ---------------- mode 2: OAM scan ----------------
                if (mode == 2'd2) begin
                    if (dot == 0) begin
                        if (ly == WY) wy_hit <= 1;
                        win_line_used <= 0;
                    end
                    if (!dot[0] && dot < 9'd80) begin
                        if (s_hit && s_seen < 4'd10) begin
                            s_seen <= s_seen + 1'b1;
                            if (o_x < 8'd168) begin
                                s_x[s_cnt]  <= o_x;
                                s_ad[s_cnt] <= {o_t, yrel[3:0], o_a[6]};
                                s_at[s_cnt] <= {o_a[7], o_a[5], o_a[4], o_a[3] & cgb_mode, o_a[2:0]};
                                s_cnt <= s_cnt + 1'b1;
                            end
                        end
                    end else if (dot[0]) scan_i <= scan_i + 1;
                end

                // sprite pattern fetch: runs at the start of mode 3 until all slots are fetched
                if (s_pend) begin
                    if (s_phi) s_hi[s_pslot] <= s_at[s_pslot][5] ? rev(ppu_vd) : ppu_vd;
                    else       s_lo[s_pslot] <= s_at[s_pslot][5] ? rev(ppu_vd) : ppu_vd;
                end
                s_pend <= 0;

                // ---------------- mode 3 ----------------
                if (mode == 2'd2 && dot == 9'd79) begin
                    mode <= 2'd3;
                    fstep <= 0; ftx <= 0; l_valid <= 0; sh_cnt <= 0; px <= 0;
                    obj_penalty <= 0; obj_tile_valid <= 0;
                    discard <= SCX[2:0]; win_mode <= 0; s_done <= 0;
                    sfifo <= 0; sf_pal <= 0; sf_dp <= 0; sf_pri <= 0; sf_oam <= 0;
                end

                if (mode == 2'd3 && px == 8'd168) begin
                    if (dot >= mode3_last) mode <= 2'd0;
                end else if (mode == 2'd3 && !s_busy) begin
                    // BG fetcher (only after sprite fetch has drained). DMG/CGB share the schedule;
                    // CGB adds the bank-1 attribute read in the otherwise idle step 1.
                    case (fstep)
                        3'd0: if (ppu_gnt) fstep <= 1;
                        3'd1: begin f_tile <= ppu_vd; fstep <= 2; end
                        3'd2: if (ppu_gnt) begin f_attr <= cur_attr; fstep <= 3; end
                        3'd3: begin f_lo <= ppu_vd; fstep <= 4; end
                        3'd4: if (ppu_gnt) fstep <= 5;
                        3'd5: begin
                            l_lo <= f_attr[5] ? rev(f_lo) : f_lo;
                            l_hi <= f_attr[5] ? rev(ppu_vd) : ppu_vd;
                            l_at <= {f_attr[7], f_attr[2:0]};
                            l_valid <= 1; fstep <= 6;
                        end
                        default: if (!l_valid) begin fstep <= 0; ftx <= ftx + 1; end
                    endcase

                    if (spr_on && m_hit) begin
                        obj_penalty <= obj_penalty + 7'd6 +
                                       ((!obj_tile_valid || obj_tile_now != obj_tile) ?
                                        obj_wait : 4'd0);
                        obj_tile <= obj_tile_now;
                        obj_tile_valid <= 1;
                        // merge sprite into sprite FIFO; costs this dot. Transparent FIFO pixels always
                        // take the sprite; in CGB mode a lower OAM slot also replaces an opaque pixel
                        // (OAM-order priority), in DMG mode the earlier (lower X) sprite stays.
                        mlo = s_lo[m_s]; mhi = s_hi[m_s];
                        for (j = 0; j < 8; j = j + 1) begin
                            mc = {mhi[7-j], mlo[7-j]};
                            if (mc != 2'd0 && (sfifo[15-2*j -: 2] == 2'd0 ||
                                               (cgb_mode && m_s < sf_oam[31-4*j -: 4]))) begin
                                sfifo[15-2*j -: 2] <= mc;
                                sf_pal[23-3*j -: 3] <= s_at[m_s][2:0];
                                sf_dp[7-j] <= s_at[m_s][4];
                                sf_pri[7-j] <= s_at[m_s][6];
                                sf_oam[31-4*j -: 4] <= m_s;
                            end
                        end
                        s_done[m_s] <= 1;
                    end else if (px < 8'd8) begin
                        px <= px + 1;
                        sfifo <= sfifo << 2; sf_pal <= sf_pal << 3; sf_dp <= sf_dp << 1;
                        sf_pri <= sf_pri << 1; sf_oam <= sf_oam << 4;
                        if (sh_cnt == 0 && l_valid) begin
                            sh_lo <= l_lo; sh_hi <= l_hi; sh_at <= l_at; sh_cnt <= 8; l_valid <= 0;
                        end
                    end else if (LCDC[5] && wy_hit && !win_mode && WX < 8'd167 && px >= WX + 8'd1) begin
                        // window start: restart fetcher on the window map
                        win_mode <= 1; win_line_used <= 1; fstep <= 0; ftx <= 0;
                        l_valid <= 0; sh_cnt <= 0; discard <= 0;
                    end else if (sh_cnt != 0) begin
                        sh_lo <= sh_lo << 1; sh_hi <= sh_hi << 1;
                        if (sh_cnt == 4'd1 && l_valid) begin
                            sh_lo <= l_lo; sh_hi <= l_hi; sh_at <= l_at; sh_cnt <= 8; l_valid <= 0;
                        end else sh_cnt <= sh_cnt - 1;
                        if (discard != 0) discard <= discard - 1;
                        else begin
                            pix <= r_shade;
                            pix_rgb <= r_rgb;
                            pix_x <= px - 8'd8; pix_we <= 1;
                            sfifo <= sfifo << 2; sf_pal <= sf_pal << 3; sf_dp <= sf_dp << 1;
                            sf_pri <= sf_pri << 1; sf_oam <= sf_oam << 4;
                            px <= px + 1;
                            if (px == 8'd167) px <= 8'd168;
                        end
                    end else if (sh_cnt == 0 && l_valid) begin
                        sh_lo <= l_lo; sh_hi <= l_hi; sh_at <= l_at; sh_cnt <= 8; l_valid <= 0;
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
        ppu_vreq = 0; ppu_va = {1'b0, map_addr};
        if (LCDC[7] && mode == 2'd3 && s_fp != s_cnt) begin
            ppu_vreq = 1; ppu_va = {s_at[s_fp][3], 1'b0, f_stile, f_srow[2:0], s_fhi};
        end else if (LCDC[7] && mode == 2'd3 && !s_busy) case (fstep)
            3'd0: begin ppu_vreq = 1; ppu_va = {1'b0, map_addr}; end
            3'd1: begin ppu_vreq = cgb_mode; ppu_va = {1'b1, map_addr}; end
            3'd2: begin ppu_vreq = 1; ppu_va = tdat_addr; end
            3'd4: begin ppu_vreq = 1; ppu_va = tdat_addr | 14'd1; end
            default: ;
        endcase
    end
endmodule
