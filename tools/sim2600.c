/*
 * sim2600 - minimal Atari 2600 (6507 + TIA/RIOT stubs) simulator
 * for tracing and regression-testing the TESTBR ROM without a GUI.
 *
 * It is NOT a full emulator: TIA is modeled only as a register file
 * with WSYNC line-syncing; RIOT implements the interval timer and
 * fixed input values. Good enough to trace code flow, frame timing
 * and every TIA register write with frame/scanline/cycle precision.
 *
 * usage: sim2600 <rom4k.bin> [frames] [-w]
 *   frames  number of frames to simulate (default 5)
 *   -w      dump every TIA write (frame line cycle reg value)
 *
 * build: cc -O2 -o sim2600 sim2600.c
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

static uint8_t rom[4096];
static uint8_t ram[128];

/* cpu state */
static uint8_t A, X, Y, SP, P;
static uint16_t PC;
static uint64_t cyc;            /* total color-clock/3 cycles      */

#define FC 0x01
#define FZ 0x02
#define FI 0x04
#define FD 0x08
#define FB 0x10
#define FU 0x20
#define FV 0x40
#define FN 0x80

/* tia/riot state */
static uint8_t tia[64];
static int dump_writes = 0;
static uint64_t frame_start_cyc = 0;
static int frame_no = 0;
static int prev_vsync = 0;

/* riot timer */
static uint64_t tim_written_at = 0;
static int tim_interval = 1024;
static int tim_value = 0;

/* per-line record for the frame map */
typedef struct { uint8_t colubk, vblank, pf1, pf2, pf0, colupf; int grp_writes; } LineRec;
static LineRec lines[1000];
static int nlines_rec = 0;

/* ---- player pixel renderer (-p mode) ----
 * Renders P0/P1 with NUSIZ close copies, VDEL and RESP/HMOVE
 * positioning by replaying the exact clock of every TIA write.
 * Good enough to preview the 48px text kernel as ASCII art.
 */
static int render_players = 0;
static int render_from = 0, render_to = 0;   /* scanline range */
static int render_frame = 2;                 /* frame to render */
static int sel_presses = 0;                  /* simulated SELECT presses */
static int sim_fire = 0;                     /* hold left fire (-f) */

typedef struct { int clock; uint8_t reg, val; } WEvent;
static WEvent evline[128];
static int nev = 0;

static int posP0 = 0, posP1 = 0;             /* pixel position 0-159 */
static uint8_t grp0_old, grp0_new, grp1_old, grp1_new;
static uint8_t vdel0, vdel1, nusiz0, nusiz1;
static int8_t hm_decode(uint8_t v) { int8_t d = v >> 4; return d >= 8 ? d - 16 : d; }
static uint8_t hmp0_reg, hmp1_reg;

