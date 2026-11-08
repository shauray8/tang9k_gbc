; Tang arcade: the FPGA's game launcher, itself a small GBC game.
; Walk Mario-style along a hall of arcade cabinets, three per room. Each cabinet
; shows a game's cover. Stand in front of one and press A (or Start) to insert a coin.
; host/arcade/build.py fills in graphics, palettes and the game records; this file is
; only the engine. Rebuild engine.bin with `make arcade` after editing.

DEF rP1    EQU $FF00
DEF rSB    EQU $FF01
DEF rSC    EQU $FF02
DEF rIF    EQU $FF0F
DEF rLCDC  EQU $FF40
DEF rLY    EQU $FF44
DEF rWY    EQU $FF4A
DEF rWX    EQU $FF4B
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

; ---- fixed layout shared with build.py ----
DEF FONT_TILES   EQU $2000   ; 96 font tiles + 64 world tiles (160 tiles)
DEF SPRITE_TILES EQU $2A00   ; 24 sprite tiles -> tile 232
DEF BG_MAP       EQU $2C00   ; 32x14 tile map
DEF BG_ATTR      EQU $2E00   ; 32x14 attributes
DEF WIN_MAP      EQU $3000   ; 32x4 window map
DEF WIN_ATTR     EQU $3080
DEF BG_PALS      EQU $3100   ; 8 palettes x 8 bytes
DEF OBJ_PALS     EQU $3140
DEF MARQUEE_PALS EQU $3180   ; dim, bright (8 bytes each)
DEF IDLE_TEXT    EQU $31A0   ; 4 x 20 banner rows when nothing is selected
DEF LOAD_TEXT    EQU $3200   ; 4 x 20 banner rows while loading
DEF BLANK_RECORD EQU $3400   ; record shown for empty cabinet slots
DEF GAME_COUNT   EQU $3FF0   ; 16-bit
DEF LAST_ROOM    EQU $3FF2   ; 16-bit index of the last room's first game

; record layout (512 bytes, banks 1+, 32 per bank)
DEF R_PAL     EQU 384
DEF R_TITLE   EQU 392        ; 2 x 20
DEF R_INFO    EQU 432
DEF R_HINT    EQU 452
DEF R_PLAY    EQU 472
DEF R_MARQUEE EQU 473        ; 4 characters

DEF COVER_TILE EQU 160       ; covers at tiles 160..231
DEF PLAYER_TILE EQU 232
DEF COIN_TILE EQU 248
DEF FLOOR_Y   EQU 80         ; player top, screen pixels
DEF RIGHT_EDGE EQU 152

; ---- WRAM ----
SECTION "shadow oam", WRAM0[$C000]
wOAM: ds 160
SECTION "state", WRAM0[$C100]
wBase:    ds 2     ; index of this room's first game
wX:       ds 1     ; player left x, screen pixels
wFace:    ds 1     ; 0 right, $20 left (OAM x-flip)
wAnim:    ds 1
wJump:    ds 1     ; jump table position, 0 = on the ground
wSel:     ds 1     ; selected slot 0-2, $FF none
wPrevSel: ds 1
wRoomDirty: ds 1
wBannerDirty: ds 1
wFrame:   ds 1
wPad:     ds 1
wPressed: ds 1
wLaunch:  ds 1     ; 0 idle, >0 coin animation countdown, $FF sent
wCoinY:   ds 1

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
    ; double speed: twice the VBlank budget for room and banner redraws
    ld a, $30
    ldh [rP1], a
    ld a, 1
    ldh [$FF4D], a
    stop

    ; tiles: font + world (2560 bytes), then sprites
    ld hl, FONT_TILES
    ld de, $8000
    ld c, 128
    call Gdma
    ld hl, FONT_TILES + 2048
    ld de, $8800
    ld c, 32
    call Gdma
    ld hl, SPRITE_TILES
    ld de, $8000 + PLAYER_TILE * 16
    ld c, 24
    call Gdma
    ; maps and attributes
    ld hl, BG_MAP
    ld de, $9800
    ld c, 28
    call Gdma
    ld hl, WIN_MAP
    ld de, $9C00
    ld c, 8
    call Gdma
    ld a, 1
    ldh [rVBK], a
    ld hl, BG_ATTR
    ld de, $9800
    ld c, 28
    call Gdma
    ld hl, WIN_ATTR
    ld de, $9C00
    ld c, 8
    call Gdma
    xor a
    ldh [rVBK], a
    ; palettes
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
    ld b, 64
