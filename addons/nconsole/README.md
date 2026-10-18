# NConsole

A small 8-bit game console that runs inside Godot: its own processor (N8),
memory, cartridges, video and controller, and an assembler to write games
for it. It is independent of AgoraOS. This first version is written in
GDScript to settle the design; a C++ (GDExtension) core can replace the CPU
later without changing cartridges.

Tests: `godot --headless --path . -s addons/nconsole/tests/run_tests.gd`
(`BENCH=1` also prints how fast the CPU runs).

## The N8 processor

8-bit data, 16-bit addresses (64 KB). Clocked at 1.789773 MHz, like the
NTSC consoles of the 80s: 29,829 cycles per frame at 60 frames a second.
(The GDScript CPU manages about 1.2 M cycles a second, so a game that never
sleeps would run slow until the C++ core exists.)

| Register | |
|---|---|
| A | accumulator: arithmetic and logic work on it |
| X, Y | index registers |
| SP | stack pointer; the stack is page `$01` and grows down from `$01FF` |
| PC | program counter |
| N V I Z C | flags: negative, overflow, interrupts off, zero, carry |

Carry is set by a carry out of addition and by a **borrow** in subtraction.
So after `cmp #n`, `jc` means A < n and `jnc` means A >= n (unsigned).

### Addressing

| Syntax | Mode | Bytes | Cycles |
|---|---|---|---|
| `inc x` | implied / registers | 1 | 2 |
| `ld a, #10` | immediate | 2 | 2 |
| `ld a, score` | absolute | 3 | 4 |
| `ld a, table,x` / `table,y` | indexed | 3 | 5 |
| `ld a, [ptr],y` | indirect: 16-bit pointer at `ptr`, plus Y | 3 | 6 |
| `jz label` | relative, -128..+127 bytes | 2 | 3 (+1 taken) |
| `jmp [vector]` | jump through a pointer | 3 | 6 |

Read-modify-write on memory (`inc`, `dec`, shifts) costs 2 cycles more.

### Instructions

| | |
|---|---|
| `ld r, src` / `st r, dst` | load / store A, X, Y (A has every mode; X and Y have immediate, absolute and indexing by the other register) |
| `add` `adc` `sub` `sbc` | A plus/minus operand (with carry/borrow) |
| `and` `or` `xor` | logic on A |
| `cmp src`, `cmp x, src`, `cmp y, src` | compare without storing |
| `inc` `dec` | A, X, Y, or memory |
| `shl` `shr` `rol` `ror` | shifts and rotates through carry, on A or memory |
| `mov a, x` `mov x, a` `mov a, y` `mov y, a` `mov x, sp` `mov sp, x` | register copies |
| `push r` / `pop r` | A, X, Y or F (the flags) |
| `jmp` `call` `ret` `reti` | jumps, subroutines, return from interrupt |
| `jz` `jnz` `jc` `jnc` `jn` `jnn` `jr` | relative branches (`jr` always) |
| `clc` `sec` `cli` `sei` | carry and interrupt flags |
| `wait` | sleep until the next frame |
| `halt` | stop until reset |
| `brk` | software interrupt; opcode `$00`, so running into empty memory traps |

### Memory map

| | |
|---|---|
| `$0000-$00FF` | zero page: RAM, a good place for pointers |
| `$0100-$01FF` | stack |
| `$0200-$1FFF` | RAM |
| `$2000-$2FFF` | video RAM |
| `$3000-$30FF` | I/O registers |
| `$8000-$BFFF` | cartridge ROM: the program bank chosen with PRGBANK |
| `$C000-$FFFF` | cartridge ROM: always the last bank; writes are ignored |

Vectors: `$FFFA` vblank, `$FFFC` reset, `$FFFE` brk. An interrupt pushes PC
(high, then low) and the flags, sets I and jumps through its vector. The CPU
starts with interrupts off.

## Video

160x120 pixels, 16 fixed colors, 8x8 tiles from the cartridge's tile ROM.

| | |
|---|---|
| `$2000-$23FF` | background map: a tile index per cell, 32 columns x 32 rows (256x256 pixels) |
| `$2400-$247F` | 32 sprites, 4 bytes each: y, x, tile, attributes (bit 0 flip horizontally, bit 1 flip vertically) |

The screen (20 x 15 tiles) is a window into the map at (SCROLLX, SCROLLY),
wrapping around its edges, so a game scrolls by changing two registers and
fills in the columns or rows about to appear. The top FIXROWS rows of the
screen don't scroll: they show map rows 0.. as they are, for a status bar.
Sprites are placed on the screen, not on the map.

Color 0 of a tile is transparent. The background color shows through the
background, the background through sprites, and sprite 0 is on top. A sprite
with y >= 120 is hidden; x and y from 248 up count as -8..-1, so sprites can
slide in from the edges. The picture is drawn at the end of each frame from
what video RAM holds then.

## Sound

Two pulse channels, a triangle and a noise channel, mixed at 44.1 kHz.
Four registers per channel at `$3030 + 4 * channel` (0, 1 pulse, 2 triangle,
3 noise):

| | | |
|---|---|---|
| +0 | PERIOD | low 8 bits of the period; noise: bits 0-3 pick one of 16 rates |
| +1 | PERIODHI | bits 0-2 of the period; **writing it starts the note** |
| +2 | VOLUME | bits 0-3 volume; bits 4-5 pulse duty (12.5, 25, 50, 75%); bit 4 makes noise short and metallic |
| +3 | SHAPE | bits 0-5 length in frames (0: until changed); bits 6-7 decay: none, or one volume step every 1, 2, 4 frames |

