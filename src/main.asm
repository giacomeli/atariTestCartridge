; ---------------------------------------------------------------
; TESTBR - Atari 2600 diagnostic cartridge (open source)
; Target: NTSC, 4K ROM
; Assembler: DASM
; ---------------------------------------------------------------

        processor 6502
NO_ILLEGAL_OPCODES = 1      ; a diagnostic cart must not rely on
                            ; unstable undocumented opcodes
        include "vcs.h"
        include "macro.h"

; ---------------------------------------------------------------
; Constants
; ---------------------------------------------------------------
FONTH       = 7             ; glyph height in visual rows
FONTROWS    = 14            ; scanlines per glyph (rows pre-doubled in ROM)
NSCREENS    = 8
TEXTLINES   = 21            ; scanlines consumed by a text block:
                            ; 6 pointer-setup lines + 14 glyph lines
                            ; + 1 spill line (the accounting after the
                            ; last row overflows into one extra line)
TEXTLINES_S = 14            ; single-height variant: 6 + 7 + 1 spill
                            ; (selected by bit 0 of the entry text color)

SCR_ART     = 0             ; splash: advances by itself after 7 s
SCR_CORES   = 1
SCR_CAL     = 2
SCR_CTRL    = 3
SCR_RAM     = 4
SCR_SOM     = 5
SCR_TIA     = 6
SCR_PAD     = 7

SPLASH_TICKS = 210          ; 7 s: one tick every 2 frames (NTSC)

; horizontal position of the 48px text window; the GRP commit
; timing of the text kernel only works in a narrow range
; (calibrated empirically with tools/sim2600 and Stella)
        IFNCONST POSX
POSX    = 58
        ENDIF

; ---------------------------------------------------------------
; RAM ($80-$FF)
; ---------------------------------------------------------------
        SEG.U vars
        ORG $80

frameCnt    ds 1
screenId    ds 1
navPrev     ds 1            ; previous nav bits (debounce)
splashCnt   ds 1            ; splash timer ticks on the ART screen

strPtr      ds 2            ; current text string
TP0         ds 2            ; six glyph pointers used by the text kernel
TP1         ds 2
TP2         ds 2
TP3         ds 2
TP4         ds 2
TP5         ds 2
linesLeft   ds 1
dlPtr       ds 2            ; current display list
dlIdx       ds 1
jmpPtr      ds 2

ramBoot     ds 1            ; 0 = power-up RAM test passed
romSumLo    ds 1            ; ROM checksum (16 bit sum of all 4K)
romSumHi    ds 1
temp        ds 1
textHalf    ds 1            ; 1 = current text bar is single height

swchbNow    ds 1            ; cached console switches
joyNow      ds 1            ; cached SWCHA (valid in stick mode)

kpTmpL      ds 1            ; keypad scan in progress
kpTmpR      ds 1
kpKeyL      ds 1            ; last committed keypad chars
kpKeyR      ds 1

ramPtr      ds 1            ; continuous RAM test cursor
ramErr      ds 1            ; errors in the current pass
ramLive     ds 1            ; 0 = last completed pass clean

sndFreq     ds 1
sndTone     ds 1
sndCh       ds 1

obX         ds 5            ; TIA object screen: x positions P0 P1 M0 M1 BL
obDir       ds 5            ; and signed speeds

pd0         ds 1            ; paddle line counters
pd1         ds 1
pd2         ds 1
pd3         ds 1

bufA        ds 6            ; six-character RAM strings (live lines)
bufB        ds 6
bufC        ds 6
bufD        ds 6
bufE        ds 6
bufF        ds 6

; ---------------------------------------------------------------
; Code
; ---------------------------------------------------------------
        SEG code
        ORG $F000

Reset SUBROUTINE
        sei
        cld
        ; ---- destructive RAM test at power-up, registers only ----
        ; Y = error flag (0 = ok)
        ldy #0
        lda #$55
        ldx #$80
.fill55 sta $00,x
        inx
        bne .fill55
        ldx #$80
.ver55  cmp $00,x
        bne .fail
        inx
        bne .ver55
        lda #$AA
        ldx #$80
.fillAA sta $00,x
        inx
        bne .fillAA
        ldx #$80
.verAA  cmp $00,x
        bne .fail
        inx
        bne .verAA
        ; address-echo pass: each byte holds its own address
        ldx #$80
.fillAD txa
        sta $00,x
        inx
        bne .fillAD
        ldx #$80
.verAD  txa
        cmp $00,x
        bne .fail
        inx
        bne .verAD
        jmp .ramdone
.fail   ldy #1
.ramdone
        ; inline CLEAN_START variant: clears TIA/RAM and sets the
        ; stack WITHOUT the unstable LXA opcode from macro.h and
        ; WITHOUT clobbering Y (which holds the RAM test result)
        ldx #0
        txa
