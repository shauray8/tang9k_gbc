; Hardware memory stress test (build with sim/hwstress/build.sh, run with run.py).
; Double speed, LCD off. Forever: for every 2 KiB chunk of ROM banks 1-63 (random data),
; GDMA it into VRAM, then have the CPU compare VRAM with the ROM byte by byte. That is the
; game access pattern that crashed Zelda: back-to-back external reads by the DMA engine
; and by the CPU, plus every opcode fetch. Results live in cartridge RAM (battery area):
;   A000 passes (32-bit LE)   A004 mismatching bytes (32-bit LE)
;   A008 last mismatch: bank, address low, address high, ROM byte, VRAM byte
;   A00D "OK" once started

SECTION "header", ROM0[$100]
    nop
    jp Start
    ds $150 - @, 0

SECTION "main", ROM0[$150]
Start:
    di
    ld sp, $DFFF
.vblank:
    ldh a, [$FF44]
    cp 144
    jr nz, .vblank
    xor a
    ldh [$FF40], a              ; LCD off: VRAM always accessible
    ld a, $30
    ldh [$FF00], a
    ld a, 1
    ldh [$FF4D], a
    stop                        ; double speed
    nop
    ld a, $0A
    ld [$0000], a               ; cartridge RAM on
    xor a
    ld [$4000], a               ; RAM bank 0
    ld hl, $A000
    ld b, 16
.clear:
    ld [hl+], a
    dec b
    jr nz, .clear
    ld a, 'O'
    ld [$A00D], a
    ld a, 'K'
    ld [$A00E], a

Pass:
    ld b, 1                     ; ROM bank
.bank:
    ld a, b
    ld [$C000], a               ; current bank, for Mismatch
    ld [$2000], a
    xor a
    ld [$3000], a
    ld c, 0                     ; 2 KiB chunk 0-7
.chunk:
    ld a, c
    add a
    add a
    add a
    add $40
    ld d, a                     ; de = chunk start in the bank window
    ldh [$FF51], a
    xor a
    ld e, a
    ldh [$FF52], a
    ldh [$FF53], a
    ldh [$FF54], a              ; to VRAM $8000
    ld a, $7F
    ldh [$FF55], a              ; GDMA 128 x 16 bytes
    ld hl, $8000
    push bc
    ld bc, $0800
.compare:
    ld a, [de]
    cp [hl]
    call nz, Mismatch
    inc de
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .compare
    pop bc
    inc c
    ld a, c
    cp 8
    jr nz, .chunk
    inc b
    ld a, b
    cp 64
    jr nz, .bank
    ld hl, $A000
    call Inc32
    jr Pass

; count a mismatch and record where (keeps bc, de, hl)
Mismatch:
    push hl
    push de
    push bc
    ld b, [hl]                  ; VRAM byte
    ld a, [de]
    ld c, a                     ; ROM byte
    ld hl, $A004
    call Inc32
    ld hl, $A008
    ld a, [$C000]
    ld [hl+], a
    ld a, e
    ld [hl+], a
    ld a, d
    ld [hl+], a
    ld a, c
    ld [hl+], a
    ld [hl], b
    pop bc
    pop de
    pop hl
    ret

; hl -> 32-bit little-endian counter, +1
Inc32:
    inc [hl]
    ret nz
    inc hl
    inc [hl]
    ret nz
    inc hl
    inc [hl]
    ret nz
    inc hl
    inc [hl]
    ret
