class_name NConsole
extends RefCounted
## The console: an N8 at 1 MHz, the video chip, two controllers and a
## cartridge slot. [method run_frame] runs one 60th of a second: the vblank
## (which wakes a waiting CPU and, if enabled, interrupts it), the CPU's
## share of cycles, then the picture is drawn from video RAM.
##
## I/O registers ($30xx):
##   $00 VCTRL   bit 0 background on, bit 1 sprites on, bit 7 vblank
##               interrupt; $03 after reset
##   $01 BGCOLOR color behind everything (0-15)
##   $10 PAD1, $11 PAD2 (read): bit 0 up, 1 down, 2 left, 3 right,
##               4 A, 5 B, 6 select, 7 start
##   $20 FRAME, $21 FRAMEHI (read): frames since reset
##   $22 RANDOM  (read): a new pseudo-random byte on every read
##   $FF DEBUG   (write): a character for the debug log

const CLOCK_HZ := 1000000
const FPS := 60
const CYCLES_PER_FRAME := CLOCK_HZ / FPS

const BTN_UP := 0x01
const BTN_DOWN := 0x02
const BTN_LEFT := 0x04
const BTN_RIGHT := 0x08
const BTN_A := 0x10
const BTN_B := 0x20
const BTN_SELECT := 0x40
const BTN_START := 0x80

const REG_VCTRL := 0x00
const REG_BGCOLOR := 0x01
const REG_PAD1 := 0x10
const REG_PAD2 := 0x11
const REG_FRAME := 0x20
const REG_FRAMEHI := 0x21
const REG_RANDOM := 0x22
const REG_DEBUG := 0xFF

var cpu := NCCpu.new()
var video := NCVideo.new()
var cartridge: NCCartridge
## Buttons held on each controller (BTN_* bits); the host sets them.
var pads := PackedByteArray([0, 0])
var frame := 0
var vctrl := 0x03
var bg_color := 0
## Cycles the CPU used in the last frame (it sleeps the rest).
var last_cycles := 0
## What the program wrote to DEBUG.
var debug_log := ""
var _rng := 0xACE1
var _redraw := true


func _init() -> void:
	cpu.io = weakref(self)


func insert(cart: NCCartridge) -> void:
	cartridge = cart
	video.load_tiles(cart.chr)
	reset()


## Power cycle: RAM cleared, ROM mapped, CPU through its reset vector.
func reset() -> void:
	cpu.mem.fill(0)
	if cartridge:
		for k in NCCartridge.PRG_SIZE:
			cpu.mem[NCCpu.ROM_START + k] = cartridge.prg[k]
	frame = 0
	vctrl = 0x03
	bg_color = 0
	_rng = 0xACE1
	debug_log = ""
	cpu.reset()
	_redraw = true


func run_frame() -> void:
	cpu.vblank(vctrl & 0x80 != 0)
	last_cycles = cpu.run(CYCLES_PER_FRAME)
	frame = (frame + 1) & 0xFFFF
	_next_random() # the sequence also depends on when the program reads it
	if _redraw or cpu.vram_dirty:
		video.render(cpu.mem, vctrl & 1 != 0, vctrl & 2 != 0, bg_color)
		cpu.vram_dirty = false
		_redraw = false


func _next_random() -> int:
	# 16-bit Galois LFSR.
	var bit := _rng & 1
	_rng >>= 1
	if bit:
		_rng ^= 0xB400
	return _rng & 0xFF


func read_io(reg: int) -> int:
	match reg:
		REG_VCTRL: return vctrl
		REG_BGCOLOR: return bg_color
		REG_PAD1: return pads[0]
		REG_PAD2: return pads[1]
		REG_FRAME: return frame & 0xFF
		REG_FRAMEHI: return frame >> 8
		REG_RANDOM:
			for k in 8:
				_next_random()
			return _rng & 0xFF
	return 0


func write_io(reg: int, value: int) -> void:
	match reg:
		REG_VCTRL:
			if (vctrl ^ value) & 3:
				_redraw = true
			vctrl = value
		REG_BGCOLOR:
			bg_color = value & 15
			_redraw = true
		REG_DEBUG:
			debug_log += char(value)
