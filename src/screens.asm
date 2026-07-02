; ---------------------------------------------------------------
; Test screens: kernels, per-screen logic, display lists, strings
; ---------------------------------------------------------------

; ---------------------------------------------------------------
; Helper: copy the 6-byte string at strPtr into bufA+offset.
; X = offset of the LAST byte (5, 11, 17, ...)
; ---------------------------------------------------------------
CopyStr SUBROUTINE
        ldy #5
.c      lda (strPtr),y
        sta bufA,x
        dex
        dey
        bpl .c
        rts

; ---------------------------------------------------------------
; Screen 1 - CORES: labeled color bars (single-height text) plus
; the color bar generator grid with the full NTSC palette:
; 16 hue rows x 8 luminance columns (all 128 colors).
; COLUBK is rewritten mid-scanline: X starts at the row hue and
; two INX per column step the luminance while STX hits COLUBK
; every 7 cycles (one column every ~21 color clocks).
; The gray scale lives in the palette's first row, so the named
; bars only carry the primary hues and white.
; ---------------------------------------------------------------
KCores SUBROUTINE
        lda #<dlCores
        sta dlPtr
        lda #>dlCores
        sta dlPtr+1
        jsr DrawDisplayList
        lda #0
        sta temp            ; current hue ($00,$10,...,$F0)
.row    ldy #4              ; scanlines per hue row (+1 spill line on
                            ; the hue-advance path = 5 per row)
.line   sta WSYNC
        ldx temp
        stx COLUBK          ; column 0 (luma 0) still in hblank
        SLEEP 12            ; align column 1 near pixel 10
        REPEAT 7
        inx
        inx
        stx COLUBK          ; next column, +2 luminance
        REPEND
        dey
        bne .line
        lda temp
        clc
        adc #$10
        sta temp
        bne .row            ; wraps to 0 after hue $F0
        sta COLUBK          ; back to black (A = 0), still in the
        rts                 ; hblank of the hue-advance spill line

dlCores
        .byte $80,$0E,22,<sTitulo,>sTitulo      ; navy title bar
        .byte $84,$0F,15,<sAzul,>sAzul          ; bit 0: single height
        .byte $42,$0F,15,<sVermel,>sVermel
        .byte $C6,$0F,15,<sVerde,>sVerde
        .byte $2C,$0F,15,<sLaranj,>sLaranj
        .byte $1C,$01,15,<sAmarel,>sAmarel      ; black text on yellow
        .byte $0E,$01,15,<sBranco,>sBranco      ; black text on white
        .byte $00,$00,0,$00,$FF                 ; hand over to the grid

; ---------------------------------------------------------------
; Screen 2 - CALIBR: color trimpot calibration.
; Hues 1 and 15 sit at the two ends of the TIA color delay line,
; so they only match when the internal trimpot is set correctly
; (Atari field service procedure). Adjust the trimpot until the
; two bands look identical. NTSC consoles only.
; ---------------------------------------------------------------
KCal SUBROUTINE
        lda #<dlCal
        sta dlPtr
        lda #>dlCal
        sta dlPtr+1
        jmp DrawDisplayList

dlCal
        .byte $80,$0E,22,<sCalTit,>sCalTit
        .byte $16,$00,80,$00,$FF                ; hue 1, luma 6
        .byte $F6,$00,80,$00,$FF                ; hue 15, luma 6
        .byte $00,$00,0,$00,$FF

; ---------------------------------------------------------------
; Screen 3 - CONTROLE: joysticks, keypads and console switches
; ---------------------------------------------------------------
KCtrl SUBROUTINE
        lda #<dlCtrl
        sta dlPtr
        lda #>dlCtrl
        sta dlPtr+1
        jmp DrawDisplayList

