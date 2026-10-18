class_name NConsole
extends RefCounted
## The console: an N8 at 1.79 MHz (the clock of NTSC consoles of the 80s),
## the video chip, the sound chip, two controllers and a
## cartridge slot. [method run_frame] runs one 60th of a second: the vblank
## (which wakes a waiting CPU and, if enabled, interrupts it), the CPU's
## share of cycles, then the picture is drawn from video RAM.
##
## I/O registers ($30xx):
##   $00 VCTRL   bit 0 background on, bit 1 sprites on, bit 7 vblank
##               interrupt; $03 after reset
##   $01 BGCOLOR color behind everything (0-15)
##   $02 SCROLLX, $03 SCROLLY  the background's offset in pixels
##   $04 FIXROWS the top rows that don't scroll (0-15), for a status bar
##   $08 PRGBANK program bank seen at $8000-$BFFF (0 after reset)
##   $09 CHRBANK tile set the video chip uses (0 after reset)
##   $10 PAD1, $11 PAD2 (read): bit 0 up, 1 down, 2 left, 3 right,
##               4 A, 5 B, 6 select, 7 start
##   $20 FRAME, $21 FRAMEHI (read): frames since reset
##   $22 RANDOM  (read): a new pseudo-random byte on every read
##   $30-$40     sound, see [NCAudio]
##   $FF DEBUG   (write): a character for the debug log

const CLOCK_HZ := 1789773
const FPS := 60
const CYCLES_PER_FRAME := CLOCK_HZ / FPS
const SAMPLE_RATE := 44100
const SAMPLES_PER_FRAME := SAMPLE_RATE / FPS

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
const REG_SCROLLX := 0x02
const REG_SCROLLY := 0x03
const REG_FIXROWS := 0x04
const REG_PRGBANK := 0x08
const REG_CHRBANK := 0x09
const REG_PAD1 := 0x10
const REG_PAD2 := 0x11
const REG_FRAME := 0x20
const REG_FRAMEHI := 0x21
const REG_RANDOM := 0x22
const REG_SOUND := 0x30
const REG_SOUND_END := 0x40
const REG_DEBUG := 0xFF

var cpu := NCCpu.new()
var video := NCVideo.new()
var audio := NCAudio.new()
## The sound of the last frame, SAMPLES_PER_FRAME stereo samples.
var sound := PackedVector2Array()
var cartridge: NCCartridge
## Buttons held on each controller (BTN_* bits); the host sets them.
var pads := PackedByteArray([0, 0])
var frame := 0
var vctrl := 0x03
var bg_color := 0
var scroll_x := 0
var scroll_y := 0
var fixed_rows := 0
var prg_bank := 0
## Cycles the CPU used in the last frame (it sleeps the rest).
var last_cycles := 0
## What the program wrote to DEBUG.
var debug_log := ""
var _rng := 0xACE1
var _frame_start := 0
var _redraw := true


func _init() -> void:
	cpu.io = weakref(self)
	audio.clock_hz = CLOCK_HZ
	audio.sample_rate = SAMPLE_RATE


func insert(cart: NCCartridge) -> void:
	cartridge = cart
	video.load_tiles(cart.chr)
	reset()


## Power cycle: RAM cleared, ROM mapped, CPU through its reset vector.
func reset() -> void:
	cpu.mem.fill(0)
	if cartridge:
		var last := cartridge.bank(cartridge.prg_banks - 1)
		for k in NCCartridge.BANK_SIZE:
			cpu.mem[0xC000 + k] = last[k]
	_map_bank(0)
	video.chr_bank = 0
	frame = 0
	vctrl = 0x03
	bg_color = 0
	scroll_x = 0
	scroll_y = 0
	fixed_rows = 0
	_rng = 0xACE1
	debug_log = ""
	audio.reset()
	cpu.reset()
	_redraw = true


func run_frame() -> void:
	_frame_start = cpu.cycles
	cpu.vblank(vctrl & 0x80 != 0)
	last_cycles = cpu.run(CYCLES_PER_FRAME)
	sound = audio.mix(SAMPLES_PER_FRAME)
	frame = (frame + 1) & 0xFFFF
	_next_random() # the sequence also depends on when the program reads it
	if _redraw or cpu.vram_dirty:
		video.render(cpu.mem, vctrl & 1 != 0, vctrl & 2 != 0, bg_color, scroll_x, scroll_y, fixed_rows)
		cpu.vram_dirty = false
		_redraw = false


## Puts program bank [param n] at $8000-$BFFF.
func _map_bank(n: int) -> void:
	prg_bank = n
	if cartridge == null:
		return
	# Splicing whole arrays is native code: a switch costs microseconds.
	var mem := cpu.mem
	cpu.mem = mem.slice(0, 0x8000) + cartridge.bank(n) + mem.slice(0xC000)


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
		REG_SCROLLX: return scroll_x
		REG_SCROLLY: return scroll_y
		REG_FIXROWS: return fixed_rows
		REG_PRGBANK: return prg_bank
		REG_CHRBANK: return video.chr_bank
		REG_PAD1: return pads[0]
		REG_PAD2: return pads[1]
		REG_SOUND_END: return audio.status()
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
		REG_SCROLLX:
			scroll_x = value
			_redraw = true
		REG_SCROLLY:
			scroll_y = value
			_redraw = true
		REG_FIXROWS:
			fixed_rows = value & 15
			_redraw = true
		REG_PRGBANK:
			if cartridge:
				_map_bank(value % cartridge.prg_banks)
		REG_CHRBANK:
			if cartridge:
				video.chr_bank = value % cartridge.chr_banks
				_redraw = true
		REG_DEBUG:
			debug_log += char(value)
		_:
			if reg >= REG_SOUND and reg <= REG_SOUND_END:
				# At the sample matching the cycle of the write.
				var at := (cpu.cycles - _frame_start) * SAMPLES_PER_FRAME / CYCLES_PER_FRAME
				audio.write(reg - REG_SOUND, value, clampi(at, 0, SAMPLES_PER_FRAME - 1))