.obp:
    ld a, [hl+]
    ldh [rOCPD], a
    dec b
    jr nz, .obp

    ; OAM DMA routine into HRAM
    ld hl, DmaRoutine
    ld de, $FF80
    ld b, DmaRoutineEnd - DmaRoutine
.copydma:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .copydma

    ; state
    ld hl, wOAM
    ld b, 160
    xor a
.clroam:
    ld [hl+], a
    dec b
    jr nz, .clroam
    ld hl, wBase
    ld b, wCoinY - wBase + 1
.clrstate:
    ld [hl+], a
    dec b
    jr nz, .clrstate
    ld a, 64
    ld [wX], a
    ld a, $FF
    ld [wSel], a
    ld a, $FE
    ld [wPrevSel], a
    call DrawRoom
    call DrawBanner
    ld a, 112
    ldh [rWY], a
    ld a, 7
    ldh [rWX], a
    ld a, %11110111      ; LCD, window 9C00 on, tiles 8000, BG 9800, OBJ 8x16 on, BG on
    ldh [rLCDC], a

MainLoop:
    call WaitVBlank
    call $FF80                 ; OAM DMA from wOAM
    call AnimateMarquees       ; palettes are not writable in mode 3
    ld a, [wRoomDirty]
    or a
    jr z, .noroom
    xor a
    ld [wRoomDirty], a
    call DrawRoom
    jr .drawn                  ; banner on the next frame: one VBlank each
.noroom:
    ld a, [wBannerDirty]
    or a
    jr z, .drawn
    xor a
    ld [wBannerDirty], a
    call DrawBanner
.drawn:
    ld hl, wFrame
    inc [hl]
    call ReadPad
    call UpdatePlayer
    call UpdateSelection
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

; hl = slot 0-2 -> hl = game index (wBase + slot)
SlotIndex:
    ld a, [wBase]
    add l
    ld l, a
    ld a, [wBase + 1]
    adc 0
    ld h, a
    ret

; ---------------- room drawing (one VBlank) ----------------
DrawRoom:
    ld c, 0                     ; slot
.slot:
    push bc
    ld h, 0
    ld l, c
    call SlotIndex
    call Record
    pop bc
    push bc
    push hl
    ; cover tiles -> $8000 + (160 + 24 * slot) * 16 = $8A00 + $180 * slot
    ld a, c
    ld de, $8A00
    or a
    jr z, .dest
.adddest:
    push af
    ld a, e
    add $80
    ld e, a
    ld a, d
    adc $01
    ld d, a
    pop af
    dec a
    jr nz, .adddest
.dest:
    ld c, 24
    call Gdma
    pop hl
    pop bc
    push bc
    push hl
    ; cover palette -> BG palette 1 + slot
    ld de, R_PAL
    add hl, de
    ld a, c
    inc a
    add a
    add a
    add a
    or $80
    ldh [rBCPS], a
    ld b, 8
.pal:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .pal
    pop hl
    pop bc
    push bc
    ; marquee text -> map row 2, columns 7*slot + 1 .. +4
    ld de, R_MARQUEE
    add hl, de
    ld a, c
    add a
    add a
    add a
    sub c                       ; 7 * slot
    add $41                     ; $9800 + 2 * 32 + 1
    ld e, a
    ld d, $98
    ld b, 4
.mq:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .mq
    pop bc
    inc c
    ld a, c
    cp 3
    jr nz, .slot
    ld a, 1
    ld [wBannerDirty], a
    ld a, $FE
    ld [wPrevSel], a            ; force marquee palette refresh
    ret

; ---------------- banner (window rows 0-3) ----------------
DrawBanner:
    ld a, [wLaunch]
    or a
    jr z, .notloading
    ld hl, LOAD_TEXT
    jr .copy
.notloading:
    ld a, [wSel]
    cp $FF
    jr nz, .game
    ld hl, IDLE_TEXT
    jr .copy
.game:
    ld h, 0
    ld l, a
    call SlotIndex
    call Record
    ld de, R_TITLE
    add hl, de
.copy:
    ld de, $9C00
    ld c, 4
.row:
    ld b, 20
