; Tang gallery: the FPGA's game launcher, itself a small GBC game.
; A wall of pinned game cards, seven per page (GTA 2 character-select style): three up,
; four down, at uneven heights. The selected card is in full colour with a white frame,
; the others are dimmed. Left/right cycle through the cards and pages, up/down change rows,
; A or Start launches.
; host/menu.py fills in graphics, palettes and the game records; this file is only the
; engine. Rebuild engine.bin with `make arcade` after editing.

DEF rP1    EQU $FF00
DEF rSB    EQU $FF01
DEF rSC    EQU $FF02
DEF rIF    EQU $FF0F
DEF rLCDC  EQU $FF40
DEF rLY    EQU $FF44
DEF rVBK   EQU $FF4F
DEF rHDMA1 EQU $FF51
DEF rHDMA2 EQU $FF52
DEF rHDMA3 EQU $FF53
DEF rHDMA4 EQU $FF54
DEF rHDMA5 EQU $FF55
DEF rBCPS  EQU $FF68
DEF rBCPD  EQU $FF69
DEF rOCPS  EQU $FF6A
DEF rOCPD  EQU $FF6B
DEF rDMA   EQU $FF46
DEF rIE    EQU $FFFF

; ---- fixed layout shared with menu.py ----
DEF FONT_TILES   EQU $2000   ; bank 0 tiles 0-255: heading font, wall, frame sprites
DEF BANK1_TILES  EQU $3000   ; bank 1 tiles 140-255: tall banner font and banner pieces
DEF BG_MAP       EQU $3740   ; 32x18 tile map
DEF BG_ATTR      EQU $3980   ; 32x18 attributes
DEF BG_PALS      EQU $3BC0   ; 8 palettes x 8 bytes, see PAL_*
DEF OBJ_PALS     EQU $3C00
DEF IDLE_TEXT    EQU $3C10   ; 2 x 20 banner rows when the library is empty
DEF LOAD_TEXT    EQU $3C40   ; 2 x 20 banner rows while loading
DEF BLANK_RECORD EQU $3C80   ; record shown for empty card slots
DEF GAME_COUNT   EQU $3FF0   ; 16-bit
DEF LAST_PAGE    EQU $3FF2   ; 16-bit index of the last page's first game

DEF PAGE       EQU 7         ; cards per page: 0-2 top row, 3-6 bottom row
DEF CARD_TILES EQU 20        ; 32x40 art, VRAM bank 1, tiles 20 * card

; BG palettes. Unselected cards share one grey palette (card colours are sorted darkest
; first), so only the selected card needs its own; selection moves by rewriting attributes.
DEF PAL_WALL   EQU 0         ; also empty slots (their art is wall texture)
DEF PAL_DIM    EQU 1
DEF PAL_SEL    EQU 2
DEF PAL_HIDDEN EQU 5         ; cards not loaded yet: flat wall colour

; record layout (512 bytes, banks 1+, 32 per bank)
DEF R_PAL    EQU CARD_TILES * 16
DEF R_BANNER EQU R_PAL + 8   ; 2 x 20 bank-1 tile numbers (tall font, banner pieces)
DEF R_PLAY   EQU R_BANNER + 40

DEF FRAME_TILE EQU 252       ; 8x16 sprites: horizontal edge pair, vertical edge pair

; ---- WRAM ----
SECTION "shadow oam", WRAM0[$C000]
wOAM: ds 160
SECTION "state", WRAM0[$C100]
wBase:    ds 2     ; index of this page's first game
wSel:     ds 1     ; selected card 0-6
wOnPage:  ds 1     ; cards on this page
wLoad:    ds 1     ; next card to load (one per frame), PAGE = all loaded
wPalDirty: ds 1    ; bit n: card n's palette needs rewriting (VBlank only fits a few)
wPalWork: ds 1
wBudget:  ds 1     ; card updates left in this VBlank
wBannerDirty: ds 1
wFrame:   ds 1
wPad:     ds 1
wPressed: ds 1
wLaunch:  ds 1     ; 0 idle, >0 launch blink countdown, $FF sent
wFx:      ds 1     ; selected card position, screen pixels
wFy:      ds 1
wEnd:

SECTION "header", ROM0[$100]
    nop
    jp Start
    ds $150 - @, 0

