DASM    = tools/dasm
STELLA  = tools/stella/Stella.app/Contents/MacOS/Stella
ROM     = roms/testbr.bin
SRC     = src/main.asm src/engine.asm src/screens.asm src/font.asm

all: $(ROM)

$(ROM): $(SRC) include/vcs.h include/macro.h
	@mkdir -p roms
	$(DASM) src/main.asm -f3 -v0 -Iinclude -Isrc -o$(ROM) -lroms/testbr.lst -sroms/testbr.sym
	@ls -l $(ROM)

run: $(ROM)
	$(STELLA) $(ROM)

# opens with keyboard controllers (keypads) on both ports,
# for the keypad line of the CONTRL screen
run-keypad: $(ROM)
	$(STELLA) -lc Keyboard -rc Keyboard $(ROM)

# opens with paddles on both ports, for the PADDLE screen
run-paddle: $(ROM)
	$(STELLA) -lc Paddles -rc Paddles $(ROM)

tools/sim2600: tools/sim2600.c
	cc -O2 -o $@ $<

tools/winid: tools/winid.m
	clang -framework Foundation -framework CoreGraphics -o $@ $<

# headless smoke test: simulates 4 frames and checks frame stability
sim: $(ROM) tools/sim2600
	tools/sim2600 $(ROM) 4

# opens the ROM in Stella and saves a screenshot of the emulator window
shot: $(ROM) tools/winid
	tools/snapshot.sh $(ROM) shots

# pixel art editor with one-click write-to-ROM (http://127.0.0.1:2600)
editor:
	python3 tools/arte-server.py

clean:
	rm -f roms/testbr.bin roms/testbr.lst roms/testbr.sym tools/sim2600 tools/winid
	rm -rf shots

.PHONY: all run run-keypad run-paddle sim shot editor clean