.ch:
    ld a, [hl+]
    ld [de], a
    inc de
    dec b
    jr nz, .ch
    ld a, e
    add 12
    ld e, a
    dec c
    jr nz, .row
    ret

; ---------------- marquee lights: palettes 5-7, selected one blinks ----------------
AnimateMarquees:
    ld a, [wFrame]
    and 15
    jr z, .update
    ld a, [wSel]
    ld b, a
    ld a, [wPrevSel]
    cp b
    ret z
.update:
    ld a, [wSel]
    ld [wPrevSel], a
    ld c, 0
.pal:
    ld a, c
    add 5
    add a
    add a
    add a
    or $80
    ldh [rBCPS], a
    ld hl, MARQUEE_PALS
    ld a, [wSel]
    cp c
    jr nz, .dim
    ld a, [wFrame]
    bit 4, a
    jr nz, .dim
    ld hl, MARQUEE_PALS + 8
.dim:
    ld b, 8
.w:
    ld a, [hl+]
    ldh [rBCPD], a
    dec b
    jr nz, .w
    inc c
    ld a, c
    cp 3
    jr nz, .pal
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
DEF PAD_B     EQU 1
DEF PAD_START EQU 3
DEF PAD_RIGHT EQU 4
DEF PAD_LEFT  EQU 5
DEF PAD_UP    EQU 6

; ---------------- player ----------------
UpdatePlayer:
    ld a, [wLaunch]
    or a
    ret nz
    ld a, [wPad]
    ld c, 1
    bit PAD_B, a
    jr z, .speed
    ld c, 2                     ; hold B to run
.speed:
    ld b, 0                     ; moved?
    bit PAD_RIGHT, a
    jr z, .notright
    ld a, [wX]
    add c
    ld [wX], a
    xor a
    ld [wFace], a
    inc b
    jr .moved
.notright:
    ld a, [wPad]
    bit PAD_LEFT, a
    jr z, .moved
    ld a, [wX]
    sub c
    ld [wX], a
    ld a, $20
    ld [wFace], a
    inc b
.moved:
    ld a, b
    or a
    jr z, .still
    ld hl, wAnim
    inc [hl]
    jr .edges
.still:
    xor a
    ld [wAnim], a
.edges:
    ; walking off either side changes room
    ld a, [wX]
    cp RIGHT_EDGE + 3
    jr c, .noright
    cp $F0
    jr nc, .left                ; wrapped below 0
    ld a, 4
    ld [wX], a
    call NextRoom
    jr .jump
.noright:
    jr .jump
.left:
    ld a, 128                   ; arrive in front of the room's last cabinet
    ld [wX], a
    call PrevRoom
.jump:
    ld a, [wJump]
    or a
    jr nz, .air
    ld a, [wPressed]
    bit PAD_UP, a
    ret z
    ld a, 1
    ld [wJump], a
    ret
.air:
    inc a
    cp JumpTableEnd - JumpTable
    jr c, .store
    xor a
.store:
    ld [wJump], a
    ret

NextRoom:
    ld a, [wBase]
    add 3
    ld l, a
    ld a, [wBase + 1]
    adc 0
    ld h, a
    ; past the last room -> back to the first
    ld a, [LAST_ROOM + 1]
    cp h
    jr c, .wrap
    jr nz, .set
    ld a, [LAST_ROOM]
    cp l
    jr nc, .set
.wrap:
    ld hl, 0
.set:
    ld a, l
    ld [wBase], a
    ld a, h
    ld [wBase + 1], a
    ld a, 1
    ld [wRoomDirty], a
    ret

PrevRoom:
    ld a, [wBase]
    ld l, a
    ld a, [wBase + 1]
    ld h, a
    or l
    jr nz, .back
    ld a, [LAST_ROOM]
    ld l, a
    ld a, [LAST_ROOM + 1]
    ld h, a
    jr NextRoom.set
.back:
    ld a, l
    sub 3
    ld l, a
    ld a, h
    sbc 0
    ld h, a
    jr NextRoom.set

; slot whose cabinet the player stands in front of (centre 24 + 56 * slot)
UpdateSelection:
    ld a, [wLaunch]
    or a
    ret nz
    ld a, [wX]
    add 8                       ; player centre
    ld e, a
    ld c, $FF
    ld b, 0
    ld d, 24
.try:
    ld a, e
    sub d
    jr nc, .pos
    cpl
    inc a