SECTION "engine", ROM0[$150]
Start:
    di
    ld sp, $FFFE
    xor a
    ldh [rIE], a
    call WaitVBlankPoll
    xor a
    ldh [rLCDC], a
    ; double speed: twice the VBlank budget for card loads
    ld a, $30
    ldh [rP1], a
    ld a, 1
    ldh [$FF4D], a
    stop

    ld hl, FONT_TILES
    ld de, $8000
    ld c, 128
    call Gdma
    ld hl, FONT_TILES + 128 * 16
    ld de, $8800
    ld c, 128
    call Gdma
    ld a, 1
    ldh [rVBK], a
    ld hl, BANK1_TILES
    ld de, $8000 + PAGE * CARD_TILES * 16
    ld c, 116
    call Gdma
    xor a
    ldh [rVBK], a
    ld hl, BG_MAP
    ld de, $9800
    ld c, 36
    call Gdma
    ld a, 1
    ldh [rVBK], a
    ld hl, BG_ATTR
    ld de, $9800
    ld c, 36
    call Gdma
    xor a
    ldh [rVBK], a
    ld a, $80
    ldh [rBCPS], a
    ld hl, BG_PALS
    ld b, 64
.bgp:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .bgp
    ld a, $80
    ldh [rOCPS], a
    ld hl, OBJ_PALS
    ld b, 8
.obp:
    ld a, [hl+]
    ldh [rOCPD], a
    dec b
    jr nz, .obp

    ld hl, DmaRoutine
    ld de, $FF80
    ld b, DmaRoutineEnd - DmaRoutine
.copydma:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copydma

    ld hl, wOAM
    ld b, 160
    xor a
.clroam:
    ld [hl+], a
    dec b
    jr nz, .clroam
    ld hl, wBase
    ld b, wEnd - wBase
.clrstate:
    ld [hl+], a
    dec b
    jr nz, .clrstate
    call CountPage
    ; LCD is off: load the whole first page at once
    ld c, 0
.first:
    push bc
    call LoadCard
    pop bc
    inc c
    ld a, c
    cp PAGE
    jr nz, .first
    ld [wLoad], a
.cards:                        ; LCD is off: no budget, finish every card now
    call UpdateCards
    ld a, [wPalDirty]
    or a
    jr nz, .cards
    call DrawBanner
    call UpdateSprites
    call $FF80
    ld a, %10010111      ; LCD, tiles 8000, BG 9800, OBJ 8x16 on, BG on
    ldh [rLCDC], a

MainLoop:
    call WaitVBlank
    call $FF80                 ; OAM DMA from wOAM
    ; VRAM and palettes are locked while a line is drawn, so the VBlank work is budgeted:
    ; banner (40 writes), one card load (GDMA), then at most two card recolours.
    ld a, [wBannerDirty]
    or a
    jr z, .nobanner
    xor a
    ld [wBannerDirty], a
    call DrawBanner
.nobanner:
    ld a, [wLoad]
    cp PAGE
    jr nc, .loaded
    ld c, a
    inc a
    ld [wLoad], a
    call LoadCard              ; one card per VBlank: the page fills in card by card
.loaded:
    ld a, [wPalDirty]
    or a
    call nz, UpdateCards
    ld hl, wFrame
    inc [hl]
    call ReadPad
    call UpdateCursor
    call UpdateLaunch
    call UpdateSprites
    jr MainLoop

; ---------------- helpers ----------------
WaitVBlankPoll:
    ldh a, [rLY]
    cp 144
    jr nz, WaitVBlankPoll
    ret

; HALT until the next VBlank (IME stays 0: the flag wakes the CPU, no handler runs)
WaitVBlank:
    xor a
    ldh [rIF], a
    ld a, 1
    ldh [rIE], a
    halt
    nop
    ret

; GDMA c blocks of 16 bytes from hl to de (both 16-byte aligned)
Gdma:
    ld a, h
    ldh [rHDMA1], a
    ld a, l
    ldh [rHDMA2], a
    ld a, d
    ldh [rHDMA3], a
    ld a, e
    ldh [rHDMA4], a
    ld a, c
    dec a
    ldh [rHDMA5], a
    ret

DmaRoutine:
    ld a, HIGH(wOAM)
    ldh [rDMA], a
    ld a, 40
.wait:
    dec a
    jr nz, .wait
    ret
DmaRoutineEnd:

