extends SceneTree
## NConsole tests. Run with:
##   godot --headless --path . -s addons/nconsole/tests/run_tests.gd
## BENCH=1 also measures how fast the CPU runs.

var _failures := 0
var _checks := 0
var _current := ""


func _initialize() -> void:
	var tests := ["test_isa", "test_arithmetic", "test_addressing", "test_stack_and_calls",
		"test_interrupts", "test_assembler_errors", "test_tiles_and_cartridge", "test_console", "test_screen", "test_snake", "test_audio", "test_scroll_and_banks", "test_monitor", "test_hopper"]
	var only := OS.get_environment("TEST_ONLY")
	for t: String in tests:
		if only.is_empty() or t in only.split(","):
			_current = t
			await call(t)
	if not OS.get_environment("BENCH").is_empty():
		bench()
	print("\n%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		printerr("FAIL [%s] %s" % [_current, what])


func check_eq(actual: Variant, expected: Variant, what: String) -> void:
	_checks += 1
	if actual != expected:
		_failures += 1
		printerr("FAIL [%s] %s\n  expected: %s\n  actual:   %s" % [_current, what, var_to_str(expected), var_to_str(actual)])


## Assembles [param body] at $8000 with a reset vector, loads it and
## runs until halt. Returns the CPU.
func run_asm(body: String, budget: int = 100000) -> NCCpu:
	var asm := NCAssembler.new()
	var cart := asm.assemble(".org $8000\nreset:\n" + body + "\n.org $fffc\n.word reset\n", "test.asm")
	check(cart != null, "assembles: %s" % "\n".join(asm.errors))
	var cpu := NCCpu.new()
	if cart == null:
		return cpu
	for k in NCCartridge.PRG_SIZE:
		cpu.mem[0x8000 + k] = cart.prg[k]
	cpu.reset()
	cpu.run(budget)
	return cpu


func errors_of(source: String) -> PackedStringArray:
	var asm := NCAssembler.new()
	asm.assemble(source, "t.asm")
	return asm.errors


# --- tests --------------------------------------------------------------------

func test_isa() -> void:
	check(NCIsa.TABLE.size() <= 256, "fits in a byte: %d opcodes" % NCIsa.TABLE.size())
	check_eq(NCIsa.opcode("brk", "", NCIsa.Mode.IMP), 0, "$00 is brk")
	var seen := {}
	for e: Array in NCIsa.TABLE:
		var key := "%s %s %d" % e
		check(not seen.has(key), "unique: " + key)
		seen[key] = true
	var mem := PackedByteArray()
	mem.resize(0x10000)
	mem[0] = NCIsa.opcode("ld", "a", NCIsa.Mode.IND)
	mem[1] = 0x10
	mem[2] = 0x00
	check_eq(NCIsa.disassemble(mem, 0), ["ld a, [$0010],y", 3], "disassembly")
	mem[3] = NCIsa.opcode("jnz", "", NCIsa.Mode.REL)
	mem[4] = 0xFB
	check_eq(NCIsa.disassemble(mem, 3), ["jnz $0000", 2], "relative target")


func test_arithmetic() -> void:
	var cpu := run_asm("ld a, #$f0\nadd #$20\nst a, $10\nld a, #0\nadc #0\nst a, $11\nhalt")
	check_eq([cpu.mem[0x10], cpu.mem[0x11]], [0x10, 1], "carry out of add, into adc")
	cpu = run_asm("ld a, #5\nsub #7\nhalt")
	check_eq([cpu.a, cpu.fc, cpu.fn, cpu.fz], [0xFE, true, true, false], "borrow sets carry")
	cpu = run_asm("ld a, #$7f\nadd #1\nhalt")
	check(cpu.fv and cpu.fn, "signed overflow")
	# A 16-bit add: $01ff + $0001.
	cpu = run_asm("ld a, #$ff\nadd #1\nst a, $20\nld a, #$01\nadc #0\nst a, $21\nhalt")
	check_eq(cpu.word(0x20), 0x0200, "16-bit add with carry")
	cpu = run_asm("ld a, #9\ncmp #10\njc @below\nld x, #1\nhalt\n@below: ld x, #2\nhalt")
	check_eq(cpu.x, 2, "cmp then jc: below")
	cpu = run_asm("ld a, #%1000_0001\nhalt".replace("_", ""))
	check_eq(cpu.a, 0x81, "binary literal")
	cpu = run_asm("ld a, #%10000001\nshl a\nst a, $10\nrol $10\nld x, $10\nshr a\nror a\nhalt")
	check_eq([cpu.x, cpu.a, cpu.fc], [0x05, 0x00, true], "shifts and rotates through carry")
	cpu = run_asm("ld a, #$0f\nand #$3c\nor #$40\nxor #$ff\nhalt")
	check_eq(cpu.a, ~((0x0f & 0x3c) | 0x40) & 0xFF, "logic")
	cpu = run_asm("ld a, #10 % 4 + 3 * 2\nld x, #<$1234\nld y, #>$1234\nhalt")
	check_eq([cpu.a, cpu.x, cpu.y], [8, 0x34, 0x12], "expressions, low and high byte")


func test_addressing() -> void:
	# Sum a table with an index, copy it through a pointer.
	var cpu := run_asm("""
	ld x, #0
	ld a, #0
@sum:
	clc
	adc table,x
	inc x
	cmp x, #4
	jnz @sum
	st a, $40
	ld a, #<$0300
	st a, $10
	ld a, #>$0300
	st a, $11
	ld y, #3
@copy:
	ld a, table,y
	st a, [$10],y
	dec y
	jnn @copy
	jmp [vector]
	halt
done:
	ld a, #$99
	halt
table: .byte 1, 2, 3, 4
vector: .word done
""")
	check_eq(cpu.mem[0x40], 10, "indexed sum")
	check_eq(Array(cpu.mem.slice(0x300, 0x304)), [1, 2, 3, 4], "indirect store")
	check_eq(cpu.a, 0x99, "jump through a pointer")
	cpu = run_asm("ld a, #1\nst a, $8000\nld a, $8000\nhalt")
	check(cpu.a != 1, "ROM can't be written")


func test_stack_and_calls() -> void:
	var cpu := run_asm("""
	ld a, #3
	call double
	call double
	push a
	ld a, #0
	pop x
	mov y, a
	halt
double:
	push a
	pop a
	shl a
	ret
""")
	check_eq([cpu.x, cpu.y, cpu.sp], [12, 0, 0xFF], "call, ret, push, pop")
	cpu = run_asm("sec\npush f\nclc\npop f\nhalt")
	check(cpu.fc, "flags saved on the stack")
	cpu = run_asm("ld x, #$80\nmov sp, x\npush a\nmov x, sp\nhalt")
	check_eq(cpu.x, 0x7f, "stack pointer moves")


func test_interrupts() -> void:
	var src := """
	ld a, #0
	st a, $10
	cli
@loop:
	wait
	ld a, $10
	cmp #3
	jnz @loop
	halt
vblank:
	inc $10
	reti
handler:
	ld a, #$42
	halt
.org $fffa
.word vblank
"""
	var asm := NCAssembler.new()
	var cart := asm.assemble(".org $8000\nreset:\n" + src + ".word reset, handler\n", "t.asm")
	check(cart != null, "assembles: %s" % "\n".join(asm.errors))
	var cpu := NCCpu.new()
	for k in NCCartridge.PRG_SIZE:
		cpu.mem[0x8000 + k] = cart.prg[k]
	cpu.reset()
	var frames := 0
	while not cpu.halted and frames < 10:
		cpu.run(1000)
		check(cpu.waiting or cpu.halted, "wait ends the frame early")
		cpu.vblank(true)
		frames += 1
	check_eq([cpu.mem[0x10], frames], [3, 4], "three vblanks counted, then halt")
	# brk goes through $fffe.
	cpu.halted = false
	cpu.pc = 0x8000
	cpu.mem[0x0200] = 0
	cpu.pc = 0x0200
	cpu.run(100)
	check_eq(cpu.a, 0x42, "brk handler")


func test_assembler_errors() -> void:
	check_eq(errors_of("foo a"), PackedStringArray(["t.asm:1: unknown instruction 'foo'"]), "unknown instruction")
	check_eq(errors_of("ld x, $10,x"), PackedStringArray(["t.asm:1: 'ld x' has no abx form"]), "bad mode")
	check_eq(errors_of("ld a, #300"), PackedStringArray(["t.asm:1: value 300 doesn't fit in a byte"]), "byte range")
	check_eq(errors_of("ld a, nowhere"), PackedStringArray(["t.asm:1: unknown symbol 'nowhere'"]), "unknown symbol")
	check_eq(errors_of("x: nop"), PackedStringArray(["t.asm:1: 'x' is a register, not a label"]), "register as label")
	check_eq(errors_of("a1: nop\na1: nop"), PackedStringArray(["t.asm:2: 'a1' is defined twice"]), "duplicate label")
	var far := "start: nop\n.res 200, $01\njnz start"
	check(errors_of(far).size() == 1 and errors_of(far)[0].contains("use jmp"), "branch range: %s" % errors_of(far))
	check_eq(errors_of(".org $8000\nnop\n.org $8000\nnop"), PackedStringArray(["t.asm:4: code overlaps at $8000"]), "overlap")
	check_eq(errors_of(".org $10\nnop"), PackedStringArray(["t.asm:2: address $0010 is outside ROM ($8000-$ffff)"]), "outside ROM")
	# Local labels belong to the label before them.
	var asm := NCAssembler.new()
	var cart := asm.assemble("one:\n@x: nop\ntwo:\n@x: nop\n jr @x", "t.asm")
	check(cart != null and cart.symbols["one@x"] == 0x8000 and cart.symbols["two@x"] == 0x8001, "local labels: %s" % asm.errors)


func test_tiles_and_cartridge() -> void:
	var asm := NCAssembler.new()
	var cart := asm.assemble("""
.title "Demo"
.section ram
score: .res 2
lives: .res 1
.section chr
.tile 'A'
..1111..
.1....1.
1......1
11111111
1......1
1......1
1......1
f......f
block: .tile
ffffffff
ffffffff
ffffffff
ffffffff
ffffffff
ffffffff
ffffffff
ffffffff
.section rom
reset: ld a, #block
""", "t.asm")
	check(cart != null, "assembles: %s" % asm.errors)
	if cart == null:
		return
	check_eq([cart.symbols.score, cart.symbols.lives, cart.symbols.block], [0x200, 0x202, 66], "ram and tile labels")
	check_eq(Array(cart.chr.slice(65 * 32, 65 * 32 + 4)), [0x00, 0x11, 0x11, 0x00], "first row of A")
	check_eq(cart.chr[65 * 32 + 31], 0x0F, "last pixel")
	check_eq(cart.prg[1], 66, "tile index as a value")
	var copy := NCCartridge.from_bytes(cart.to_bytes())
	check(copy != null and copy.title == "Demo" and copy.prg == cart.prg and copy.chr == cart.chr, "cartridge image round trip")
	check(NCCartridge.from_bytes(PackedByteArray([1, 2, 3])) == null, "not a cartridge")


const VIDEO_TEST := """
.title "Video test"
.section chr
.tile 1
44444444
44444444
44444444
44444444
44444444
44444444
44444444
44444444
.tile 2
6.......
66......
666.....
6666....
66666...
666666..
6666666.
66666666
.section ram
pad: .res 1
rnd: .res 2
ticks: .res 1
.section rom
reset:
	ld a, #9
	st a, $3001
	ld a, #1
	st a, $2000 + 1 * 32 + 2
	ld a, #40
	st a, $2400
	ld a, #50
	st a, $2401
	ld a, #2
	st a, $2402
	ld a, #1
	st a, $2403
	ld a, $3022
	st a, rnd
	ld a, $3022
	st a, rnd + 1
	ld a, #'H'
	st a, $30ff
	ld a, #'I'
	st a, $30ff
	ld a, #$83
	st a, $3000
	cli
@loop:
	wait
	ld a, $3010
	st a, pad
	jr @loop
vblank:
	inc ticks
	reti
.org $fffa
.word vblank, reset, reset
"""


func test_console() -> void:
	var asm := NCAssembler.new()
	var cart := asm.assemble(VIDEO_TEST, "video.asm")
	check(cart != null, "assembles: %s" % asm.errors)
	if cart == null:
		return
	var c := NConsole.new()
	c.insert(cart)
	c.run_frame()
	c.pads[0] = NConsole.BTN_START | NConsole.BTN_LEFT
	c.run_frame()
	c.run_frame()
	var img := c.video.image
	check_eq(img.get_size(), Vector2i(160, 120), "160x120")
	check_eq(img.get_pixel(0, 0), NCVideo.PALETTE[9], "background color")
	check_eq(img.get_pixel(16, 8), NCVideo.PALETTE[4], "background tile at column 2, row 1")
	check_eq(img.get_pixel(23, 15), NCVideo.PALETTE[4], "whole tile")
	check_eq(img.get_pixel(57, 40), NCVideo.PALETTE[6], "sprite flipped: its corner pixel is on the right")
	check_eq(img.get_pixel(50, 40), NCVideo.PALETTE[9], "transparent sprite pixel")
	check_eq(c.cpu.mem[cart.symbols.pad], NConsole.BTN_START | NConsole.BTN_LEFT, "controller read")
	check(c.cpu.mem[cart.symbols.rnd] != c.cpu.mem[cart.symbols.rnd + 1], "random bytes")
	check_eq(c.debug_log, "HI", "debug output")
	check_eq(c.cpu.mem[cart.symbols.ticks], 2, "vblank interrupts once enabled")
	check(c.last_cycles < 100, "a waiting CPU sleeps: %d cycles" % c.last_cycles)
	check_eq(c.frame, 3, "frame counter")
	c.reset()
	check_eq(c.cpu.mem[cart.symbols.ticks], 0, "reset clears RAM")


func test_screen() -> void:
	var path := "user://nconsole_test.asm"
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(VIDEO_TEST)
	f.close()
	var screen := NConsoleScreen.new()
	screen.cartridge_path = path
	root.add_child(screen)
	for k in 10:
		await process_frame
	check(screen.console.cartridge != null and screen.console.cartridge.title == "Video test", "cartridge loaded from source")
	check(screen.console.frame > 0, "frames run")
	check_eq(screen.texture.get_size(), Vector2(160, 120), "texture")
	# A breakpoint opens the debugger and stops the frames.
	screen.monitor.command("b reset")
	screen.console.reset()
	for k in 5:
		await process_frame
	check(screen.console.paused and screen.debugger.visible, "a breakpoint opens the debugger")
	var frame := screen.console.frame
	for k in 5:
		await process_frame
	check_eq(screen.console.frame, frame, "paused")
	screen.debugger.run("bd *")
	screen.debugger.run("c")
	for k in 5:
		await process_frame
	check(not screen.console.paused and screen.console.frame > frame, "continued")
	screen.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_snake() -> void:
	var cart := NCCartridge.load_file("res://addons/nconsole/games/snake.asm")
	check(cart != null and cart.title == "Snake", "the game assembles")
	if cart == null:
		return
	var c := NConsole.new()
	c.insert(cart)
	var sym := cart.symbols
	var mem := c.cpu.mem
	var cell := func(col: int, row: int) -> int: return mem[0x2000 + row * 32 + col]
	var text := func(col: int, row: int, n: int) -> String:
		var out := ""
		for k in n:
			var t: int = mem[0x2000 + row * 32 + col + k]
			out += " " if t == 0 else char(t) # tile 0 is the empty cell
		return out
	var worst := [0]
	var frames := func(n: int) -> void:
		for k in n:
			c.run_frame()
			worst[0] = maxi(worst[0], c.last_cycles)
	frames.call(3)
	check_eq([mem[sym.state], text.call(7, 5, 5), text.call(4, 10, 11)], [0, "SNAKE", "PRESS START"], "title screen")
	c.pads[0] = NConsole.BTN_START
	frames.call(1)
	c.pads[0] = 0
	frames.call(1)
	check_eq(mem[sym.state], 1, "start begins a game")
	check_eq([cell.call(5, 7), cell.call(6, 7), cell.call(7, 7)], [2, 2, 3], "snake drawn")
	check_eq([cell.call(0, 1), cell.call(19, 14), cell.call(0, 8)], [1, 1, 1], "walls")
	check_eq(text.call(1, 0, 9), "SCORE 000", "score shown")
	check(c.audio.status() & 2 == 2, "the start tune plays on pulse 1")
	# Put food in front of the snake (move the random one away first).
	for k in 1024:
		if mem[0x2000 + k] == 4:
			mem[0x2000 + k] = 0
	mem[0x2000 + 7 * 32 + 9] = 4
	frames.call(8 * 2)
	check_eq(mem[sym.body_x + mem[sym.head]], 9, "the head moved two cells")
	check_eq(text.call(1, 0, 9), "SCORE 001", "food eaten")
	check(c.audio.status() & 1 == 1, "eating makes a sound")
	frames.call(8)
	check_eq((mem[sym.head] - mem[sym.tail]) & 255, 3, "grown to four cells")
	var food := 0
	for k in 1024:
		if mem[0x2000 + k] == 4:
			food += 1
	check_eq(food, 1, "new food placed")
	# Turn up, then right again into the wall.
	c.pads[0] = NConsole.BTN_UP
	frames.call(8)
	c.pads[0] = NConsole.BTN_RIGHT
	frames.call(8)
	c.pads[0] = 0
	check_eq([mem[sym.body_x + mem[sym.head]], mem[sym.body_y + mem[sym.head]]], [11, 6], "steered")
	frames.call(8 * 10)
	check_eq([mem[sym.state], text.call(5, 8, 9)], [2, "GAME OVER"], "hit the wall")
	frames.call(1)
	check(c.audio.status() & 0b1010 == 0b1010, "crash and tune: %x" % c.audio.status())
	frames.call(60)
	check_eq(c.audio.status() & 0b1010, 0, "both end")
	check(worst[0] < NConsole.CYCLES_PER_FRAME / 2, "the game needs a fraction of the CPU: at most %d of %d cycles" % [worst[0], NConsole.CYCLES_PER_FRAME])
	var t := Time.get_ticks_usec()
	frames.call(60)
	print("snake: worst frame %d cycles; 60 frames emulated in %.1f ms" % [worst[0], (Time.get_ticks_usec() - t) / 1000.0])


## Rising zero crossings in [param samples], left channel.
func crossings(samples: PackedVector2Array) -> int:
	var n := 0
	for k in range(1, samples.size()):
		if samples[k - 1].x <= 0.0 and samples[k].x > 0.0:
			n += 1
	return n


func peak(samples: PackedVector2Array) -> float:
	var p := 0.0
	for v in samples:
		p = maxf(p, absf(v.x))
	return p


func test_audio() -> void:
	var asm := NCAssembler.new()
	var cart := asm.assemble("""
reset:
	ld a, #$2f        ; pulse 0: volume 15, duty 50%
	st a, $3032
	ld a, #0          ; held
	st a, $3033
	ld a, #253        ; A4
	st a, $3030
	ld a, #0
	st a, $3031
	ld a, #$0f        ; pulse 1: a 5-frame blip
	st a, $3036
	ld a, #5
	st a, $3037
	ld a, #100
	st a, $3034
	ld a, #0
	st a, $3035
@loop:
	wait
	jr @loop
.org $fffc
.word reset
""", "sound.asm")
	check(cart != null, "assembles: %s" % asm.errors)
	if cart == null:
		return
	var c := NConsole.new()
	c.insert(cart)
	var all := PackedVector2Array()
	for k in 6:
		c.run_frame()
		all.append_array(c.sound)
	check_eq(c.sound.size(), 735, "735 samples a frame")
	check(c.audio.status() & 1 == 1, "pulse 0 still playing")
	check(c.cpu.read(0x3040) & 1 == 1, "status register")
	# The blip on pulse 1 is over; pulse 0 alone is 440 Hz.
	var tone := PackedVector2Array()
	for k in 6:
		c.run_frame()
		tone.append_array(c.sound)
	check_eq(c.audio.status(), 1, "the 5-frame note ended")
	var hz := crossings(tone) / (tone.size() / 44100.0)
	check(absf(hz - 440.0) < 12.0, "period 253 is A4: %.1f Hz" % hz)
	# Unit checks on the chip itself.
	var a := NCAudio.new()
	a.write(2, 0x0F, 0)       # pulse 0 volume 15
	a.write(3, 0x40, 0)       # decay every frame
	a.write(0, 200, 0)
	a.write(1, 0, 300)        # starts at sample 300
	var first := a.mix(735)
	check(peak(first.slice(0, 300)) == 0.0 and peak(first.slice(300)) > 0.0, "a write lands at its sample")
	var loud := peak(first)
	for k in 7:
		a.mix(735)
	check(peak(a.mix(735)) < loud * 0.6, "decay: quieter after 8 frames")
	for k in 10:
		a.mix(735)
	check_eq(a.status(), 0, "decayed to silence")
	var t := NCAudio.new()
	t.write(10, 0x0F, 0)      # triangle
	t.write(8, 120, 0)
	t.write(9, 0, 0)
	var tri := t.mix(735)
	var levels := {}
	for v in tri:
		levels[snappedf(v.x, 0.001)] = true
	check(levels.size() > 20, "the triangle has slopes, not two levels")
	var n := NCAudio.new()
	n.write(14, 0x0F, 0)      # noise
	n.write(12, 3, 0)
	n.write(13, 0, 0)
	var noise := n.mix(735)
	check(crossings(noise) > 50 and peak(noise) > 0.0, "noise")
	n.write(0x10, 0, 0)       # all channels off
	check_eq(peak(n.mix(735)), 0.0, "channel mask")
	var all4 := NCAudio.new()
	for ch in 4:
		all4.write(ch * 4 + 2, 0x2F, 0)
		all4.write(ch * 4, 150, 0)
		all4.write(ch * 4 + 1, 1, 0)
	var t0 := Time.get_ticks_usec()
	for k in 60:
		all4.mix(735)
	print("audio: one second of four channels mixed in %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))


func test_scroll_and_banks() -> void:
	var asm := NCAssembler.new()
	var cart := asm.assemble("""
.title "Banks"
.prgbanks 4
.chrbanks 2
.section chr
.chrbank 0
.tile 1
44444444
44444444
44444444
44444444
44444444
44444444
44444444
44444444
.chrbank 1
.tile 1
77777777
77777777
77777777
77777777
77777777
77777777
77777777
77777777
.section rom
.bank 1
in_one: .byte $11
.bank 2
in_two: .byte $22
.org $c000
reset:
	ld a, #1
	st a, $2000 + 20 * 32 + 3   ; map row 20, column 3
	st a, $2000                 ; row 0, column 0: the status bar
	st a, $3008
	ld a, $8000
	st a, $10
	ld a, #2
	st a, $3008
	ld a, in_two
	st a, $11
	ld a, #0
	st a, $3008
	ld a, $8000
	st a, $12
	ld a, #20 * 8 - 8           ; map row 20 on screen row 1
	st a, $3003
	ld a, #16                   ; column 3 on screen column 1
	st a, $3002
	ld a, #1
	st a, $3004                 ; the top row stays put
@loop:
	wait
	jr @loop
.org $fffa
.word reset, reset, reset
""", "banks.asm")
	check(cart != null, "assembles: %s" % asm.errors)
	if cart == null:
		return
	check_eq([cart.prg_banks, cart.chr_banks, cart.prg.size()], [4, 2, 0x10000], "sizes")
	check_eq([cart.symbols.in_one, cart.symbols.in_two, cart.label_banks.in_two], [0x8000, 0x8000, 2], "banked labels")
	check_eq(cart.prg[3 * 0x4000], NCIsa.opcode("ld", "a", NCIsa.Mode.IMM), "$c000 is in the last bank")
	var c := NConsole.new()
	c.insert(cart)
	c.run_frame()
	check_eq([c.cpu.mem[0x10], c.cpu.mem[0x11], c.cpu.mem[0x12]], [0x11, 0x22, 0], "the window shows the chosen bank")
	var img := c.video.image
	check_eq(img.get_pixel(8, 8), NCVideo.PALETTE[4], "scrolled: map (3, 20) at screen (1, 1)")
	check_eq(img.get_pixel(8, 16), NCVideo.PALETTE[0], "and nothing below it")
	check_eq(img.get_pixel(0, 0), NCVideo.PALETTE[4], "the fixed row shows map row 0")
	check_eq(img.get_pixel(8, 0), NCVideo.PALETTE[0], "fixed: no scroll")
	c.write_io(NConsole.REG_CHRBANK, 1)
	c.run_frame()
	check_eq(c.video.image.get_pixel(8, 8), NCVideo.PALETTE[7], "the other tile set")
	c.write_io(NConsole.REG_SCROLLX, 17)
	c.run_frame()
	var px := func(x: int) -> Color: return c.video.image.get_pixel(x, 8)
	check_eq([px.call(6), px.call(7), px.call(14), px.call(15)], [NCVideo.PALETTE[0], NCVideo.PALETTE[7], NCVideo.PALETTE[7], NCVideo.PALETTE[0]], "pixel scrolling: the tile is at 7-14")
	var copy := NCCartridge.from_bytes(cart.to_bytes())
	check(copy != null and copy.prg == cart.prg and copy.chr == cart.chr and copy.prg_banks == 4, "banked cartridge round trip")
	var v1 := "NC8\u001a".to_ascii_buffer()
	v1.append_array([1, 0, 0, 0])
	v1.resize(32 + 0x8000 + 0x2000)
	var old := NCCartridge.from_bytes(v1)
	check(old != null and old.prg_banks == 2 and old.chr_banks == 1, "version 1 files still load")
	check_eq(errors_of("nop\n.prgbanks 4"), PackedStringArray(["t.asm:2: .prgbanks must come before any code"]), "banks after code")
	check_eq(errors_of(".bank 5"), PackedStringArray(["t.asm:1: bank 5 doesn't exist (the cartridge has 2)"]), "no such bank")


## Runs frames until the console pauses (at most [param limit]).
func run_until_paused(c: NConsole, limit: int = 120) -> void:
	for k in limit:
		c.run_frame()
		if c.paused:
			return


func test_monitor() -> void:
	var cart := NCCartridge.load_file("res://addons/nconsole/games/snake.asm")
	var c := NConsole.new()
	c.insert(cart)
	var mon := NCMonitor.new(c)
	var food: int = cart.labels.place_food
	for k in 3:
		c.run_frame()
	check_eq(mon.command("b place_food"), "break at $%04x (place_food)" % food, "breakpoint by label")
	c.pads[0] = NConsole.BTN_START
	run_until_paused(c)
	c.pads[0] = 0
	check(c.paused and c.cpu.pc == food, "stopped at place_food when the game starts")
	check(mon.stop_message().begins_with("break at $%04x (place_food)\n>* %04x  " % [food, food]), "why it stopped: " + mon.stop_message())
	check(mon.command("r").begins_with("PC=%04x A=" % food), "registers")
	var listing := mon.command("d place_food 20")
	check(listing.begins_with("place_food:\n>* %04x  " % food) and listing.contains("ld a, $3022"), "disassembly: " + listing)
	check(listing.contains("call peek"), "calls named by label: " + listing)
	c.run_frame()
	check_eq(c.cpu.pc, food, "paused: frames don't run")
	mon.command("s")
	check_eq(c.cpu.pc, food + 3, "one step")
	# Step over the call to peek.
	var at := food
	while NCIsa.disassemble(c.cpu.mem, at)[0] != "call $%04x" % cart.labels.peek:
		at += NCIsa.disassemble(c.cpu.mem, at)[1]
	mon.command("bd *")
	mon.command("b %x" % at)
	mon.command("c")
	run_until_paused(c)
	check_eq(c.cpu.pc, at, "at the call")
	check_eq(mon.command("n"), "running to $%04x" % (at + 3), "step over")
	run_until_paused(c)
	check(c.cpu.pc == at + 3 and not c.cpu.breakpoints.has(at + 3), "back after the call; the one-shot stop is gone")
	check_eq(mon.command("b"), "$%04x" % at, "list")
	mon.command("bd *")
	# Watch the pad being stored.
	check(mon.command("w pad_prev").begins_with("watch $"), "watch")
	mon.command("c")
	run_until_paused(c)
	check(mon.stop_message().begins_with("write to $%04x (pad_prev) = $00" % cart.symbols.pad_prev), "watched write: " + mon.stop_message())
	mon.command("wd *")
	# Memory.
	check_eq(mon.command("e score 1 2 #9"), "%04x: %-48s %s" % [cart.symbols.score, "01 02 09 ", "..."], "write and show memory")
	check_eq(Array(c.cpu.mem.slice(cart.symbols.score, cart.symbols.score + 3)), [1, 2, 9], "memory written")
	check(mon.command("m 2000 20").begins_with("2000: 00 53 43 4f 52 45 00 "), "dump: the score text")
	# Trace.
	mon.command("t on")
	mon.command("s 5")
	var trace := mon.command("t 3").split("\n")
	check(trace.size() == 3 and trace[2].contains("%04x" % c.cpu.trace[c.cpu.trace.size() - 1]), "trace: %s" % trace)
	mon.command("t off")
	# Stepping through wait goes on into the next frame.
	var frame := c.frame
	for k in 2000:
		mon.command("s")
		if c.frame != frame:
			break
	check(c.frame == frame + 1 and not c.cpu.waiting, "stepped into the next frame")
	check_eq(mon.command("x"), "?command x (help lists them)", "unknown command")
	mon.command("c")
	c.run_frame()
	check(not c.paused, "running again")


func test_hopper() -> void:
	var cart := NCCartridge.load_file("res://addons/nconsole/games/hopper.asm")
	check(cart != null and cart.title == "Gem Hopper" and cart.prg_banks == 4, "Gem Hopper assembles into 4 banks")
	if cart == null:
		return
	var c := NConsole.new()
	c.insert(cart)
	var s: Dictionary = cart.symbols
	var m := func(name: String) -> int: return c.cpu.mem[s[name]]
	var setm := func(name: String, v: int) -> void: c.cpu.mem[s[name]] = v
	var x_of := func() -> int: return c.cpu.mem[s.px_l] | (c.cpu.mem[s.px_h] << 8)
	var worst := [0]
	var frames := func(n: int, pad: int = 0) -> void:
		for k in n:
			c.pads[0] = pad
			c.run_frame()
			worst[0] = maxi(worst[0], c.last_cycles)
	## The hero at world (x, y), standing still.
	var place := func(x: int, y: int) -> void:
		setm.call("px_l", x & 255)
		setm.call("px_h", x >> 8)
		setm.call("py", y)
		for v in ["pyf", "vy_l", "vy_h"]:
			setm.call(v, 0)
	var text := func(col: int, row: int, n: int) -> String:
		var out := ""
		for k in n:
			out += char(c.cpu.mem[0x2000 + row * 32 + col + k])
		return out
	frames.call(3)
	check_eq([m.call("state"), text.call(5, 5, 10)], [0, "GEM HOPPER"], "title screen")
	frames.call(1, NConsole.BTN_START)
	frames.call(2)
	check_eq([m.call("state"), m.call("level"), c.prg_bank, m.call("next_col")], [1, 1, 1, 32], "level 1 from bank 1, the first 32 columns in")
	check_eq(text.call(1, 0, 14), "GEMS 00 LIFE 3", "status bar")
	check_eq(c.fixed_rows, 1, "the status bar doesn't scroll")
	check_eq([c.cpu.mem[0x2000 + 12 * 32], c.cpu.mem[0x2000 + 13 * 32]], ['#'.unicode_at(0), '%'.unicode_at(0)], "ground copied from the level")
	# Walking right scrolls the map and copies columns in; a frame of
	# play needs a fraction of the CPU.
	worst[0] = 0
	frames.call(80, NConsole.BTN_RIGHT)
	check(worst[0] < NConsole.CYCLES_PER_FRAME / 4, "a frame of play: at most %d of %d cycles" % [worst[0], NConsole.CYCLES_PER_FRAME])
	print("hopper: worst frame of play %d cycles" % worst[0])
	var cam: int = m.call("cam_l") | (m.call("cam_h") << 8)
	check(x_of.call() > 90 and cam == x_of.call() - 64 and c.scroll_x == cam & 255, "the camera follows: x %d, camera %d" % [x_of.call(), cam])
	check_eq(m.call("next_col"), (cam >> 3) + 32, "columns copied ahead")
	frames.call(120, NConsole.BTN_LEFT)
	check_eq(x_of.call(), cam, "can't go back past the camera")
	# Gems on the first platform (columns 13-16).
	place.call(100, 64)
	frames.call(40, NConsole.BTN_RIGHT)
	var ones: int = c.cpu.mem[s.gems + 1]
	check_eq(m.call("gems") * 10 + ones, 4, "four gems picked up")
	check_eq(text.call(6, 0, 2), "04", "the status bar counts them")
	# Drop onto the first beetle.
	var bug := -1
	for k in 4:
		if c.cpu.mem[s.est + k] == 1:
			bug = k
			break
	check(bug >= 0, "beetles walk the level")
	if bug >= 0:
		var bx: int = c.cpu.mem[s.ex_l + bug] | (c.cpu.mem[s.ex_h + bug] << 8)
		# a little ahead of it, so it walks under the hero
		place.call(bx - 3 if c.cpu.mem[s.edir + bug] == 1 else bx + 3, 60)
		frames.call(25)
		check_eq(c.cpu.mem[s.est + bug], 2, "stomped from above")
		check_eq(m.call("state"), 1, "and the hero lives")
	# Walk into a beetle from the side.
	frames.call(30)
	bug = -1
	for k in 4:
		if c.cpu.mem[s.est + k] == 1:
			bug = k
			break
	check(bug >= 0, "another beetle")
	if bug >= 0:
		var bx: int = c.cpu.mem[s.ex_l + bug] | (c.cpu.mem[s.ex_h + bug] << 8)
		place.call(bx - 30, 88)
		frames.call(60, NConsole.BTN_RIGHT)
		check_eq(m.call("state"), 2, "a beetle from the side hurts")
		frames.call(110)
		check_eq([m.call("state"), m.call("lives"), x_of.call()], [1, 2, 16], "back to the start with a life less")
	# Spikes at columns 64-65.
	place.call(60 * 8, 88)
	frames.call(60, NConsole.BTN_RIGHT)
	check_eq(m.call("state"), 2, "spikes hurt")
	frames.call(110)
	# A pit at columns 22-23.
	place.call(19 * 8, 88)
	frames.call(60, NConsole.BTN_RIGHT)
	check_eq(m.call("state"), 2, "into a pit")
	frames.call(110)
	check_eq(m.call("state"), 4, "the last life lost in a pit: game over")
	check_eq(text.call(5, 6, 9), "GAME OVER", "game over screen")
	# Through both levels.
	frames.call(1, NConsole.BTN_START)
	frames.call(2)
	place.call(117 * 8, 88)
	frames.call(80, NConsole.BTN_RIGHT)
	check_eq([m.call("state"), text.call(15, 0, 5)], [3, "CLEAR"], "level 1 cleared at the star")
	frames.call(125)
	check_eq([m.call("state"), m.call("level"), c.prg_bank], [1, 2, 2], "level 2 from bank 2")
	check_eq(char(c.cpu.mem[0x2000 + 11 * 32 + 12]), "^", "level 2's own layout: spikes at column 12")
	place.call(117 * 8, 88)
	frames.call(80, NConsole.BTN_RIGHT)
	frames.call(125)
	check_eq([m.call("state"), text.call(6, 5, 7)], [5, "YOU WIN"], "won")


# --- speed ----------------------------------------------------------------------

func bench() -> void:
	var cpu := run_asm("""
@outer:
	ld x, #0
@inner:
	ld a, table,x
	clc
	adc $10
	st a, $10
	inc x
	cmp x, #200
	jnz @inner
	jr @outer
table: .res 256, 3
""", 0)
	var t := Time.get_ticks_usec()
	var before := cpu.cycles
	var instructions := 0
	while Time.get_ticks_usec() - t < 1000000:
		var pc_before := cpu.cycles
		cpu.run(10000)
		instructions += (cpu.cycles - pc_before) / 4 # about 4 cycles each here
	var secs := (Time.get_ticks_usec() - t) / 1000000.0
	print("CPU: %.2f M cycles/s, about %.2f M instructions/s" % [(cpu.cycles - before) / secs / 1e6, instructions / secs / 1e6])
