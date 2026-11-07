// Writes a .gb image byte stream into PSRAM (via psram_bridge) from address 0, decodes the header
// (0x147 mapper, 0x148 ROM size, 0x149 RAM size) and reports `done` after the last ROM byte.
module cart_loader (
    input             clk,
    input             start,        // pulse: begin a new image
    input             in_v,
    input      [7:0]  in_d,
    output            full,         // producer must not present in_v while full
    output reg        done,
    // PSRAM bridge
    output            m_req,
    output     [21:0] m_addr,
    output     [7:0]  m_wd,
    input             m_busy,
    // decoded header (valid after done)
    output reg        cgb_mode,     // ROM header 0x143 bit 7; banking groundwork, not full GBC support
    output reg [1:0]  cart_type,    // 0 none, 1 MBC1, 2 MBC3, 3 MBC5
    output reg        cart_rtc,     // header types 0F/10 have an MBC3 timer
    output reg        cart_ram,     // header RAM size is nonzero
    output reg [8:0]  rom_mask,
    output reg [3:0]  ram_mask,
    output reg [7:0]  sum
);
    reg [21:0] idx, last;
    reg slot_v; reg [7:0] slot;
    reg active;
    assign full = slot_v || m_busy;
    assign m_req = active && slot_v && !m_busy;
    assign m_addr = idx;
    assign m_wd = slot;
    always @(posedge clk) begin
        if (start) begin
            idx <= 0; last <= 22'h3DFFFF; slot_v <= 0; active <= 1; done <= 0; sum <= 0;
            cgb_mode <= 0; cart_rtc <= 0; cart_ram <= 0;
        end else begin
            if (in_v && active) begin slot <= in_d; slot_v <= 1; end
            if (m_req) begin
                slot_v <= 0; idx <= idx + 1; sum <= sum + slot;
                case (idx)
                    22'h143: cgb_mode <= slot[7];
                    22'h147: begin
                        cart_type <= (slot >= 8'h01 && slot <= 8'h03) ? 2'd1 :
                                     (slot >= 8'h0F && slot <= 8'h13) ? 2'd2 :
                                     (slot >= 8'h19 && slot <= 8'h1E) ? 2'd3 : 2'd0;
                        cart_rtc <= slot == 8'h0F || slot == 8'h10;
                    end
                    22'h148: if (slot <= 8'd7) begin              // 32 KB << n (n <= 7 fits 4 MB die)
                                 last <= (22'h8000 << slot) - 1;
                                 rom_mask <= (9'd2 << slot) - 1;
                             end
                    22'h149: begin
                        ram_mask <= slot == 8'h03 ? 4'h3 : slot == 8'h04 ? 4'hF :
                                    slot == 8'h05 ? 4'h7 : 4'h0;
                        cart_ram <= slot >= 8'h01 && slot <= 8'h05;
                    end
                    default: ;
                endcase
                if (idx == last) begin active <= 0; done <= 1; end
            end
        end
    end
endmodule