; hl = game index -> hl = record pointer, MBC5 bank selected; empty slots use BLANK_RECORD
Record:
    ld a, [GAME_COUNT + 1]
    cp h
    jr c, .blank
    jr nz, .valid
    ld a, [GAME_COUNT]
    dec a
    cp l
    jr c, .blank
    ld a, [GAME_COUNT]
    or a
    jr z, .blank
.valid:
    ; bank = index / 32 + 1, pointer = $4000 + (index % 32) * 512
    ld a, l
    and %00011111
    add a
    add $40
    ld b, a                     ; high byte of the pointer
    ld a, l
    srl h
    rra
    srl h
    rra
    srl h
    rra
    srl h
    rra
    srl h
    rra                         ; a = index / 32 (low 8 bits are enough for 4064 games)
    inc a
    ld [$2000], a
    xor a
    ld [$3000], a
    ld h, b
    ld l, 0
    ret
.blank:
    ld hl, BLANK_RECORD
    ret

; l = card 0-6 -> hl = game index (wBase + card)
SlotIndex:
    ld h, 0
    ld a, [wBase]
    add l
    ld l, a
    ld a, [wBase + 1]
    adc h
    ld h, a
    ret

; c = card: art tiles -> VRAM bank 1, tiles CARD_TILES * card
LoadCard:
    ld a, c
    call MarkPal
    ld l, c
    push bc
    call SlotIndex
    call Record
    pop bc
    push hl
    ld hl, $8000
    ld de, CARD_TILES * 16
    ld a, c
    or a
    jr z, .dest
.mul:
    add hl, de
    dec a
    jr nz, .mul
.dest:
    ld d, h
    ld e, l
    pop hl
    ld a, 1
    ldh [rVBK], a
    ld c, CARD_TILES
    call Gdma
    xor a
    ldh [rVBK], a
    ret

; a = card -> a = its bit in wPalDirty (keeps bc, de, hl)
CardBit:
    push bc
    ld b, a
    inc b
    ld a, %10000000
.shift:
    rlca
    dec b
    jr nz, .shift
    pop bc
    ret

; a = card: mark it for UpdateCards (keeps bc, de, hl)
MarkPal:
    call CardBit
    push bc
    ld b, a
    ld a, [wPalDirty]
    or b
    ld [wPalDirty], a
    pop bc
    ret

; Marked cards get their attributes: selected -> PAL_SEL (and its colours, blinking dim
; while launching), others PAL_DIM, empty slots PAL_WALL, not loaded yet PAL_HIDDEN.
UpdateCards:
    ld a, 2
    ld [wBudget], a
    ld a, [wPalDirty]
    ld [wPalWork], a
    ld c, 0
.card:
    ld a, [wPalWork]
    rrca
    ld [wPalWork], a
    jr nc, .next
    ld a, [wLoad]
    ld b, a
    ld a, c
    cp b
    ld b, PAL_HIDDEN
    jr nc, .attr
    ld a, [wOnPage]
    ld b, a
    ld a, c
    cp b
    ld b, PAL_WALL
    jr nc, .attr
    ld a, [wSel]
    cp c
    ld b, PAL_DIM
    jr nz, .attr
    push bc
    ld l, c
    call SlotIndex
    call Record
    ld de, R_PAL
    add hl, de
    ld a, [wLaunch]
    or a
    jr z, .colour
    inc a
    jr z, .colour               ; $FF: sent
    ld a, [wFrame]
    bit 2, a
    jr z, .colour
    ld hl, BG_PALS + PAL_DIM * 8
.colour:
    ld a, $80 | PAL_SEL * 8
    ldh [rBCPS], a
    ld b, 8
.w:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .w
    pop bc
    ld b, PAL_SEL
.attr:
    call CardAttr
    ld a, c                     ; done: clear its mark
    call CardBit
    cpl
    ld b, a
    ld a, [wPalDirty]
    and b
    ld [wPalDirty], a
    ld hl, wBudget
    dec [hl]
    ret z
.next:
    inc c
    ld a, c
    cp PAGE
    jr nz, .card
    ret

; c = card, b = palette: attribute (VRAM bank 1 tiles) for its 4x5 tiles (keeps c)
CardAttr:
    push bc
    ld a, c
    add a
    ld e, a
    ld d, 0
    ld hl, CardPos
    add hl, de
    ld a, [hl+]                 ; px
    rrca
    rrca
    rrca
    ld e, a                     ; column
    ld l, [hl]                  ; py: row * 32 = py * 4
    ld h, 0
    add hl, hl
    add hl, hl
    ld d, 0
    add hl, de
    ld de, $9800
    add hl, de
    ld a, b
    or $08
    ld b, a
    ld a, 1
    ldh [rVBK], a
    ld c, 5