dlCtrl
        .byte $80,$0E,22,<sCtrl,>sCtrl
        .byte $84,$0E,22,<bufA,>bufA            ; left stick
        .byte $84,$0E,22,<bufB,>bufB            ; right stick
        .byte $C6,$0E,22,<bufC,>bufC            ; keypads
        .byte $42,$0E,22,<bufD,>bufD            ; difficulty switches
        .byte $42,$0E,22,<bufE,>bufE            ; select/reset
        .byte $42,$0E,22,<bufF,>bufF            ; tv type
        .byte $0E,$00,10,$00,$FF
        .byte $00,$00,0,$00,$FF

; builds the live strings during vertical blank
VCtrl SUBROUTINE
        ; ---- bufA/bufB: sticks as "L <arrows> F" ----
        lda #_L
        sta bufA
        lda #_R
        sta bufB
        ; left stick: up $10 down $20 left $40 right $80 (0 = pressed)
        ldx #_UP
        lda joyNow
        and #$10
        jsr PickArrow
        sta bufA+1
        ldx #_DN
        lda joyNow
        and #$20
        jsr PickArrow
        sta bufA+2
        ldx #_LT
        lda joyNow
        and #$40
        jsr PickArrow
        sta bufA+3
        ldx #_RT
        lda joyNow
        and #$80
        jsr PickArrow
        sta bufA+4
        ; right stick: up $01 down $02 left $04 right $08
        ldx #_UP
        lda joyNow
        and #$01
        jsr PickArrow
        sta bufB+1
        ldx #_DN
        lda joyNow
        and #$02
        jsr PickArrow
        sta bufB+2
        ldx #_LT
        lda joyNow
        and #$04
        jsr PickArrow
        sta bufB+3
        ldx #_RT
        lda joyNow
        and #$08
        jsr PickArrow
        sta bufB+4
        ; fire buttons: only meaningful while SWACNT is in input mode
        lda frameCnt
        and #$0F
        cmp #5
        bcc .fireSkip
        ldx #_F
        lda INPT4
        and #$80
        jsr PickArrow
        sta bufA+5
        ldx #_F
        lda INPT5
        and #$80
        jsr PickArrow
        sta bufB+5
.fireSkip
        ; ---- bufC: keypads "TEC" + last key left/right ----
        lda #_T
        sta bufC
        lda #_E
        sta bufC+1
        lda #_C
        sta bufC+2
        lda #_SP
        sta bufC+3
        lda kpKeyL
        sta bufC+4
        lda kpKeyR
        sta bufC+5
        ; ---- bufD: difficulty "DF A B" (1 = A, 0 = B) ----
        lda #_D
        sta bufD
        lda #_F
        sta bufD+1
        lda #_SP
        sta bufD+2
        sta bufD+4
        ldx #_B
        lda swchbNow
        and #$40
        beq .dfl
        ldx #_A
.dfl    stx bufD+3
        ldx #_B
        lda swchbNow
        and #$80
        beq .dfr
        ldx #_A
.dfr    stx bufD+5
        ; ---- bufE: "S1 R1 " raw select/reset bits (0 = pressed) ----
        lda #_S
        sta bufE
        lda #_R
        sta bufE+3
        lda #_SP
        sta bufE+2
        sta bufE+5
        ldx #_0
        lda swchbNow
        and #$02
        beq .sel
        ldx #_1
.sel    stx bufE+1
        ldx #_0
        lda swchbNow
        and #$01
        beq .res
        ldx #_1
.res    stx bufE+4
        ; ---- bufF: tv type ----
        lda swchbNow
        and #$08            ; bit3: 1 = color
        bne .cor
        lda #<sTvPb
        sta strPtr
        lda #>sTvPb
        sta strPtr+1
        jmp .cp
.cor    lda #<sTvCor
        sta strPtr
        lda #>sTvCor
        sta strPtr+1
.cp     ldx #35             ; bufF = bufA+30, last byte offset 35
        jmp CopyStr

; A = masked input bit (0 = active), X = glyph when active.
; Returns the glyph in A, or '-' when inactive.
PickArrow SUBROUTINE
        beq .on
        lda #_DASH
        rts
.on     txa
        rts

