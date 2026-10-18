extends SceneTree
## NConsole tests. Run with:
##   godot --headless --path . -s addons/nconsole/tests/run_tests.gd
## BENCH=1 also measures how fast the CPU runs.

var _failures := 0
var _checks := 0
var _current := ""


func _initialize() -> void:
	var tests := ["test_isa", "test_arithmetic", "test_addressing", "test_stack_and_calls",
		"test_interrupts", "test_assembler_errors", "test_tiles_and_cartridge", "test_console", "test_screen", "test_snake"]
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
	st a, $2000 + 1 * 20 + 2
	ld a, #40
	st a, $2200
	ld a, #50
	st a, $2201
	ld a, #2
	st a, $2202
	ld a, #1
	st a, $2203
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
	var cell := func(col: int, row: int) -> int: return mem[0x2000 + row * 20 + col]
	var text := func(col: int, row: int, n: int) -> String:
		var out := ""
		for k in n:
			var t: int = mem[0x2000 + row * 20 + col + k]
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
	# Put food in front of the snake (move the random one away first).
	for k in 300:
		if mem[0x2000 + k] == 4:
			mem[0x2000 + k] = 0
	mem[0x2000 + 7 * 20 + 9] = 4
	frames.call(8 * 2)
	check_eq(mem[sym.body_x + mem[sym.head]], 9, "the head moved two cells")
	check_eq(text.call(1, 0, 9), "SCORE 001", "food eaten")
	frames.call(8)
	check_eq((mem[sym.head] - mem[sym.tail]) & 255, 3, "grown to four cells")
	var food := 0
	for k in 300:
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
	check(worst[0] < NConsole.CYCLES_PER_FRAME / 2, "the game needs a fraction of the CPU: at most %d of %d cycles" % [worst[0], NConsole.CYCLES_PER_FRAME])
	var t := Time.get_ticks_usec()
	frames.call(60)
	print("snake: worst frame %d cycles; 60 frames emulated in %.1f ms" % [worst[0], (Time.get_ticks_usec() - t) / 1000.0])


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