.pos:
    cp 18
    jr nc, .next
    ld c, b
.next:
    ld a, d
    add 56
    ld d, a
    inc b
    ld a, b
    cp 3
    jr nz, .try
    ld a, [wSel]
    cp c
    ret z
    ld a, c
    ld [wSel], a
    ld a, 1
    ld [wBannerDirty], a
    ret

; ---------------- launching ----------------
UpdateLaunch:
    ld a, [wLaunch]
    cp $FF
    ret z
    or a
    jr nz, .animating
    ld a, [wPressed]
    and (1 << PAD_A) | (1 << PAD_START)
    ret z
    ld a, [wSel]
    cp $FF
    ret z
    ld h, 0
    ld l, a
    call SlotIndex
    call Record
    ld de, R_PLAY
    add hl, de
    ld a, [hl]
    or a
    ret z                       ; out of order
    ld a, 40
    ld [wLaunch], a
    ld a, 8
    ld [wCoinY], a
    ld a, 1
    ld [wBannerDirty], a
    ret
.animating:
    ld hl, wCoinY
    inc [hl]
    inc [hl]
    ld hl, wLaunch
    dec [hl]
    ret nz
    ld [hl], $FF
    ; A5, index low, index high, low ^ high ^ 5A
    ld a, [wSel]
    ld h, 0
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

; ---------------- sprites ----------------
UpdateSprites:
    ; player frame: 0 stand, 1/2 walk, 3 jump
    ld a, [wJump]
    or a
    ld b, 3
    jr nz, .frame
    ld a, [wAnim]
    or a
    ld b, 0
    jr z, .frame
    and 8
    ld b, 1
    jr z, .frame
    ld b, 2
.frame:
    ld a, b
    add a
    add a
    add PLAYER_TILE
    ld c, a                     ; left half tile
    ; y = FLOOR_Y + 16 - jump height
    ld a, [wJump]
    ld e, a
    ld d, 0
    ld hl, JumpTable
    add hl, de
    ld a, FLOOR_Y + 16
    sub [hl]
    ld d, a
    ld hl, wOAM
    ld a, [wFace]
    or a
    jr nz, .flipped
    ld [hl], d                  ; left half
    inc hl
    ld a, [wX]
    add 8
    ld [hl+], a
    ld a, c
    ld [hl+], a
    xor a
    ld [hl+], a
    ld [hl], d                  ; right half
    inc hl
    ld a, [wX]
    add 16
    ld [hl+], a
    ld a, c
    add 2
    ld [hl+], a
    xor a
    ld [hl+], a
    jr .coin
.flipped:
    ld [hl], d
    inc hl
    ld a, [wX]
    add 16
    ld [hl+], a
    ld a, c
    ld [hl+], a
    ld a, $20
    ld [hl+], a
    ld [hl], d
    inc hl
    ld a, [wX]
    add 8
    ld [hl+], a
    ld a, c
    add 2
    ld [hl+], a
    ld a, $20
    ld [hl+], a
.coin:
    ; spinning coin above the selected cabinet (falls into it while launching)
    ld a, [wSel]
    cp $FF
    jr z, .nocoin
    ld b, a
    add a
    add a
    add a
    sub b                       ; 7 * slot
    add a
    add a
    add a                       ; 56 * slot
    add 24 + 8 - 4
    ld e, a                     ; OAM x
    ld a, [wLaunch]
    or a
    jr z, .bob
    cp $FF
    jr z, .nocoin
    ld a, [wCoinY]
    cp 64                       ; reached the coin slot
    jr nc, .nocoin
    add 16
    jr .coiny
.bob:
    ld a, [wFrame]
    rrca
    rrca
    rrca
    and 3
    add 16 + 6
.coiny:
    ld [hl+], a
    ld a, e
    ld [hl+], a
    ld a, [wFrame]
    and 8
    rrca
    rrca                        ; 0 or 2
    add COIN_TILE
    ld [hl+], a
    ld a, 1                     ; OBJ palette 1
    ld [hl+], a
    ret
.nocoin:
    xor a
    ld [hl], a
    ret

; jump heights (pixels above the floor), index 0 = standing
JumpTable:
    db 0, 3, 6, 9, 11, 13, 15, 16, 17, 18, 18, 18, 17, 16, 15, 13, 11, 9, 6, 3
JumpTableEnd:
