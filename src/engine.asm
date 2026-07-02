; ---------------------------------------------------------------
; Display list engine
;
; A display list is a sequence of 5-byte entries describing
; horizontal bars, each optionally carrying one line of text
; rendered with the classic 48px (6 character) sprite kernel.
;
;   .byte bgColor, textColor, height, strLo, strHi
;
;   strHi = $FF  -> bar without text
;   height = 0   -> end of list (bgColor still applied)
;
; A text bar must be at least TEXTLINES+1 scanlines tall.
; ---------------------------------------------------------------

DrawDisplayList SUBROUTINE
        lda #0
        sta dlIdx
.entry  ldy dlIdx
        lda (dlPtr),y       ; background color
        sta WSYNC           ; ---- bar starts here
        sta COLUBK
        iny
        lda (dlPtr),y       ; text color; bit 0 (unused by the TIA
        sta COLUP0          ; luminance) selects single-height text
        sta COLUP1
        and #1
        sta textHalf
        iny
        lda (dlPtr),y       ; height in scanlines
        beq .done
        sta linesLeft
        iny
        lda (dlPtr),y       ; string pointer
        sta strPtr
        iny
        lda (dlPtr),y
        sta strPtr+1
        iny
        sty dlIdx
        dec linesLeft       ; current line counts as one
        cmp #$FF            ; strHi still in A
        bne .text
        jmp .pad
.done   rts

; ---- inline text block ----
; Renders one 6-character line, double height. Consumes exactly
; TEXTLINES (20) scanlines: 6 pointer-setup lines + 14 glyph lines.
; It is inlined (not a subroutine) so the entry line above stays
; under 76 cycles even with page-crossing penalties.
; The store sequence MUST run on every scanline - the three close
; copies of each player reuse one register, so skipping a line's
; stores would repeat a single character across all copies.
; Double height comes from the pre-doubled rows in the font data.
; Requires: strPtr -> 6 char codes, FontData page aligned,
; P0/P1 positioned by PrepTextSprites, NUSIZ=3 copies close, VDEL on.
.text   ldy #5
        ldx #10
.char   sta WSYNC           ; ---- one setup line per character
        lda (strPtr),y
        lsr
        lsr
        lsr
        lsr                 ; A = code / 16 (font page offset)
        clc
        adc #>FontData
        sta TP0+1,x
        lda (strPtr),y
        asl
        asl
        asl
        asl                 ; low byte of code * 16 (wraps by design)
        sta TP0,x
        dex
        dex
        dey
        bpl .char
        ; preload the first row; the row code is fully unrolled
        ; because a loop tail (dec/ldy/jmp) does not fit in the
        ; 22 cycles left after the six GRP stores
        lda textHalf
        beq .full
        jmp .halfRows
.full   ldy #FONTROWS-1
        lda (TP0),y
        sta GRP0            ; VDEL buffered
ROWN    SET FONTROWS-1
        REPEAT FONTROWS
        sta WSYNC           ; ---- one glyph scanline
        lda (TP1),y
        sta GRP1            ; commits char 0
        lda (TP2),y
        sta GRP0            ; commits char 1, buffers char 2
        lda (TP3),y
        sta temp
        lda (TP4),y
        tax
        lda (TP5),y
        tay
        lda temp
        sta.w GRP1          ; commits char 2 (absolute: +1 cycle to land
        stx GRP0            ; after char 0 finished drawing)
        sty GRP1            ; commits chars 3/4 in sequence
        sta GRP0            ; commits char 5
ROWN    SET ROWN-1
        IF ROWN >= 0
        ldy #ROWN
        lda (TP0),y
        sta GRP0            ; buffer char 0 for the next scanline
        ENDIF
        REPEND
        lda #0
        sta GRP0
        sta GRP1
        sta GRP0
        lda linesLeft
        sec
        sbc #TEXTLINES
        jmp .acct
        ; single height: the font rows are pre-doubled, so reading
        ; only the odd indices (13,11,...,1) yields each visual row once
.halfRows
        ldy #FONTROWS-1
        lda (TP0),y
        sta GRP0            ; VDEL buffered
ROWN    SET FONTROWS-1
        REPEAT 7
        sta WSYNC           ; ---- one glyph scanline
        lda (TP1),y
        sta GRP1
        lda (TP2),y
        sta GRP0
        lda (TP3),y
        sta temp
        lda (TP4),y
        tax
        lda (TP5),y
        tay
        lda temp
        sta.w GRP1
        stx GRP0
        sty GRP1
        sta GRP0
ROWN    SET ROWN-2
        IF ROWN >= 1
        ldy #ROWN
        lda (TP0),y
        sta GRP0
        ENDIF
        REPEND
        lda #0
        sta GRP0
        sta GRP1
        sta GRP0
        lda linesLeft
        sec
        sbc #TEXTLINES_S
.acct   sta linesLeft
        beq .next
        bmi .next
.pad    lda linesLeft
        beq .next
.padLoop
        sta WSYNC
        dec linesLeft
        bne .padLoop
.next   jmp .entry

; ---------------------------------------------------------------
; PrepTextSprites - configures and positions P0/P1 for the
; 48px text kernel. Runs every frame during vertical blank.
; ---------------------------------------------------------------
PrepTextSprites SUBROUTINE
        lda #%00000011      ; three copies close
        sta NUSIZ0
        sta NUSIZ1
        lda #1
        sta VDELP0
        sta VDELP1
        lda #0
        sta REFP0
        sta REFP1
        sta GRP0
        sta GRP1
        sta GRP0
        lda #0              ; screens with playfield restore it here
        sta PF0
        sta PF1
        sta PF2
        sta CTRLPF
        lda #POSX
        ldx #0
        jsr PosObject
        lda #POSX+8
        ldx #1
        jsr PosObject
        IFCONST CALIB
        ; playfield ruler for calibration builds: PF1 bit0 lights
        ; pixels 44-47 (left half) and 124-127 (right half)
        lda #$0E
        sta COLUPF
        lda #$01
        sta PF1
        lda #0
        sta PF0
        sta PF2
        sta CTRLPF
        ENDIF
        rts

; ---------------------------------------------------------------
; PosObject - standard horizontal positioning routine.
; A = x position (0-159), X = object index (0=P0 ... 4=BL)
; Consumes 3 scanlines.
; ---------------------------------------------------------------
PosObject SUBROUTINE
        sec
        sta WSYNC
.div    sbc #15             ; 15 pixels per loop iteration
        bcs .div
        eor #7
        asl
        asl
        asl
        asl
        sta HMP0,x
        sta RESP0,x
        sta WSYNC
        sta HMOVE
        sta WSYNC
        sta HMCLR           ; safe: 76 cycles after HMOVE
        rts