; keypad row driving happens during overscan (CTRL screen only);
; the fire buttons beep on their own audio channel (left = 0,
; right = 1), testing input and sound together
OCtrl SUBROUTINE
        lda frameCnt
        and #$0F
        cmp #4
        bcc .drive
        bne .beep
        lda #$00            ; phase 4: release the port to input mode
        sta SWACNT
        beq .silence        ; always (A = 0)
.beep   ; phases 5-15: INPT4/5 read the fire buttons again
        lda #4              ; pure tone
        sta AUDC0
        sta AUDC1
        lda #10
        sta AUDF0
        lda #20             ; lower pitch on the right channel
        sta AUDF1
        ldx #0
        lda INPT4
        bmi .lVol
        ldx #12
.lVol   stx AUDV0
        ldx #0
        lda INPT5
        bmi .rVol
        ldx #12
.rVol   stx AUDV1
        rts
.drive  tax                 ; phase 0-3 = row to drive low
        lda #$FF
        sta SWACNT
        lda RowMask,x
        sta SWCHA
.silence
        lda #0              ; INPT4/5 belong to the keypad scan now
        sta AUDV0
        sta AUDV1
        rts

RowMask ; row k: clear bit 4+k (left port) and bit k (right port)
        .byte %11101110,%11011101,%10111011,%01110111

; ---------------------------------------------------------------
; Screen 4 - RAM: power-up test, continuous test, ROM checksum
; ---------------------------------------------------------------
KRam SUBROUTINE
        lda #<dlRam
        sta dlPtr
        lda #>dlRam
        sta dlPtr+1
        jmp DrawDisplayList

dlRam
        .byte $80,$0E,22,<sRamTit,>sRamTit
        .byte $84,$0E,22,<bufA,>bufA            ; power-up result
        .byte $C6,$0E,22,<bufB,>bufB            ; continuous result
        .byte $42,$0E,22,<bufC,>bufC            ; rom checksum
        .byte $0E,$00,10,$00,$FF
        .byte $00,$00,0,$00,$FF

VRam SUBROUTINE
        ; ---- continuous non-destructive test, 16 bytes per frame ----
        ; Y holds the original value while the byte is under test, so
        ; every live variable (including the stack) survives.
        ldx ramPtr
        bmi .go             ; boot clear leaves ramPtr at 0, which
        ldx #$80            ; would sweep the TIA registers at
.go     lda #16             ; $00-$7F: clamp to the real RAM range
        sta temp
.t      ldy $00,x
        lda #$55
        sta $00,x
        cmp $00,x
        bne .bad
        lda #$AA
        sta $00,x
        cmp $00,x
        bne .bad
        sty $00,x
        jmp .next
.bad    sty $00,x
        inc ramErr
.next   inx
        bne .cont
        ldx #$80            ; wrap $FF -> $80
.cont   dec temp
        bne .t
        stx ramPtr
        cpx #$80            ; completed a full pass?
        bne .strings
        lda ramErr
        sta ramLive
        lda #0
        sta ramErr
.strings
        ; ---- bufA: power-up result ----
        lda #<sRamOk
        sta strPtr
        lda #>sRamOk
        sta strPtr+1
        lda ramBoot
        beq .bootOk
        lda #<sRamEr
        sta strPtr
        lda #>sRamEr
        sta strPtr+1
.bootOk ldx #5
        jsr CopyStr
        ; ---- bufB: continuous result ----
        lda #<sMemOk
        sta strPtr
        lda #>sMemOk
        sta strPtr+1
        lda ramLive
        beq .liveOk
        lda #<sMemEr
        sta strPtr
        lda #>sMemEr
        sta strPtr+1
.liveOk ldx #11
        jsr CopyStr
        ; ---- bufC: "S hhhh" rom checksum ----
        lda #_S
        sta bufC
        lda #_SP
        sta bufC+1
        lda romSumHi
        lsr
        lsr
        lsr
        lsr
        sta bufC+2
        lda romSumHi
        and #$0F
        sta bufC+3
        lda romSumLo
        lsr
        lsr
        lsr
        lsr
        sta bufC+4
        lda romSumLo
        and #$0F
        sta bufC+5
        rts