static void render_line_and_reset(int line) {
    /* replay events in clock order (already ordered) and paint */
    char row[161];
    int e = 0;
    for (int x = 0; x < 160; x++) {
        int clk = 68 + x;
        while (e < nev && evline[e].clock <= clk) {
            uint8_t r = evline[e].reg, v = evline[e].val;
            switch (r) {
                case 0x1B: grp0_new = v; if (!vdel0) grp0_old = v;
                           if (vdel1) grp1_old = grp1_new; break;
                case 0x1C: grp1_new = v; if (!vdel1) grp1_old = v;
                           if (vdel0) grp0_old = grp0_new; break;
                case 0x25: vdel0 = v & 1; break;
                case 0x26: vdel1 = v & 1; break;
                case 0x04: nusiz0 = v & 7; break;
                case 0x05: nusiz1 = v & 7; break;
                case 0x10: posP0 = (clk < 68) ? 3 : clk - 68 + 5; break;
                case 0x11: posP1 = (clk < 68) ? 3 : clk - 68 + 5; break;
                case 0x20: hmp0_reg = v; break;
                case 0x21: hmp1_reg = v; break;
                case 0x2A: posP0 -= hm_decode(hmp0_reg);
                           posP1 -= hm_decode(hmp1_reg);
                           posP0 = ((posP0 % 160) + 160) % 160;
                           posP1 = ((posP1 % 160) + 160) % 160; break;
                case 0x2B: hmp0_reg = hmp1_reg = 0; break;
            }
            e++;
        }
        int on = 0;
        for (int c = 0; c < 3; c++) {
            int start0 = posP0 + c * 16, start1 = posP1 + c * 16;
            int d0 = x - start0, d1 = x - start1;
            if (d0 >= 0 && d0 < 8 && ((grp0_old >> (7 - d0)) & 1)) on = 1;
            if (d1 >= 0 && d1 < 8 && ((grp1_old >> (7 - d1)) & 1)) on = 1;
        }
        row[x] = on ? '#' : '.';
    }
    row[160] = 0;
    /* apply remaining events (past visible clocks) */
    while (e < nev) {
        uint8_t r = evline[e].reg, v = evline[e].val;
        switch (r) {
            case 0x1B: grp0_new = v; if (!vdel0) grp0_old = v;
                       if (vdel1) grp1_old = grp1_new; break;
            case 0x1C: grp1_new = v; if (!vdel1) grp1_old = v;
                       if (vdel0) grp0_old = grp0_new; break;
            case 0x25: vdel0 = v & 1; break;
            case 0x26: vdel1 = v & 1; break;
            case 0x04: nusiz0 = v & 7; break;
            case 0x05: nusiz1 = v & 7; break;
            case 0x10: posP0 = 3; break;   /* strobe in hblank of next line */
            case 0x11: posP1 = 3; break;
            case 0x20: hmp0_reg = v; break;
            case 0x21: hmp1_reg = v; break;
            case 0x2A: posP0 -= hm_decode(hmp0_reg);
                       posP1 -= hm_decode(hmp1_reg);
                       posP0 = ((posP0 % 160) + 160) % 160;
                       posP1 = ((posP1 % 160) + 160) % 160; break;
            case 0x2B: hmp0_reg = hmp1_reg = 0; break;
        }
        e++;
    }
    if (render_players && line >= render_from && line <= render_to)
        printf("l%03d %s\n", line, row);
    nev = 0;
}

static const char *tia_name(int r) {
    static const char *n[64] = {
        "VSYNC","VBLANK","WSYNC","RSYNC","NUSIZ0","NUSIZ1","COLUP0","COLUP1",
        "COLUPF","COLUBK","CTRLPF","REFP0","REFP1","PF0","PF1","PF2",
        "RESP0","RESP1","RESM0","RESM1","RESBL","AUDC0","AUDC1","AUDF0",
        "AUDF1","AUDV0","AUDV1","GRP0","GRP1","ENAM0","ENAM1","ENABL",
        "HMP0","HMP1","HMM0","HMM1","HMBL","VDELP0","VDELP1","VDELBL",
        "RESMP0","RESMP1","HMOVE","HMCLR","CXCLR","$2D","$2E","$2F",
        "$30","$31","$32","$33","$34","$35","$36","$37",
        "$38","$39","$3A","$3B","$3C","$3D","$3E","$3F"};
    return n[r & 0x3F];
}

static int cur_line(void)  { return (int)((cyc - frame_start_cyc) / 76); }
static int cur_cycle(void) { return (int)((cyc - frame_start_cyc) % 76); }

static void record_line(void) {
    int l = cur_line();
    if (l >= 0 && l < 1000) {
        lines[l].colubk = tia[0x09];
        lines[l].vblank = tia[0x01];
        lines[l].pf0 = tia[0x0D];
        lines[l].pf1 = tia[0x0E];
        lines[l].pf2 = tia[0x0F];
        lines[l].colupf = tia[0x08];
        if (l + 1 > nlines_rec) nlines_rec = l + 1;
    }
}

static int ram_dump = 0;