`$3040` SOUND: write the channels that are on (`$0F` after reset), read the
ones sounding. A tone is `CLOCK / (16 * (period + 1))` Hz on all tonal
channels: 253 is A4, 213 C5, 106 C6. Writes take effect at the sample that
matches their CPU cycle, not only at frame boundaries.

## I/O registers

| | | |
|---|---|---|
| `$3000` | VCTRL | bit 0 background on, bit 1 sprites on, bit 7 vblank interrupt; `$03` after reset |
| `$3001` | BGCOLOR | the color behind everything |
| `$3002`, `$3003` | SCROLLX, SCROLLY | the background's offset in pixels |
| `$3004` | FIXROWS | top rows of the screen that don't scroll (0-15) |
| `$3008` | PRGBANK | program bank at `$8000-$BFFF` (0 after reset) |
| `$3009` | CHRBANK | tile set the video chip uses (0 after reset) |
| `$3010`, `$3011` | PAD1, PAD2 | buttons held: bit 0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 select, 7 start |
| `$3020`, `$3021` | FRAME, FRAMEHI | frames since reset |
| `$3022` | RANDOM | a new pseudo-random byte on every read |
| `$3030-$3040` | sound | see above |
| `$30FF` | DEBUG | write a character to the debug log |

Each frame: the vblank wakes a CPU stopped by `wait` (and interrupts it when
VCTRL bit 7 is set and I is clear), the CPU gets its 29,829 cycles, then the
picture is drawn. A game that waits each frame costs the host only the
cycles it really uses.

## Playing

`NConsoleScreen` is a `Control` that runs a cartridge (`cartridge_path`,
`.nc8` or `.asm`) at 60 frames a second. Keys: arrows or WASD, Z/J = A,
X/K = B, Enter = start, Shift = select; F3 shows CPU load and the emulator's
time per frame, F5 resets, F2 opens the debugger.

## Debugger

F2 shows registers and the code at PC next to the picture, with a command
line below (`NCMonitor`, a machine-code monitor). F7 steps, F8 steps over a
call, F9 continues or pauses. A breakpoint or watched write stops the
console in the middle of a frame and opens the debugger.

| | |
|---|---|
| `r` | registers |
| `s [n]` / `n` | step n instructions / step over a call |
| `c` / `p` / `f` | continue / pause / run to the end of the frame |
| `b [addr]`, `bd addr\|*` | breakpoints: set or list, delete |
| `w [addr]`, `wd addr\|*` | stop on writes to an address |
| `d [addr] [n]` | disassemble, with labels for addresses |
| `m [addr] [n]` | memory dump |
| `e addr bytes...` | write memory (hex bytes, or `#decimal`) |
| `g addr` | set PC |
| `t on\|off`, `t [n]` | trace of the last executed instructions |
| `reset` | power cycle |

Numbers are hex; addresses can be labels, or `label+offset` (`m score`,
`b place_food`, `d main@play`). Without a breakpoint, watch or trace the
CPU runs its fast loop, so debugging costs nothing until it's used.

## Games

`games/snake.asm`: Snake. The field is the background map, the snake a ring
buffer of cells, collisions are read back from video RAM. It has a start
jingle and a game-over tune (a small note player on pulse 1), a blip for
food and a noise crash. Open
`demo/demo.tscn` and run it (F6) to play.

`games/hopper.asm`: Gem Hopper, a side-scrolling platform game in two
levels. The levels are ASCII art (the character is the tile) in program
banks 1 and 2; the code is in the fixed bank. The camera only moves forward
and copies each level column into the 32-column map just before it scrolls
in; collisions read the map. Beetles walk, turn at walls and edges, and can
be stomped; the hero's vertical speed is 8.8 fixed point, with a lower jump
when A is let go and a run on B. A two-voice note player plays the melody on
pulse 1 and the bass on the triangle. `demo/hopper.tscn` plays it; a frame of
play takes about 3,300 of the 29,829 cycles. A frame of play uses a few hundred
cycles of the 29,829; 60 frames emulate in about 3 ms.

## The assembler

```asm
SPEED = 8                 ; a constant
.section ram
score:  .res 2            ; variables get RAM addresses
.section rom
reset:  ld a, #<message   ; < low byte, > high byte
@loop:  st a, $2000,x     ; @name is local to the last plain label
        jnz @loop
message: .byte "HELLO", 0
.org $fffa
        .word vblank, reset, reset
```

- Numbers: `42`, `$2a`, `%101010`, `'c'`. Operators: `+ - * / % & | ^ << >> ~`
  and parentheses.
- `.section rom|ram|chr`, `.org`, `.byte`, `.word`, `.res count[, fill]`,
  `.title "Name"`, `.include "file"`.
- `.tile [index]` in the chr section: the next 8 lines are rows of 8 pixels,
  hex digits `0`-`f` (`.` is 0). A label before it gets the tile index.
- `.prgbanks n` (2-32, before any code), `.bank n`: code at `$8000-$BFFF`
  goes to bank n, code at `$C000-$FFFF` to the last bank.
- `.chrbanks n` (1-16), `.chrbank n`: tiles that follow go to set n.

## Cartridges

Program ROM comes in 16 KB banks (2 to 32, so up to 512 KB) and tile ROM
in sets of 256 tiles of 8x8 pixels, 4 bits each (1 to 16 sets), which only
the video chip sees. The CPU sees one switchable bank at `$8000` and the
last bank at `$C000`, where the vectors and the code that switches banks
belong. A switch costs microseconds, so games may do it often.

`.nc8` files: a 32-byte header (`NC8` `$1A`, version 2, program banks, tile
banks, a reserved byte, a 24-byte title), the program ROM, then the tile
ROM. Version 1 files (32 KB + 8 KB) still load.
`NCCartridge.load_file` also takes an `.asm` source and assembles it.