; ---------------------------------------------------------------
; Screen 5 - SOM: tone/frequency sweep on both channels
; ---------------------------------------------------------------
KSom SUBROUTINE
        lda #<dlSom
        sta dlPtr
        lda #>dlSom
        sta dlPtr+1
        jmp DrawDisplayList

dlSom
        .byte $80,$0E,22,<sSomTit,>sSomTit
        .byte $84,$0E,22,<bufA,>bufA            ; channel
        .byte $C6,$0E,22,<bufB,>bufB            ; tone (AUDC)
        .byte $42,$0E,22,<bufC,>bufC            ; frequency (AUDF)
        .byte $0E,$00,10,$00,$FF
        .byte $00,$00,0,$00,$FF

VSom SUBROUTINE
        lda #_C
        sta bufA
        lda #_A
        sta bufA+1
        lda #_N
        sta bufA+2
        lda #_SP
        sta bufA+3
        sta bufA+5
        lda sndCh
        sta bufA+4          ; 0/1 map straight to digit codes
        lda #_T
        sta bufB
        lda #_O
        sta bufB+1
        lda #_M
        sta bufB+2
        lda #_SP
        sta bufB+3
        sta bufB+5
        lda sndTone
        sta bufB+4          ; 0-15 map straight to hex codes
        lda #_F
        sta bufC
        lda #_R
        sta bufC+1
        lda #_Q
        sta bufC+2
        lda #_SP
        sta bufC+3
        lda sndFreq
        lsr
        lsr
        lsr
        lsr
        sta bufC+4
        lda sndFreq
        and #$0F
        sta bufC+5
        rts

OSom SUBROUTINE
        lda frameCnt
        and #7
        bne .apply
        inc sndFreq
        lda sndFreq
        cmp #32
        bcc .apply
        lda #0
        sta sndFreq
        inc sndTone
        lda sndCh           ; swap channels on every tone change so
        eor #1              ; both are heard within seconds
        sta sndCh
        lda sndTone
        cmp #16
        bcc .apply
        lda #0
        sta sndTone
.apply  lda sndCh
        bne .ch1
        lda sndTone
        sta AUDC0
        lda sndFreq
        sta AUDF0
        lda #10
        sta AUDV0
        lda #0
        sta AUDV1
        rts
.ch1    lda sndTone
        sta AUDC1
        lda sndFreq
        sta AUDF1
        lda #10
        sta AUDV1
        lda #0
        sta AUDV0
        rts

; ---------------------------------------------------------------
; Screen 6 - TIA: players, missiles, ball and playfield in motion
; ---------------------------------------------------------------
KTia SUBROUTINE
        lda #<dlTia
        sta dlPtr
        lda #>dlTia
        sta dlPtr+1
        jsr DrawDisplayList
        ; reconfigure the players as moving objects
        lda #0
        sta VDELP0
        sta VDELP1
        lda #$20            ; one copy, 4-clock missiles
        sta NUSIZ0
        sta NUSIZ1
        lda #$20            ; 4-clock ball
        sta CTRLPF
        lda #$46            ; P0/M0 red
        sta COLUP0
        lda #$C8            ; P1/M1 green
        sta COLUP1
        lda #$9C            ; BL/PF blue-cyan
        sta COLUPF
        ldx #4              ; position the five objects (15 lines)
.pos    lda obX,x
        jsr PosObject
        dex
        bpl .pos
        lda #%11000011
        sta GRP0
        lda #%00111100
        sta GRP1
        lda #2
        sta ENAM0
        sta ENAM1
        sta ENABL
        lda #%00011000      ; playfield stripes behind the objects
        sta PF1
        ldy #110            ; object band
.reg    sta WSYNC
        dey
        bne .reg
        lda #0              ; everything off again
        sta ENAM0
        sta ENAM1
        sta ENABL
        sta GRP0
        sta GRP1
        sta GRP0
        sta PF1
        rts

dlTia
        .byte $80,$0E,22,<sTiaTit,>sTiaTit
        .byte $00,$0E,0,$00,$FF                 ; black band for objects