.row:
    ld a, b
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld [hl+], a
    ld de, 28
    add hl, de
    dec c
    jr nz, .row
    xor a
    ldh [rVBK], a
    pop bc
    ret

; ---------------- banner (map rows 16-17, tall font) ----------------
DrawBanner:
    ld hl, LOAD_TEXT
    ld a, [wLaunch]
    or a
    jr nz, .copy
    ld hl, IDLE_TEXT
    ld a, [wOnPage]
    or a
    jr z, .copy
    ld a, [wSel]
    ld l, a
    call SlotIndex
    call Record
    ld de, R_BANNER
    add hl, de
.copy:
    ld de, $9800 + 16 * 32
    call Copy20
    ld de, $9800 + 17 * 32
Copy20:
    ld b, 20
.c:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .c
    ret

; ---------------- input ----------------
ReadPad:
    ld a, $20
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    cpl
    and $0F
    swap a
    ld b, a                     ; d-pad in the high nibble: down up left right
    ld a, $10
    ldh [rP1], a
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    ldh a, [rP1]
    cpl
    and $0F
    or b                        ; buttons low: start select b a
    ld b, a
    ld a, $30
    ldh [rP1], a
    ld a, [wPad]
    cpl
    and b
    ld [wPressed], a
    ld a, b
    ld [wPad], a
    ret

DEF PAD_A     EQU 0
DEF PAD_START EQU 3
DEF PAD_RIGHT EQU 4
DEF PAD_LEFT  EQU 5
DEF PAD_UP    EQU 6
DEF PAD_DOWN  EQU 7

; ---------------- cursor: cards 0-2 top row, 3-6 bottom row ----------------
UpdateCursor:
    ld a, [wLaunch]
    or a
    ret nz
    ld a, [wOnPage]
    or a
    ret z
    ld b, a
    ld a, [wPressed]
    bit PAD_RIGHT, a
    jr nz, .right
    bit PAD_LEFT, a
    jr nz, .left
    bit PAD_DOWN, a
    jr nz, .down
    bit PAD_UP, a
    ret z
    ld a, [wSel]
    cp 3
    ret c
    sub 3
    ld e, a
    ld d, 0
    ld hl, UpTab
    add hl, de
    ld a, [hl]
    jr .set
.right:
    ld a, [wSel]
    inc a
    cp b
    jr c, .set
    call NextPage
    xor a
    jr .set
.left:
    ld a, [wSel]
    or a
    jr z, .prev
    dec a
    jr .set
.prev:
    call PrevPage
    ld a, [wOnPage]
    dec a
    jr .set
.down:
    ld a, [wSel]
    cp 3
    ret nc
    ld e, a
    ld d, 0
    ld hl, DownTab
    add hl, de
    ld a, [hl]
    cp b
    jr c, .set
    ld a, b                     ; short bottom row: its last card
    dec a
    cp 3
    ret c
.set:
    push af
    ld a, [wSel]
    call MarkPal                ; the old card dims
    pop af
    ld [wSel], a
    call MarkPal                ; the new one lights up
    ld a, 1
    ld [wBannerDirty], a
    ret

; next page, wrapping after the last one; reloads only if the page changed
NextPage:
    ld a, [wBase]
    add PAGE
    ld l, a
    ld a, [wBase + 1]
    adc 0
    ld h, a
    ld a, [LAST_PAGE + 1]
    cp h
    jr c, .wrap
    jr nz, .set
    ld a, [LAST_PAGE]
    cp l
    jr nc, .set
.wrap:
    ld hl, 0
.set:
    ld a, [wBase]
    cp l
    jr nz, .change
    ld a, [wBase + 1]
    cp h
    ret z
.change:
    ld a, l
    ld [wBase], a
    ld a, h
    ld [wBase + 1], a
    xor a
    ld [wLoad], a
; wOnPage = min(6, count - base)
CountPage:
    ld a, [wBase]
    ld e, a
    ld a, [wBase + 1]
    ld d, a
    ld a, [GAME_COUNT]
    sub e
    ld l, a
    ld a, [GAME_COUNT + 1]
    sbc d
    jr nz, .six
    ld a, l
    cp PAGE
    jr c, .store