static void dump_frame_map(void) {
    printf("frame %d: %d scanlines\n", frame_no, nlines_rec);
    if (ram_dump && frame_no == render_frame) {
        for (int i = 0; i < 128; i += 16) {
            printf("  $%02X:", 0x80 + i);
            for (int j = 0; j < 16; j++) printf(" %02X", ram[i + j]);
            printf("\n");
        }
    }
    /* compact run-length map: line-range: vblank colubk pf1 */
    int i = 0;
    while (i < nlines_rec) {
        int j = i;
        while (j + 1 < nlines_rec &&
               lines[j+1].colubk == lines[i].colubk &&
               lines[j+1].vblank == lines[i].vblank &&
               lines[j+1].pf1 == lines[i].pf1) j++;
        printf("  lines %3d-%3d  vblank=%02X colubk=%02X pf012=%02X,%02X,%02X colupf=%02X\n",
               i, j, lines[i].vblank, lines[i].colubk,
               lines[i].pf0, lines[i].pf1, lines[i].pf2, lines[i].colupf);
        i = j + 1;
    }
    memset(lines, 0, sizeof(lines));
    nlines_rec = 0;
}

static void tia_write(int r, uint8_t v) {
    r &= 0x3F;
    if (dump_writes)
        printf("W f%-2d l%-3d c%-2d %-6s = %02X\n",
               frame_no, cur_line(), cur_cycle(), tia_name(r), v);
    if (r == 0x02) {                       /* WSYNC */
        record_line();
        if (render_players && frame_no == render_frame) render_line_and_reset(cur_line());
        cyc = cyc + (76 - (cyc - frame_start_cyc) % 76);
        return;
    }
    if (render_players && frame_no == render_frame && nev < 128) {
        /* the bus write happens on the store's final cycle */
        int wcyc = (int)(((cyc ? cyc - 1 : 0) - frame_start_cyc) % 76);
        evline[nev].clock = wcyc * 3 + 2;
        evline[nev].reg = (uint8_t)r;
        evline[nev].val = v;
        nev++;
    }
    if (r == 0x00) {                       /* VSYNC */
        int on = v & 2;
        if (on && !prev_vsync) {           /* frame boundary */
            record_line();
            dump_frame_map();
            frame_no++;
            frame_start_cyc = cyc - (cyc - frame_start_cyc) % 76;
        }
        prev_vsync = on;
    }
    tia[r] = v;
    record_line();
}

static uint8_t tia_read(int r) {
    r &= 0x0F;
    switch (r) {
        case 0x08: case 0x09: case 0x0A: case 0x0B: return 0x00; /* INPT0-3 */
        case 0x0C: return sim_fire ? 0x00 : 0x80;                /* INPT4 */
        case 0x0D: return 0x80;                                  /* INPT5 */
        default: return 0;                                        /* collisions */
    }
}

static void riot_write(uint16_t a, uint8_t v) {
    if ((a & 0x14) == 0x14) {              /* TIMxT */
        static const int iv[4] = {1, 8, 64, 1024};
        tim_interval = iv[a & 3];
        tim_value = v;
        tim_written_at = cyc;
    }
    /* SWACNT/SWBCNT ignored */
}

static uint8_t riot_read(uint16_t a) {
    switch (a & 7) {
        case 0: return 0xFF;               /* SWCHA: nothing pressed */
        case 1: return 0x00;               /* SWACNT */
        case 2:                            /* SWCHB: switches released */
            /* -s N: pulse SELECT on even frames 4,6,... N times */
            if (sel_presses && frame_no >= 4 &&
                frame_no < 4 + 2 * sel_presses && (frame_no & 1) == 0)
                return 0x3D;
            return 0x3F;
        case 3: return 0x00;               /* SWBCNT */
        case 4: {                          /* INTIM */
            uint64_t elapsed = cyc - tim_written_at;
            long ticks = (long)(elapsed / tim_interval);
            long vv = (long)tim_value - ticks;
            if (vv >= 0) return (uint8_t)vv;
            /* after underflow RIOT counts at clock rate */
            long over = (long)(elapsed - (uint64_t)(tim_value + 1) * tim_interval);
            return (uint8_t)(0xFF - (over & 0xFF));
        }
        default: return 0;
    }
}