.clear  dex
        txs
        pha
        bne .clear
        sty ramBoot

        ; ---- ROM checksum: 16 bit sum of $F000-$FFFF ----
        lda #0
        sta strPtr
        sta romSumLo
        sta romSumHi
        lda #$F0
        sta strPtr+1
        ldx #16             ; 16 pages
        ldy #0
.sumLoop
        lda romSumLo
        clc
        adc (strPtr),y
        sta romSumLo
        bcc .noCarry
        inc romSumHi
.noCarry
        iny
        bne .sumLoop
        inc strPtr+1
        dex
        bne .sumLoop

        ; ---- one-time state ----
        lda #_DASH
        sta kpKeyL
        sta kpKeyR
        sta kpTmpL
        sta kpTmpR
        ldx #9              ; object positions and speeds
.obInit lda ObInitTab,x
        sta obX,x
        dex
        bpl .obInit
        IFCONST STARTSCR    ; debug builds: boot straight into a screen
        lda #STARTSCR
        sta screenId
        ENDIF
        lda SWCHB           ; init nav debounce with current state
        and #%00000010
        eor #%00000010
        sta navPrev

; ---------------------------------------------------------------
; Frame loop
; ---------------------------------------------------------------
MainLoop SUBROUTINE
        ; ---- vertical sync: 3 lines ----
        sta WSYNC
        lda #2
        sta VSYNC
        sta WSYNC
        sta WSYNC
        sta WSYNC
        lda #0
        sta VSYNC

        ; ---- vertical blank: ~37 lines ----
        lda #42
        sta TIM64T
        inc frameCnt
        jsr ReadInputs
        jsr PrepTextSprites
        jsr VBlankLogic
.vbWait lda INTIM
        bne .vbWait
        sta WSYNC
        ldx screenId        ; A = 0: display on, paddle dump off
        cpx #SCR_PAD
        bne .vbOn
        lda #%10000000      ; paddle screen: keep the pots grounded
.vbOn   sta VBLANK          ; (bit 7 does not blank video) until the
                            ; counting region starts, so the counters
                            ; measure the charge time precisely

        ; ---- visible frame: 192 lines ----
        lda #231
        sta TIM64T
        jsr RunKernel
.visWait
        lda INTIM
        bne .visWait
        sta WSYNC
        lda #%00000010
        ldx screenId
        cpx #SCR_PAD
        bne .noDump
        lda #%10000010      ; paddle screen: ground the pots in blanking
.noDump sta VBLANK

        ; ---- overscan: ~30 lines ----
        lda #31
        sta TIM64T
        jsr OverscanLogic
.osWait lda INTIM
        bne .osWait
        jmp MainLoop

; ---------------------------------------------------------------
; Input reading and screen navigation
;   SELECT advances to the next screen on every screen.
;   Joystick right/left changes screens too, except on the
;   controller screen (the stick is what is being tested there).
; ---------------------------------------------------------------
ReadInputs SUBROUTINE
        lda SWCHB
        sta swchbNow
        ; keypad column read happens in scan phases 1-4 (CTRL screen)
        lda screenId
        cmp #SCR_CTRL
        bne .stick
        lda frameCnt
        and #$0F
        beq .kpReset
        cmp #5
        bcs .stick          ; phases 5-15: SWACNT is back to input
        jsr KeypadRead      ; phases 1-4: read columns of row phase-1
        jmp .nav
.kpReset
        lda #_DASH          ; phase 0: start a fresh scan
        sta kpTmpL
        sta kpTmpR
        jmp .nav
.stick  lda SWCHA
        sta joyNow
.nav    ; build nav bits: select=bit1, right=bit7, left=bit6 (1 = active)
        lda swchbNow
        and #%00000010
        eor #%00000010      ; 1 = select pressed
        sta temp
        lda screenId
        cmp #SCR_CTRL
        beq .edge           ; no stick nav while testing the stick
        lda joyNow
        eor #$FF            ; 1 = pressed
        and #%11000000
        ora temp
        sta temp
.edge   lda temp
        tay                 ; Y = current state
        lda navPrev
        eor #$FF
        and temp            ; A = rising edges
        sty navPrev
        tax                 ; X = edges
        beq .done
        and #%10000010      ; select or right: next screen
        beq .prevScr
        inc screenId
        lda screenId
        cmp #NSCREENS
        bcc .changed
        lda #0
        sta screenId
        beq .changed
.prevScr
        txa
        and #%01000000      ; left: previous screen
        beq .done
        dec screenId
        bpl .changed
        lda #NSCREENS-1
        sta screenId
.changed
        lda #0              ; manual screen change: restart the
        sta splashCnt       ; splash timer for the next ART visit
