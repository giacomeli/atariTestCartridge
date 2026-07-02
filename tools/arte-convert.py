#!/usr/bin/env python3
"""Converte o JSON do tools/pixel-editor.html nas tabelas da tela ARTE.

Uso: python3 tools/arte-convert.py matriz.json [render.json] > tabelas.asm

A tela ARTE desenha 32x32 sem flicker: cada player tem 2 copias
proximas (P0 nos grupos de colunas 0-7/16-23, P1 em 8-15/24-31) com
reescrita de GRP no meio da scanline via VDEL, o que da 1 cor por
player por linha. Pixels de uma terceira cor (olhos, boca, lingua)
viram FUROS no sprite; uma banda de playfield espelhado (PF2 + REF)
fica atras da arte com uma cor por linha (COLUPF) e aparece pelos
furos.

Blocos simetricos da banda (REF=1, so PF2):
  bit7 -> cols 12-19 | bit6 -> cols 8-11 + 20-23
  bit5 -> cols 4-7 + 24-27 | bit4 -> cols 0-3 + 28-31

Para cada linha o conversor testa cada cor presente como candidata a
cor da banda (e banda nenhuma). Pixels que nao couberem em nenhuma
das 3 cores da linha sao APROXIMADOS pela mais proxima em RGB (cor
do player ou da banda), e vence a candidata com menos pixels
aproximados. Blocos de banda que aparecem fora do sprite (coluna
coberta sem furo e sem pixel) sao descartados individualmente: os
furos desses blocos voltam ao sprite como aproximacoes. Cada
aproximacao gera um aviso.

As tabelas saem com as linhas em ORDEM INVERTIDA (indice 0 = linha
31 da arte): o kernel varre y=31..0 com dey/bpl para caber no
orcamento de ciclos da scanline.

Se render.json for passado, grava a matriz efetivamente renderizada
(pos-aproximacoes) para diff automatizado contra o emulador.
"""
import json
import sys

BLOCKS = {
    0x80: set(range(12, 20)),
    0x40: set(range(8, 12)) | set(range(20, 24)),
    0x20: set(range(4, 8)) | set(range(24, 28)),
    0x10: set(range(0, 4)) | set(range(28, 32)),
}
TRANSPARENT = -1

# paleta NTSC amostrada do Stella 7.0 (mesma do pixel-editor.html)
PALETTE_HEX = [
    ["#000000","#3F3F3E","#646463","#848483","#A2A2A1","#BABAB9","#D2D2D1","#EAEAE9"],
    ["#3D3D00","#5D5E0A","#7C7B15","#999920","#B4B42A","#CDCD33","#E6E63E","#FDFC48"],
    ["#712300","#863D0C","#995718","#AD6F26","#BD8632","#CD9B3E","#DCB049","#E9C254"],
    ["#861500","#9A2F0E","#AE481E","#C0612E","#D1773D","#E08D4D","#EFA25C","#FDB567"],
    ["#8A0000","#9E1212","#B12827","#C23D3D","#D25150","#E26463","#EF7574","#FD8685"],
    ["#7A0058","#8D126E","#A02784","#B13B98","#C04EAA","#D061BC","#DD71CC","#EA82DC"],
    ["#450A77","#5D128F","#7227A4","#883BB9","#9B4ECA","#AE60DC","#BF71EC","#D082FB"],
    ["#0B1285","#2A1699","#4328AD","#5D3DBF","#7451D0","#8B64DF","#A175EE","#B586FB"],
    ["#00148A","#11179D","#2429B0","#373DC1","#4951D1","#5B64E0","#6A75EE","#7986FB"],
    ["#00157D","#123193","#244CA7","#3767BB","#4980CC","#5A97DD","#69AEED","#79C2FB"],
    ["#002658","#124574","#23618D","#377EA7","#4997BE","#5AB0D4","#6AC7E8","#79DDFB"],
    ["#003526","#125742","#24755E","#379576","#49B18E","#5BCCA5","#6AE5BB","#7AFDCF"],
    ["#003900","#125B13","#297927","#3D973C","#51B350","#64CD63","#76E674","#86FD85"],
    ["#0D3200","#2B5410","#487323","#639337","#7DB049","#95CB59","#ADE569","#C2FD78"],
    ["#272E00","#444E0F","#626B21","#7E8833","#97A343","#B0BC53","#C7D462","#DDEA70"],
    ["#3D2301","#5E420D","#7B5F1D","#997B2D","#B4963A","#CDAF4A","#E6C757","#FDDD64"],
]
RGB = {}
for hue, line in enumerate(PALETTE_HEX):
    for lum, hexa in enumerate(line):
        RGB[hue * 16 + lum * 2] = tuple(int(hexa[i:i + 2], 16) for i in (1, 3, 5))