OTia SUBROUTINE
        lda #0
        sta AUDV0
        sta AUDV1
        ldx #4
.m      lda obX,x
        clc
        adc obDir,x
        sta obX,x
        cmp #150
        bcs .rev
        cmp #6
        bcs .next
.rev    sec                 ; bounce: reverse the speed
        lda #0
        sbc obDir,x
        sta obDir,x
        clc
        adc obX,x
        sta obX,x           ; step back inside the field
.next   dex
        bpl .m
        rts

; ---------------------------------------------------------------
; Screen 7 - PADDLE: analog reads of INPT0-3
; The pots are grounded during blanking (VBLANK bit 7, set by the
; frame loop) and released at the top of the visible frame; the
; kernel then counts scanlines until each pot charges up.
; ---------------------------------------------------------------
KPad SUBROUTINE
        lda #<dlPadT
        sta dlPtr
        lda #>dlPadT
        sta dlPtr+1
        jsr DrawDisplayList
        lda #0              ; reset the counters for this frame
        sta pd0
        sta pd1
        sta pd2
        sta pd3
        sta WSYNC
        sta VBLANK          ; release the pot dump: charging starts now
        ldy #64             ; counting region: 64 scanlines
.cnt    sta WSYNC
        lda INPT0           ; unrolled: the loop version would not
        bmi .s0             ; fit in one scanline
        inc pd0
.s0     lda INPT1
        bmi .s1
        inc pd1
.s1     lda INPT2
        bmi .s2
        inc pd2
.s2     lda INPT3
        bmi .s3
        inc pd3
.s3     dey
        bne .cnt
        lda #<dlPadV
        sta dlPtr
        lda #>dlPadV
        sta dlPtr+1
        jmp DrawDisplayList

dlPadT
        .byte $80,$0E,22,<sPadTit,>sPadTit
        .byte $02,$0E,0,$00,$FF                 ; dark band while counting

dlPadV
        .byte $84,$0E,22,<bufA,>bufA
        .byte $84,$0E,22,<bufB,>bufB
        .byte $C6,$0E,22,<bufC,>bufC
        .byte $C6,$0E,22,<bufD,>bufD
        .byte $0E,$00,8,$00,$FF
        .byte $00,$00,0,$00,$FF

; builds "Pn=hh " lines from the previous frame's counts
VPad SUBROUTINE
        ldx #0              ; paddle index
        ldy #0              ; buffer offset
.p      lda #_P
        sta bufA,y
        iny
        txa
        sta bufA,y          ; paddle number 0-3
        iny
        lda #_EQ
        sta bufA,y
        iny
        lda pd0,x
        lsr
        lsr
        lsr
        lsr
        sta bufA,y
        iny
        lda pd0,x
        and #$0F
        sta bufA,y
        iny
        lda #_SP
        sta bufA,y
        iny
        inx
        cpx #4
        bcc .p
        rts


; ---------------------------------------------------------------
; Screen 8 - ARTE: viewer for pixel art made in the editor
; (tools/pixel-editor.html). 32px wide art, no flicker: each
; player shows two close copies (NUSIZ=1) interleaved as
; P0 P1 P0 P1, and VDEL lets the GRPs be rewritten mid-scanline
; so all four 8px groups differ (classic 48px trick, 32px wide).
; Detail pixels (eyes/mouth/tongue) are HOLES in the sprites; a
; mirrored-playfield band (REF=1, PF2 bits only) sits behind the
; art with its own color per row (COLUPF) and shows through.
; PF2 blocks are symmetric around x=80: bit7 = art cols 12-19,
; bit6 = cols 8-11+20-23, bit5 = 4-7+24-27, bit4 = 0-3+28-31.
; ---------------------------------------------------------------

