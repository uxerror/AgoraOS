class_name AgoraRoomSounds
extends RefCounted
## The sounds of the hardware in the 3D view, made here rather than
## recorded: a fan's hum, a disk's spindle and its head seeking, the
## 15.7 kHz whine of a CRT's line transformer and the thump of its degauss
## coil. Each is a short 16-bit buffer, made once and played looping or once.

const RATE := 22050

static var _cache := {}


## The sound [param name]: "fan", "spindle", "seek", "crt", "degauss".
static func stream(name: String) -> AudioStreamWAV:
	if not _cache.has(name):
		_cache[name] = _make(name)
	return _cache[name]


static func _make(name: String) -> AudioStreamWAV:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(name)
	var samples := PackedFloat32Array()
	var loop := true
	# The CRT's whine is above what 22050 Hz can carry.
	var rate := 44100 if name == "crt" else RATE
	match name:
		"fan":
			# Air: noise through two low-pass stages, and the blade tone.
			var n := RATE * 2
			var a := 0.0
			var b := 0.0
			for i in n:
				a += (rng.randf_range(-1.0, 1.0) - a) * 0.08
				b += (a - b) * 0.15
				var blade := sin(TAU * 140.0 * i / RATE) * 0.12
				samples.append(b * 2.2 + blade)
		"spindle":
			# 5400 rpm: 90 Hz and its harmonics, faint.
			for i in RATE:
				var t := float(i) / RATE
				samples.append(sin(TAU * 90.0 * t) * 0.3 + sin(TAU * 180.0 * t) * 0.15 + sin(TAU * 540.0 * t) * 0.05)
		"crt":
			for i in rate:
				samples.append(sin(TAU * 15734.0 * i / rate) * 0.5)
		"seek":
			loop = false
			for i in int(RATE * 0.03):
				var env := exp(-float(i) / (RATE * 0.004))
				samples.append((rng.randf_range(-1.0, 1.0) * 0.6 + sin(TAU * 1800.0 * i / RATE) * 0.4) * env)
		"degauss":
			loop = false
			for i in int(RATE * 1.2):
				var t := float(i) / RATE
				var env := exp(-t * 3.0)
				var thump := exp(-t * 30.0) * sin(TAU * 45.0 * t)
				samples.append(sin(TAU * 60.0 * t) * env * 0.7 + sin(TAU * 120.0 * t) * env * 0.3 + thump)
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = samples.size()
	return w