static uint8_t rd(uint16_t a) {
    a &= 0x1FFF;
    if (a & 0x1000) return rom[a & 0x0FFF];
    if ((a & 0x80) == 0) return tia_read(a);
    if (a & 0x200) return riot_read(a);
    return ram[a & 0x7F];
}

static void wr(uint16_t a, uint8_t v) {
    a &= 0x1FFF;
    if (a & 0x1000) return;                /* rom write ignored */
    if ((a & 0x80) == 0) { tia_write(a, v); return; }
    if (a & 0x200) { riot_write(a, v); return; }
    ram[a & 0x7F] = v;
}

/* ---------------- 6502 core ---------------- */

static void setnz(uint8_t v) { P = (P & ~(FN|FZ)) | (v & FN) | (v ? 0 : FZ); }

static void push(uint8_t v) { wr(0x100 | SP, v); SP--; }
static uint8_t pop(void)    { SP++; return rd(0x100 | SP); }

/* addressing helpers return effective address; pagecross flag global */
static int pagecross;

static uint16_t a_imm(void)  { return PC++; }
static uint16_t a_zp(void)   { return rd(PC++); }
static uint16_t a_zpx(void)  { return (rd(PC++) + X) & 0xFF; }
static uint16_t a_zpy(void)  { return (rd(PC++) + Y) & 0xFF; }
static uint16_t a_abs(void)  { uint16_t a = rd(PC) | (rd(PC+1) << 8); PC += 2; return a; }
static uint16_t a_absx(void) { uint16_t b = rd(PC) | (rd(PC+1) << 8); PC += 2;
                               pagecross = ((b & 0xFF00) != ((b + X) & 0xFF00)); return b + X; }
static uint16_t a_absy(void) { uint16_t b = rd(PC) | (rd(PC+1) << 8); PC += 2;
                               pagecross = ((b & 0xFF00) != ((b + Y) & 0xFF00)); return b + Y; }
static uint16_t a_indx(void) { uint8_t z = rd(PC++) + X;
                               return rd(z) | (rd((uint8_t)(z + 1)) << 8); }
static uint16_t a_indy(void) { uint8_t z = rd(PC++);
                               uint16_t b = rd(z) | (rd((uint8_t)(z + 1)) << 8);
                               pagecross = ((b & 0xFF00) != ((b + Y) & 0xFF00)); return b + Y; }

static void adc(uint8_t m) {
    unsigned s = A + m + (P & FC);
    P = (P & ~(FC|FV)) | (s > 0xFF ? FC : 0)
      | ((~(A ^ m) & (A ^ s) & 0x80) ? FV : 0);
    A = (uint8_t)s; setnz(A);
}
static void sbc(uint8_t m) { adc(m ^ 0xFF); }
static void cmpr(uint8_t r, uint8_t m) {
    unsigned s = r - m;
    P = (P & ~FC) | (r >= m ? FC : 0);
    setnz((uint8_t)s);
}
static uint8_t asl_(uint8_t v) { P = (P & ~FC) | (v >> 7); v <<= 1; setnz(v); return v; }
static uint8_t lsr_(uint8_t v) { P = (P & ~FC) | (v & 1); v >>= 1; setnz(v); return v; }
static uint8_t rol_(uint8_t v) { int c = P & FC; P = (P & ~FC) | (v >> 7); v = (v << 1) | c; setnz(v); return v; }
static uint8_t ror_(uint8_t v) { int c = P & FC; P = (P & ~FC) | (v & 1); v = (v >> 1) | (c << 7); setnz(v); return v; }