KArt SUBROUTINE
        lda #<dlArt
        sta dlPtr
        lda #>dlArt
        sta dlPtr+1
        jsr DrawDisplayList
        lda #1
        sta VDELP0          ; VDEL on both players: buffered GRPs
        sta VDELP1          ; make the mid-line swap tear-free
        sta NUSIZ0          ; two close copies: P0 covers groups
        sta NUSIZ1          ; 0/2, P1 covers groups 1/3
        sta CTRLPF          ; mirrored playfield: PF2 bits form a
                            ; symmetric band behind the art only
        lda #67             ; P0 copies at x=64 and x=80: the art
        ldx #0              ; must be centered on x=80, the mirror
        jsr PosObject       ; axis of the playfield band
        lda #75             ; P1 copies at x=72 and x=88
        ldx #1
        jsr PosObject
        sta WSYNC
        lda #$94            ; blue canvas
        sta COLUBK
        sta WSYNC
        ldy #31             ; tables are stored bottom-up: the loop
        lda ArtC0,y         ; counts y down (dey/bpl fits the line
        sta COLUP0          ; budget) while the beam draws the art
        lda ArtC1,y         ; top-down
        sta COLUP1
.row    sta WSYNC
        jsr .line           ; first scanline of the double row
        lda ArtC0-1,y       ; colors of the NEXT row parked in a
        sta TP0             ; scratch byte and X: applied at the
        lda ArtC1-1,y       ; end of the second scanline, past the
        tax                 ; art window
        sta WSYNC
        jsr .line           ; second scanline, same row
        stx COLUP1          ; 60
        lda TP0             ; 63
        sta COLUP0          ; 66: applied past the art window
        dey                 ; 68: LAST flag write before the branch
        bpl .row            ; 71 (72 crossing): +WSYNC stays <76
        sta WSYNC
        lda #0
        sta COLUBK          ; black below the canvas, still in
        sta PF2             ; hblank: clean bottom edge
        sta GRP0            ; VDEL: alternate GRP0/GRP1 so the
        sta GRP1            ; buffered (old) registers clear too
        sta GRP0
        sta CTRLPF
        sta VDELP0
        sta VDELP1
        rts

; one art scanline, cycle-exact: called right after sta WSYNC, the
; jsr's 6 cycles put the two tail stores in their write windows,
; with the beam between the copies of each player (47-49 / 50-52)
.line   lda ArtPF,y         ; 4 13: playfield band of this row
        sta PF2             ; (hblank)
        lda ArtCF,y         ; 4 20: band color (feature color)
        sta COLUPF
        lda ArtP0,y         ; 4 27: new GRP0 = G0
        sta GRP0
        lda ArtP1,y         ; 4 34: new GRP1 = G1, shows G0
        sta GRP1
        lda ArtP2,y         ; 4 41: new GRP0 = G2, shows G1
        sta GRP0
        lda ArtP3,y         ; 4 45: G3 in A
        sta GRP1            ; 48 (x=76): shows G2 on P0's 2nd copy
        sta GRP0            ; 51 (x=85): shows G3 on P1's 2nd copy
        rts                 ; 57

dlArt
        .byte $80,$0E,22,<sArtTit,>sArtTit
        .byte $00,$00,0,$00,$FF                 ; positioning happens on
                                                ; black, then KArt turns the
                                                ; canvas blue

; art tables, one byte per row, in REVERSED row order (index 0 =
; art row 31): the kernel scans y=31..0. Generated by
; tools/arte-convert.py from the editor's JSON export - the block
; between the markers below is REPLACED whole by tools/arte-server.py
; ("make editor"), do not edit it by hand. align 32 keeps each
; 32-byte table inside a single page (no +1 page-crossing penalty
; on the cycle-exact lda abs,y).
; >>> ARTE-TABELAS
; gerado por tools/arte-convert.py
; linhas em ordem INVERTIDA (indice 0 = linha 31 da arte):
; o kernel varre y=31..0
        align 32
ArtP0  .byte $00,$00,$01,$03,$07,$0F,$1F,$3F
       .byte $3F,$7E,$7C,$7D,$FB,$F3,$FF,$FF
       .byte $FF,$FF,$FE,$FC,$78,$7C,$7E,$3F
       .byte $3F,$1F,$0F,$07,$03,$01,$00,$00