def color_dist(a, b):
    return sum((x - y) ** 2 for x, y in zip(RGB[a], RGB[b]))


def player_of(col):
    return (col // 8) & 1        # grupos intercalados P0 P1 P0 P1


def solve_row(pxrow):
    """Escolhe banda/furos/cores de player minimizando aproximacoes.

    Retorna (holes, pf2, band_color, dom, approx) onde approx e a
    lista [(col, desenhado, renderizado)].
    """
    lit = [c for c in range(32) if pxrow[c] != TRANSPARENT]
    candidates = [None] + sorted({pxrow[c] for c in lit})
    best = None
    for band in candidates:
        holes = set(c for c in lit if pxrow[c] == band) if band is not None else set()
        dom = [0, 0]
        for _ in range(2):
            for p in (0, 1):
                vals = [pxrow[c] for c in lit
                        if player_of(c) == p and c not in holes]
                dom[p] = max(set(vals), key=vals.count) if vals else 0
            if band is None:
                break
            grown = set(holes)
            for c in lit:
                if c not in holes and color_dist(pxrow[c], band) < \
                        color_dist(pxrow[c], dom[player_of(c)]):
                    grown.add(c)
            if grown == holes:
                break
            holes = grown
        bits = 0
        for bit, cols in BLOCKS.items():
            if not any(c in cols for c in holes):
                continue
            if any(c not in holes and pxrow[c] == TRANSPARENT for c in cols):
                holes -= cols            # bloco vazaria fora do sprite:
                continue                 # devolve os furos ao sprite
            bits |= bit
        for p in (0, 1):                 # dominancia sem os furos finais
            vals = [pxrow[c] for c in lit
                    if player_of(c) == p and c not in holes]
            dom[p] = max(set(vals), key=vals.count) if vals else 0
        approx = []
        for c in lit:
            shown = band if c in holes else dom[player_of(c)]
            if shown != pxrow[c]:
                approx.append((c, pxrow[c], shown))
        bitcount = bin(bits).count('1')
        key = (len(approx), bitcount, band is not None)
        if best is None or key < best[0]:
            best = (key, holes, bits, band if holes else 0, dom, approx)
    _, holes, bits, band, dom, approx = best
    return holes, bits, band or 0, dom, approx


def convert(pixels):
    """Gera o bloco DASM da arte 32x32.

    Retorna (texto_asm, avisos, render) onde render e a matriz
    efetivamente exibida pela ROM (pos-aproximacoes).
    """
    warnings = []
    pats = [[0] * 32 for _ in range(4)]
    pcol = [[0] * 32 for _ in range(2)]
    pf2 = [0] * 32
    colupf = [0] * 32
    render = [[TRANSPARENT] * 32 for _ in range(32)]

    for row in range(32):
        holes, pf2[row], colupf[row], dom, approx = solve_row(pixels[row])
        for c, drawn, shown in approx:
            warnings.append(
                f'linha {row}, coluna {c}: ${drawn:02X} nao coube '
                f'(1 cor por player + 1 banda por linha); vira ${shown:02X}')
        for g in range(4):
            bits = 0
            for i in range(8):
                c = g * 8 + i
                if pixels[row][c] != TRANSPARENT and c not in holes:
                    bits |= 0x80 >> i
            pats[g][row] = bits
        for p in (0, 1):
            pcol[p][row] = dom[p]
        for c in range(32):
            if pixels[row][c] == TRANSPARENT:
                continue
            render[row][c] = colupf[row] if c in holes else dom[player_of(c)]

    out = []
    for w in warnings:
        out.append(f'; AVISO: {w}')
    out.append('; gerado por tools/arte-convert.py')
    out.append('; linhas em ordem INVERTIDA (indice 0 = linha 31 da arte):')
    out.append('; o kernel varre y=31..0')
    out.append('        align 32')

    def table(name, rows):
        rows = list(reversed(rows))
        for i in range(0, 32, 8):
            head = f'{name}  ' if i == 0 else '       '
            out.append(head + '.byte ' +
                       ','.join(f'${b:02X}' for b in rows[i:i + 8]))

    for g in range(4):
        table(f'ArtP{g}', pats[g])
    table('ArtC0', pcol[0])
    table('ArtC1', pcol[1])
    table('ArtPF', pf2)
    table('ArtCF', colupf)
    return '\n'.join(out), warnings, render


def main():
    data = json.load(open(sys.argv[1]))
    if data.get('largura') != 32 or data.get('altura') != 32:
        sys.exit('a tela ARTE espera arte 32x32')
    text, _, render = convert(data['pixels'])
    print(text)
    if len(sys.argv) > 2:
        json.dump({'largura': 32, 'altura': 32, 'pixels': render},
                  open(sys.argv[2], 'w'))


if __name__ == '__main__':
    main()
