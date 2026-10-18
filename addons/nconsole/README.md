# NConsole

A small 8-bit game console that runs inside Godot: its own processor (N8),
memory, cartridges, video and controller, and an assembler to write games
for it. It is independent of AgoraOS. This first version is written in
GDScript to settle the design; a C++ (GDExtension) core can replace the CPU
later without changing cartridges.

Tests: `godot --headless --path . -s addons/nconsole/tests/run_tests.gd`
(`BENCH=1` also prints how fast the CPU runs).

## The N8 processor

8-bit data, 16-bit addresses (64 KB). Clocked at 1 MHz: about 16,600 cycles
per frame at 60 frames a second.

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
| `$8000-$FFFF` | cartridge ROM; writes are ignored |

Vectors: `$FFFA` vblank, `$FFFC` reset, `$FFFE` brk. An interrupt pushes PC
(high, then low) and the flags, sets I and jumps through its vector. The CPU
starts with interrupts off.

## Video

160x120 pixels, 16 fixed colors, 8x8 tiles from the cartridge's tile ROM.

| | |
|---|---|
| `$2000-$212B` | background: a tile index per cell, 20 columns x 15 rows |
| `$2200-$227F` | 32 sprites, 4 bytes each: y, x, tile, attributes (bit 0 flip horizontally, bit 1 flip vertically) |

Color 0 of a tile is transparent. The background color shows through the
background, the background through sprites, and sprite 0 is on top. A sprite
with y >= 120 is hidden; x and y from 248 up count as -8..-1, so sprites can
slide in from the edges. The picture is drawn at the end of each frame from
what video RAM holds then.

## I/O registers

| | | |
|---|---|---|
| `$3000` | VCTRL | bit 0 background on, bit 1 sprites on, bit 7 vblank interrupt; `$03` after reset |
| `$3001` | BGCOLOR | the color behind everything |
| `$3010`, `$3011` | PAD1, PAD2 | buttons held: bit 0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 select, 7 start |
| `$3020`, `$3021` | FRAME, FRAMEHI | frames since reset |
| `$3022` | RANDOM | a new pseudo-random byte on every read |
| `$30FF` | DEBUG | write a character to the debug log |

Each frame: the vblank wakes a CPU stopped by `wait` (and interrupts it when
VCTRL bit 7 is set and I is clear), the CPU gets its 16,666 cycles, then the
picture is drawn. A game that waits each frame costs the host only the
cycles it really uses.

## Playing

`NConsoleScreen` is a `TextureRect` that runs a cartridge
(`cartridge_path`, `.nc8` or `.asm`) at 60 frames a second. Keys: arrows or
WASD, Z/J = A, X/K = B, Enter = start, Shift = select; F3 shows CPU load and
the emulator's time per frame, F5 resets.

## Games

`games/snake.asm`: Snake. The field is the background map, the snake a ring
buffer of cells, collisions are read back from video RAM. Open
`demo/demo.tscn` and run it (F6) to play. A frame of play uses a few hundred
cycles of the 16,666; 60 frames emulate in about 3 ms.

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

## Cartridges

`.nc8` files: a 32-byte header (`NC8` `$1A`, version 1, flags, a 24-byte
title), 32 KB of program ROM (seen at `$8000`) and 8 KB of tile ROM
(256 tiles of 8x8 pixels, 4 bits each), which only the video chip sees.
`NCCartridge.load_file` also takes an `.asm` source and assembles it.