.done   rts

; ---------------------------------------------------------------
; Keypad column read for row (phase-1). Rows were driven low in
; the previous overscan; the pot lines had a full frame to settle.
; Key numbers: row*3+col -> 1..9, then *, 0, # on the last row.
; ---------------------------------------------------------------
KeypadRead SUBROUTINE
        sec
        sbc #1              ; A = row 0-3 (phase was 1-4)
        sta temp
        asl
        adc temp            ; A = row*3
        sta temp            ; base key index (0,3,6,9)
        ; left port: col0=INPT0, col1=INPT1, col2=INPT4 (bit7=0 pressed)
        ; if INPT0 AND INPT1 read low the pot lines are floating
        ; (no keypad attached) - report nothing
        ldx #0
        lda INPT0
        bmi .ltry1
        lda INPT1
        bpl .lNone
        bmi .lgot           ; always (N set)
.ltry1  inx
        lda INPT1
        bpl .lgot
        inx
        lda INPT4
        bmi .lNone
.lgot   txa
        clc
        adc temp
        tax
        lda KeyChar,x
        sta kpTmpL
.lNone  ; right port: col0=INPT2, col1=INPT3, col2=INPT5
        ldx #0
        lda INPT2
        bmi .rtry1
        lda INPT3
        bpl .rNone          ; both low: floating, no keypad
        bmi .rgot           ; always (N set)
.rtry1  inx
        lda INPT3
        bpl .rgot
        inx
        lda INPT5
        bmi .rNone
.rgot   txa
        clc
        adc temp
        tax
        lda KeyChar,x
        sta kpTmpR
.rNone  ; commit at the end of the scan (phase 4)
        lda frameCnt
        and #$0F
        cmp #4
        bne .out
        lda kpTmpL
        sta kpKeyL
        lda kpTmpR
        sta kpKeyR
.out    rts

; key index -> char code (rows 1-3 are the digits 1-9)
KeyChar .byte _1,_2,_3,_4,_5,_6,_7,_8,_9,_X,_0,_H

; ---------------------------------------------------------------
; Kernel and logic dispatch
; ---------------------------------------------------------------
RunKernel SUBROUTINE
        ldx screenId
        lda KernelTabLo,x
        sta jmpPtr
        lda KernelTabHi,x
        sta jmpPtr+1
        jmp (jmpPtr)

VBlankLogic SUBROUTINE
        ldx screenId
        lda VLogicTabLo,x
        sta jmpPtr
        lda VLogicTabHi,x
        sta jmpPtr+1
        jmp (jmpPtr)

OverscanLogic SUBROUTINE
        ldx screenId
        lda OLogicTabLo,x
        sta jmpPtr
        lda OLogicTabHi,x
        sta jmpPtr+1
        jmp (jmpPtr)

KernelTabLo
        .byte <KArt,<KCores,<KCal,<KCtrl,<KRam,<KSom,<KTia,<KPad
KernelTabHi
        .byte >KArt,>KCores,>KCal,>KCtrl,>KRam,>KSom,>KTia,>KPad
VLogicTabLo
        .byte <VArt,<VNull,<VNull,<VCtrl,<VRam,<VSom,<VNull,<VPad
VLogicTabHi
        .byte >VArt,>VNull,>VNull,>VCtrl,>VRam,>VSom,>VNull,>VPad
OLogicTabLo
        .byte <ONull,<ONull,<ONull,<OCtrl,<ONull,<OSom,<OTia,<ONull
OLogicTabHi
        .byte >ONull,>ONull,>ONull,>OCtrl,>ONull,>OSom,>OTia,>ONull

VNull SUBROUTINE
        rts

; splash timer: the ART screen advances to the next screen by
; itself after SPLASH_TICKS ticks (one tick every 2 frames);
; SELECT still skips it at any time via ReadInputs
VArt SUBROUTINE
        lda frameCnt
        lsr
        bcs .out
        inc splashCnt
        lda splashCnt
        cmp #SPLASH_TICKS
        bcc .out
        lda #0
        sta splashCnt
        inc screenId
.out    rts

; silence both audio channels outside the sound screen
ONull SUBROUTINE
        lda #0
        sta AUDV0
        sta AUDV1
        rts

; initial object positions and speeds for the TIA screen
ObInitTab
        .byte 20,60,90,120,40       ; obX: P0 P1 M0 M1 BL
        .byte 1,2,3,254,255         ; obDir (254 = -2, 255 = -1)

        include "engine.asm"
        include "screens.asm"
        include "font.asm"

; ---------------------------------------------------------------
; Vectors
; ---------------------------------------------------------------
        ORG $FFFA
        .word Reset         ; NMI
        .word Reset         ; RESET
        .word Reset         ; IRQ
