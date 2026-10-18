class_name NCAudio
extends RefCounted
## The sound chip: two pulse channels, a triangle and a noise channel.
##
## Registers ($30xx), four per channel at $30 + 4 * channel (0 and 1
## pulse, 2 triangle, 3 noise):
##   +0 PERIOD     low 8 bits of the period; for noise, bits 0-3 pick
##                 one of 16 rates (0 is the highest)
##   +1 PERIODHI   bits 0-2: high bits of the period. Writing it starts
##                 the note: the length and the volume start again.
##   +2 VOLUME     bits 0-3 volume; bits 4-5 duty for pulse (12.5, 25,
##                 50, 75%); bit 4 for noise makes it short and metallic
##   +3 SHAPE      bits 0-5 length in frames (0: until changed); bits 6-7
##                 decay: 0 none, then the volume drops one step every
##                 1, 2 or 4 frames
##   $40 SOUND     write: channels on (bit per channel, $0f after reset);
##                 read: which channels are sounding
##
## A tone's frequency is CLOCK / (16 * (period + 1)) on all three tonal
## channels, so the same period gives the same note: 253 is A4 (440 Hz).
## Writes take effect at the sample matching the CPU cycle they happen
## on, so sound isn't limited to the frame rate.

const CHANNELS := 4
const NOISE := 3
const TRIANGLE := 2
## CPU cycles per noise generator step, for each rate.
const NOISE_PERIODS: PackedInt32Array = [4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048]
const DUTY: PackedFloat32Array = [0.125, 0.25, 0.5, 0.75]
## Frames between volume steps for each decay setting.
const DECAY_FRAMES: PackedByteArray = [0, 1, 2, 4]
## Loudest output, all channels at full volume.
const MASTER := 0.5


class Channel:
	var period := 0
	var volume := 0
	var level := 0
	var duty := 2
	var short := false
	var shape := 0
	var length := 0
	var decay_count := 0
	var playing := false
	var phase := 0.0


var clock_hz := 1789773
var sample_rate := 44100
var enabled := 0x0F
var _ch: Array[Channel] = []
## [sample, register, value] waiting for the next mix.
var _events: Array = []
var _lfsr := 1


func _init() -> void:
	for k in CHANNELS:
		_ch.append(Channel.new())


func reset() -> void:
	for k in CHANNELS:
		_ch[k] = Channel.new()
	enabled = 0x0F
	_events.clear()
	_lfsr = 1


## Bits for the channels that are sounding (a note on, volume above 0).
func status() -> int:
	var bits := 0
	for k in CHANNELS:
		if _ch[k].playing and _ch[k].level > 0:
			bits |= 1 << k
	return bits


## Queues a register write ([param reg] counted from $3030) to happen
## at [param sample] of the next [method mix].
func write(reg: int, value: int, sample: int) -> void:
	_events.append([sample, reg, value])


## The next [param count] stereo samples, then one frame's worth of
## length and decay.
func mix(count: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(count)
	var e := 0
	var s := 0
	while s < count:
		while e < _events.size() and _events[e][0] <= s:
			_apply(_events[e][1], _events[e][2])
			e += 1
		var until := count if e >= _events.size() else clampi(_events[e][0], s + 1, count)
		_render(out, s, until)
		s = until
	while e < _events.size():
		_apply(_events[e][1], _events[e][2])
		e += 1
	_events.clear()
	_frame()
	return out


func _apply(reg: int, value: int) -> void:
	if reg == 0x10:
		enabled = value & 0x0F
		return
	if reg > 0x0F:
		return
	var c := _ch[reg >> 2]
	match reg & 3:
		0:
			c.period = (c.period & 0x700) | value
		1:
			c.period = (c.period & 0xFF) | ((value & 7) << 8)
			c.playing = true
			c.level = c.volume
			c.length = c.shape & 63
			c.decay_count = 0
		2:
			c.volume = value & 15
			c.level = c.volume
			c.duty = (value >> 4) & 3
			c.short = value & 0x10 != 0
		3:
			c.shape = value


func _render(out: PackedVector2Array, from: int, to: int) -> void:
	for k in CHANNELS:
		var c := _ch[k]
		if not c.playing or c.level == 0 or enabled & (1 << k) == 0:
			continue
		var amp := c.level / 15.0 * MASTER / CHANNELS
		if k == NOISE:
			var steps := float(clock_hz) / NOISE_PERIODS[c.period & 15] / sample_rate
			var tap := 6 if c.short else 1
			for s in range(from, to):
				c.phase += steps
				while c.phase >= 1.0:
					c.phase -= 1.0
					var fb := (_lfsr ^ (_lfsr >> tap)) & 1
					_lfsr = (_lfsr >> 1) | (fb << 14)
				var v := amp if _lfsr & 1 else -amp
				out[s] += Vector2(v, v)
			continue
		if c.period < 8:
			continue # above hearing: silent, as on real chips
		var inc := float(clock_hz) / (16.0 * (c.period + 1)) / sample_rate
		if k == TRIANGLE:
			for s in range(from, to):
				c.phase = fmod(c.phase + inc, 1.0)
				var v := amp * (1.0 - 4.0 * absf(c.phase - 0.5))
				out[s] += Vector2(v, v)
		else:
			var duty := DUTY[c.duty]
			for s in range(from, to):
				c.phase = fmod(c.phase + inc, 1.0)
				var v := amp if c.phase < duty else -amp
				out[s] += Vector2(v, v)


## Length counters and decay, once a frame.
func _frame() -> void:
	for c in _ch:
		if not c.playing:
			continue
		if c.length > 0:
			c.length -= 1
			if c.length == 0:
				c.playing = false
				continue
		var decay := c.shape >> 6
		if decay > 0 and c.level > 0:
			c.decay_count += 1
			if c.decay_count >= DECAY_FRAMES[decay]:
				c.decay_count = 0
				c.level -= 1
				if c.level == 0:
					c.playing = false