ArtP1  .byte $0F,$7F,$FF,$FF,$FF,$F8,$C3,$9F
       .byte $7F,$7F,$FF,$FF,$FF,$FF,$FF,$FF
       .byte $FF,$FF,$7F,$3F,$1F,$3F,$7F,$FF
       .byte $FF,$FF,$FF,$FF,$FF,$FF,$7F,$0F
ArtP2  .byte $F0,$FE,$FF,$FF,$FF,$1F,$C3,$F9
       .byte $FE,$FE,$FF,$FF,$FF,$FF,$FF,$FF
       .byte $FF,$FF,$FE,$FC,$F8,$FC,$FE,$FF
       .byte $FF,$FF,$FF,$FF,$FF,$FF,$FE,$F0
ArtP3  .byte $00,$00,$80,$C0,$E0,$F0,$F8,$FC
       .byte $FC,$7E,$3E,$BE,$DF,$CF,$FF,$FF
       .byte $FF,$FF,$7F,$3F,$1E,$3E,$7E,$FC
       .byte $FC,$F8,$F0,$E0,$C0,$80,$00,$00
ArtC0  .byte $1C,$1C,$1C,$1C,$1C,$1C,$1C,$1C
       .byte $1C,$1C,$1C,$1C,$1C,$1C,$1C,$1C
       .byte $1C,$1C,$1C,$1C,$1C,$1C,$1C,$1C
       .byte $1C,$1C,$1C,$1C,$1C,$1C,$1C,$1C
ArtC1  .byte $1C,$1C,$1C,$1C,$1C,$1C,$1C,$1C
       .byte $1C,$1C,$1C,$1C,$1C,$1C,$1C,$1C
       .byte $1C,$1C,$1C,$1C,$1C,$1C,$1C,$1C
       .byte $1C,$1C,$1C,$1C,$1C,$1C,$1C,$1C
ArtPF  .byte $00,$00,$00,$00,$00,$80,$C0,$40
       .byte $40,$60,$20,$20,$20,$20,$00,$00
       .byte $00,$00,$60,$60,$60,$60,$60,$00
       .byte $00,$00,$00,$00,$00,$00,$00,$00
ArtCF  .byte $00,$00,$00,$00,$00,$00,$00,$00
       .byte $00,$00,$00,$00,$00,$00,$00,$00
       .byte $00,$00,$00,$00,$00,$00,$00,$00
       .byte $00,$00,$00,$00,$00,$00,$00,$00
; <<< ARTE-TABELAS

; ---------------------------------------------------------------
; Strings (char codes from font.asm)
; ---------------------------------------------------------------
sTitulo .byte _T,_E,_S,_T,_B,_R
sAzul   .byte _A,_Z,_U,_L,_SP,_SP
sVermel .byte _V,_E,_R,_M,_E,_L
sVerde  .byte _V,_E,_R,_D,_E,_SP
sLaranj .byte _L,_A,_R,_A,_N,_J
sAmarel .byte _A,_M,_A,_R,_E,_L
sBranco .byte _B,_R,_A,_N,_C,_O
sCtrl   .byte _C,_O,_N,_T,_R,_L
sCalTit .byte _C,_A,_L,_I,_B,_R
sArtTit .byte _A,_R,_T,_E,_SP,_SP
sRamTit .byte _R,_A,_M,_SP,_SP,_SP
sSomTit .byte _S,_O,_M,_SP,_SP,_SP
sTiaTit .byte _T,_I,_A,_SP,_SP,_SP
sPadTit .byte _P,_A,_D,_D,_L,_E
sRamOk  .byte _R,_A,_M,_SP,_O,_K
sRamEr  .byte _R,_A,_M,_SP,_E,_R
sMemOk  .byte _M,_E,_M,_SP,_O,_K
sMemEr  .byte _M,_E,_M,_SP,_E,_R
sTvCor  .byte _T,_V,_SP,_C,_O,_R
sTvPb   .byte _T,_V,_SP,_P,_B,_SP