.six:
    ld a, PAGE
.store:
    ld [wOnPage], a
    ld a, %01111111             ; whole page
    ld [wPalDirty], a
    ret

PrevPage:
    ld a, [wBase]
    ld l, a
    ld a, [wBase + 1]
    ld h, a
    or l
    jr nz, .back
    ld a, [LAST_PAGE]
    ld l, a
    ld a, [LAST_PAGE + 1]
    ld h, a
    jr NextPage.set
.back:
    ld a, l
    sub PAGE
    ld l, a
    ld a, h
    sbc 0
    ld h, a
    jr NextPage.set

; ---------------- launching ----------------
UpdateLaunch:
    ld a, [wLaunch]
    cp $FF
    ret z
    or a
    jr nz, .blinking
    ld a, [wPressed]
    and (1 << PAD_A) | (1 << PAD_START)
    ret z
    ld a, [wOnPage]
    or a
    ret z
    ld a, [wSel]
    ld l, a
    call SlotIndex
    call Record
    ld de, R_PLAY
    add hl, de
    ld a, [hl]
    or a
    ret z                       ; unsupported image
    ld a, 40
    ld [wLaunch], a
    ld a, 1
    ld [wBannerDirty], a
    ret
.blinking:
    ld a, [wSel]
    call MarkPal
    ld hl, wLaunch
    dec [hl]
    ret nz
    ld [hl], $FF
    ; A5, index low, index high, low ^ high ^ 5A
    ld a, [wSel]
    ld l, a
    call SlotIndex
    ld a, $A5
    call Send
    ld a, l
    call Send
    ld a, h
    call Send
    ld a, l
    xor h
    xor $5A
    call Send
    ret

Send:
    ldh [rSB], a
    ld a, $81
    ldh [rSC], a
.wait:
    ldh a, [rSC]
    bit 7, a
    jr nz, .wait
    ret

; ---------------- selection frame: 14 sprites, a 2 px white edge inside the card ----------
UpdateSprites:
    ld hl, wOAM
    ld a, [wOnPage]
    or a
    jr z, .hide
    ld a, [wSel]
    add a
    ld e, a
    ld d, 0
    push hl
    ld hl, CardPos
    add hl, de
    ld a, [hl+]
    ld [wFx], a
    ld a, [hl]
    ld [wFy], a
    pop hl
    ld a, [wFy]                 ; top two lines
    add 16
    ld d, a
    call HEdge
    ld a, [wFy]                 ; bottom two lines (38-39)
    add 16 + 38
    ld d, a
    call HEdge
    ld a, [wFx]                 ; left two columns
    add 8
    ld e, a
    call VEdge
    ld a, [wFx]                 ; right two columns (30-31)
    add 8 + 30
    ld e, a
    jr VEdge
.hide:
    ld b, 14 * 4
    xor a
.z:
    ld [hl+], a
    dec b
    jr nz, .z
    ret

; d = OAM y: four sprites across the card's 32 columns
HEdge:
    ld a, [wFx]
    add 8
    ld e, a
    ld b, 4
.l:
    ld a, FRAME_TILE
    call Put
    ld a, e
    add 8
    ld e, a
    dec b
    jr nz, .l
    ret

; e = OAM x: three 8x16 sprites down the card's 40 lines (the last overlaps)
VEdge:
    ld a, [wFy]
    add 16
    ld d, a
    ld a, FRAME_TILE + 2
    call Put
    ld a, [wFy]
    add 32
    ld d, a
    ld a, FRAME_TILE + 2
    call Put
    ld a, [wFy]
    add 40
    ld d, a
    ld a, FRAME_TILE + 2
    jr Put

; OAM entry at hl: y = d, x = e, tile = a, attributes 0
Put:
    ld [hl], d
    inc hl
    ld [hl], e
    inc hl
    ld [hl+], a
    ld [hl], 0
    inc hl
    ret

; card positions (screen pixels, top-left), shared with menu.py's CARDS
CardPos:
    db 48, 16, 80, 24, 112, 16
    db 16, 80, 48, 72, 80, 80, 112, 72
; up from bottom card 3-6, down from top card 0-2 (nearest column)
UpTab:
    db 0, 0, 1, 2
DownTab:
    db 4, 5, 6