static void branch(int cond) {
    int8_t off = (int8_t)rd(PC++);
    cyc += 2;
    if (cond) {
        uint16_t old = PC;
        PC += off;
        cyc += 1 + (((old & 0xFF00) != (PC & 0xFF00)) ? 1 : 0);
    }
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: sim2600 rom.bin [frames] [-w]\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f || fread(rom, 1, 4096, f) != 4096) { fprintf(stderr, "bad rom\n"); return 2; }
    fclose(f);
    int max_frames = 5;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "-w")) dump_writes = 1;
        else if (!strcmp(argv[i], "-p") && i + 2 < argc) {
            render_players = 1;            /* ASCII sprite preview */
            render_from = atoi(argv[++i]);
            render_to = atoi(argv[++i]);
        }
        else if (!strcmp(argv[i], "-r")) ram_dump = 1;
        else if (!strcmp(argv[i], "-f")) sim_fire = 1;
        else if (!strcmp(argv[i], "-s") && i + 1 < argc) {
            sel_presses = atoi(argv[++i]);
            render_frame = 4 + 2 * sel_presses + 4;
        }
        else max_frames = atoi(argv[i]);
    }

    A = X = Y = 0; SP = 0xFF; P = FU | FI;
    PC = rom[0xFFC & 0xFFF] | (rom[0xFFD & 0xFFF] << 8);
    printf("reset vector: %04X\n", PC);

    uint64_t max_cyc = 80000ULL * (max_frames + 2);
    while (cyc < max_cyc && frame_no < max_frames) {
        uint16_t ea;
        uint8_t op = rd(PC++);
        pagecross = 0;
        switch (op) {
        /* loads */
        case 0xA9: A = rd(a_imm()); setnz(A); cyc += 2; break;
        case 0xA5: A = rd(a_zp());  setnz(A); cyc += 3; break;
        case 0xB5: A = rd(a_zpx()); setnz(A); cyc += 4; break;
        case 0xAD: A = rd(a_abs()); setnz(A); cyc += 4; break;
        case 0xBD: A = rd(a_absx()); setnz(A); cyc += 4 + pagecross; break;
        case 0xB9: A = rd(a_absy()); setnz(A); cyc += 4 + pagecross; break;
        case 0xA1: A = rd(a_indx()); setnz(A); cyc += 6; break;
        case 0xB1: A = rd(a_indy()); setnz(A); cyc += 5 + pagecross; break;
        case 0xA2: X = rd(a_imm()); setnz(X); cyc += 2; break;
        case 0xA6: X = rd(a_zp());  setnz(X); cyc += 3; break;
        case 0xB6: X = rd(a_zpy()); setnz(X); cyc += 4; break;
        case 0xAE: X = rd(a_abs()); setnz(X); cyc += 4; break;
        case 0xBE: X = rd(a_absy()); setnz(X); cyc += 4 + pagecross; break;
        case 0xA0: Y = rd(a_imm()); setnz(Y); cyc += 2; break;
        case 0xA4: Y = rd(a_zp());  setnz(Y); cyc += 3; break;
        case 0xB4: Y = rd(a_zpx()); setnz(Y); cyc += 4; break;
        case 0xAC: Y = rd(a_abs()); setnz(Y); cyc += 4; break;
        case 0xBC: Y = rd(a_absx()); setnz(Y); cyc += 4 + pagecross; break;
        /* stores: cycles are added BEFORE the write so the bus write
         * lands on the instruction's final cycle (cyc-1) */
        case 0x85: ea = a_zp();  cyc += 3; wr(ea, A); break;
        case 0x95: ea = a_zpx(); cyc += 4; wr(ea, A); break;
        case 0x8D: ea = a_abs(); cyc += 4; wr(ea, A); break;
        case 0x9D: ea = a_absx(); cyc += 5; wr(ea, A); break;
        case 0x99: ea = a_absy(); cyc += 5; wr(ea, A); break;
        case 0x81: ea = a_indx(); cyc += 6; wr(ea, A); break;
        case 0x91: ea = a_indy(); cyc += 6; wr(ea, A); break;
        case 0x86: ea = a_zp();  cyc += 3; wr(ea, X); break;
        case 0x96: ea = a_zpy(); cyc += 4; wr(ea, X); break;
        case 0x8E: ea = a_abs(); cyc += 4; wr(ea, X); break;
        case 0x84: ea = a_zp();  cyc += 3; wr(ea, Y); break;
        case 0x94: ea = a_zpx(); cyc += 4; wr(ea, Y); break;
        case 0x8C: ea = a_abs(); cyc += 4; wr(ea, Y); break;
        /* transfers */
        case 0xAA: X = A; setnz(X); cyc += 2; break;
        case 0xA8: Y = A; setnz(Y); cyc += 2; break;
        case 0x8A: A = X; setnz(A); cyc += 2; break;
        case 0x98: A = Y; setnz(A); cyc += 2; break;
        case 0xBA: X = SP; setnz(X); cyc += 2; break;
        case 0x9A: SP = X; cyc += 2; break;
        /* stack */
        case 0x48: push(A); cyc += 3; break;
        case 0x68: A = pop(); setnz(A); cyc += 4; break;
        case 0x08: push(P | FB | FU); cyc += 3; break;
        case 0x28: P = (pop() | FU) & ~FB; cyc += 4; break;
        /* alu */
        case 0x69: adc(rd(a_imm())); cyc += 2; break;
        case 0x65: adc(rd(a_zp()));  cyc += 3; break;
        case 0x75: adc(rd(a_zpx())); cyc += 4; break;
        case 0x6D: adc(rd(a_abs())); cyc += 4; break;
        case 0x7D: adc(rd(a_absx())); cyc += 4 + pagecross; break;
        case 0x79: adc(rd(a_absy())); cyc += 4 + pagecross; break;
        case 0x61: adc(rd(a_indx())); cyc += 6; break;
        case 0x71: adc(rd(a_indy())); cyc += 5 + pagecross; break;
        case 0xE9: sbc(rd(a_imm())); cyc += 2; break;
        case 0xE5: sbc(rd(a_zp()));  cyc += 3; break;
        case 0xF5: sbc(rd(a_zpx())); cyc += 4; break;
        case 0xED: sbc(rd(a_abs())); cyc += 4; break;
        case 0xFD: sbc(rd(a_absx())); cyc += 4 + pagecross; break;
        case 0xF9: sbc(rd(a_absy())); cyc += 4 + pagecross; break;
        case 0xE1: sbc(rd(a_indx())); cyc += 6; break;
        case 0xF1: sbc(rd(a_indy())); cyc += 5 + pagecross; break;
        case 0x29: A &= rd(a_imm()); setnz(A); cyc += 2; break;
        case 0x25: A &= rd(a_zp());  setnz(A); cyc += 3; break;
        case 0x35: A &= rd(a_zpx()); setnz(A); cyc += 4; break;
        case 0x2D: A &= rd(a_abs()); setnz(A); cyc += 4; break;
        case 0x3D: A &= rd(a_absx()); setnz(A); cyc += 4 + pagecross; break;
        case 0x39: A &= rd(a_absy()); setnz(A); cyc += 4 + pagecross; break;
        case 0x21: A &= rd(a_indx()); setnz(A); cyc += 6; break;
        case 0x31: A &= rd(a_indy()); setnz(A); cyc += 5 + pagecross; break;
        case 0x09: A |= rd(a_imm()); setnz(A); cyc += 2; break;
        case 0x05: A |= rd(a_zp());  setnz(A); cyc += 3; break;
        case 0x15: A |= rd(a_zpx()); setnz(A); cyc += 4; break;
        case 0x0D: A |= rd(a_abs()); setnz(A); cyc += 4; break;
        case 0x1D: A |= rd(a_absx()); setnz(A); cyc += 4 + pagecross; break;
        case 0x19: A |= rd(a_absy()); setnz(A); cyc += 4 + pagecross; break;
        case 0x01: A |= rd(a_indx()); setnz(A); cyc += 6; break;
        case 0x11: A |= rd(a_indy()); setnz(A); cyc += 5 + pagecross; break;
        case 0x49: A ^= rd(a_imm()); setnz(A); cyc += 2; break;
        case 0x45: A ^= rd(a_zp());  setnz(A); cyc += 3; break;
        case 0x55: A ^= rd(a_zpx()); setnz(A); cyc += 4; break;
        case 0x4D: A ^= rd(a_abs()); setnz(A); cyc += 4; break;
        case 0x5D: A ^= rd(a_absx()); setnz(A); cyc += 4 + pagecross; break;
        case 0x59: A ^= rd(a_absy()); setnz(A); cyc += 4 + pagecross; break;
        case 0x41: A ^= rd(a_indx()); setnz(A); cyc += 6; break;
        case 0x51: A ^= rd(a_indy()); setnz(A); cyc += 5 + pagecross; break;
        /* compares */
        case 0xC9: cmpr(A, rd(a_imm())); cyc += 2; break;
        case 0xC5: cmpr(A, rd(a_zp()));  cyc += 3; break;
        case 0xD5: cmpr(A, rd(a_zpx())); cyc += 4; break;
        case 0xCD: cmpr(A, rd(a_abs())); cyc += 4; break;
        case 0xDD: cmpr(A, rd(a_absx())); cyc += 4 + pagecross; break;
        case 0xD9: cmpr(A, rd(a_absy())); cyc += 4 + pagecross; break;
        case 0xC1: cmpr(A, rd(a_indx())); cyc += 6; break;
        case 0xD1: cmpr(A, rd(a_indy())); cyc += 5 + pagecross; break;
        case 0xE0: cmpr(X, rd(a_imm())); cyc += 2; break;
        case 0xE4: cmpr(X, rd(a_zp()));  cyc += 3; break;
        case 0xEC: cmpr(X, rd(a_abs())); cyc += 4; break;
        case 0xC0: cmpr(Y, rd(a_imm())); cyc += 2; break;
        case 0xC4: cmpr(Y, rd(a_zp()));  cyc += 3; break;
        case 0xCC: cmpr(Y, rd(a_abs())); cyc += 4; break;
        /* read-modify-write */
        case 0x0A: A = asl_(A); cyc += 2; break;
        case 0x06: ea = a_zp();  wr(ea, asl_(rd(ea))); cyc += 5; break;
        case 0x16: ea = a_zpx(); wr(ea, asl_(rd(ea))); cyc += 6; break;
        case 0x0E: ea = a_abs(); wr(ea, asl_(rd(ea))); cyc += 6; break;
        case 0x1E: ea = a_absx(); wr(ea, asl_(rd(ea))); cyc += 7; break;
        case 0x4A: A = lsr_(A); cyc += 2; break;
        case 0x46: ea = a_zp();  wr(ea, lsr_(rd(ea))); cyc += 5; break;
        case 0x56: ea = a_zpx(); wr(ea, lsr_(rd(ea))); cyc += 6; break;
        case 0x4E: ea = a_abs(); wr(ea, lsr_(rd(ea))); cyc += 6; break;
        case 0x5E: ea = a_absx(); wr(ea, lsr_(rd(ea))); cyc += 7; break;
        case 0x2A: A = rol_(A); cyc += 2; break;
        case 0x26: ea = a_zp();  wr(ea, rol_(rd(ea))); cyc += 5; break;
        case 0x36: ea = a_zpx(); wr(ea, rol_(rd(ea))); cyc += 6; break;
        case 0x2E: ea = a_abs(); wr(ea, rol_(rd(ea))); cyc += 6; break;
        case 0x3E: ea = a_absx(); wr(ea, rol_(rd(ea))); cyc += 7; break;
        case 0x6A: A = ror_(A); cyc += 2; break;
        case 0x66: ea = a_zp();  wr(ea, ror_(rd(ea))); cyc += 5; break;
        case 0x76: ea = a_zpx(); wr(ea, ror_(rd(ea))); cyc += 6; break;
        case 0x6E: ea = a_abs(); wr(ea, ror_(rd(ea))); cyc += 6; break;
        case 0x7E: ea = a_absx(); wr(ea, ror_(rd(ea))); cyc += 7; break;
        case 0xE6: ea = a_zp();  { uint8_t v = rd(ea)+1; wr(ea,v); setnz(v);} cyc += 5; break;
        case 0xF6: ea = a_zpx(); { uint8_t v = rd(ea)+1; wr(ea,v); setnz(v);} cyc += 6; break;
        case 0xEE: ea = a_abs(); { uint8_t v = rd(ea)+1; wr(ea,v); setnz(v);} cyc += 6; break;
        case 0xFE: ea = a_absx(); { uint8_t v = rd(ea)+1; wr(ea,v); setnz(v);} cyc += 7; break;
        case 0xC6: ea = a_zp();  { uint8_t v = rd(ea)-1; wr(ea,v); setnz(v);} cyc += 5; break;
        case 0xD6: ea = a_zpx(); { uint8_t v = rd(ea)-1; wr(ea,v); setnz(v);} cyc += 6; break;
        case 0xCE: ea = a_abs(); { uint8_t v = rd(ea)-1; wr(ea,v); setnz(v);} cyc += 6; break;
        case 0xDE: ea = a_absx(); { uint8_t v = rd(ea)-1; wr(ea,v); setnz(v);} cyc += 7; break;
        case 0xE8: X++; setnz(X); cyc += 2; break;
        case 0xCA: X--; setnz(X); cyc += 2; break;
        case 0xC8: Y++; setnz(Y); cyc += 2; break;
        case 0x88: Y--; setnz(Y); cyc += 2; break;
        /* bit */
        case 0x24: { uint8_t m = rd(a_zp());
                     P = (P & ~(FN|FV|FZ)) | (m & (FN|FV)) | ((A & m) ? 0 : FZ); } cyc += 3; break;
        case 0x2C: { uint8_t m = rd(a_abs());
                     P = (P & ~(FN|FV|FZ)) | (m & (FN|FV)) | ((A & m) ? 0 : FZ); } cyc += 4; break;
        /* jumps */
        case 0x4C: PC = a_abs(); cyc += 3; break;
        case 0x6C: { uint16_t p = a_abs();
                     PC = rd(p) | (rd((uint16_t)((p & 0xFF00) | ((p + 1) & 0xFF))) << 8); }
                   cyc += 5; break;
        case 0x20: { uint16_t t = a_abs(); push((PC-1) >> 8); push((PC-1) & 0xFF); PC = t; }
                   cyc += 6; break;
        case 0x60: PC = (pop() | (pop() << 8)) + 1; cyc += 6; break;
        case 0x40: P = (pop() | FU) & ~FB; PC = pop() | (pop() << 8); cyc += 6; break;
        /* branches */
        case 0xD0: branch(!(P & FZ)); break;
        case 0xF0: branch(P & FZ); break;
        case 0x10: branch(!(P & FN)); break;
        case 0x30: branch(P & FN); break;
        case 0x90: branch(!(P & FC)); break;
        case 0xB0: branch(P & FC); break;
        case 0x50: branch(!(P & FV)); break;
        case 0x70: branch(P & FV); break;
        /* flags */
        case 0x18: P &= ~FC; cyc += 2; break;
        case 0x38: P |= FC; cyc += 2; break;
        case 0x58: P &= ~FI; cyc += 2; break;
        case 0x78: P |= FI; cyc += 2; break;
        case 0xB8: P &= ~FV; cyc += 2; break;
        case 0xD8: P &= ~FD; cyc += 2; break;
        case 0xF8: P |= FD; cyc += 2; break;
        case 0xEA: cyc += 2; break;
        default:
            printf("ILLEGAL/JAM opcode %02X at PC=%04X (frame %d line %d)\n",
                   op, (uint16_t)(PC - 1), frame_no, cur_line());
            printf("A=%02X X=%02X Y=%02X SP=%02X P=%02X\n", A, X, Y, SP, P);
            return 1;
        }
    }
    printf("simulated %llu cycles, %d frames\n", (unsigned long long)cyc, frame_no);
    return 0;
}
