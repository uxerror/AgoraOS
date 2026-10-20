class_name AgoraWav
extends RefCounted
## WAV files (RIFF, PCM): reading the format and the samples, and making
## one from samples. Used by /dev/dsp, play, and programs that bring their
## own sounds.


## {rate, channels, bits, data} of a PCM WAV file, or {} if it isn't one.
static func parse(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF" or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		return {}
	var out := {}
	var k := 12
	while k + 8 <= bytes.size():
		var id := bytes.slice(k, k + 4).get_string_from_ascii()
		var size := bytes.decode_u32(k + 4)
		var body := k + 8
		if id == "fmt " and size >= 16:
			if bytes.decode_u16(body) != 1:
				return {} # not PCM
			out.channels = bytes.decode_u16(body + 2)
			out.rate = bytes.decode_u32(body + 4)
			out.bits = bytes.decode_u16(body + 14)
		elif id == "data":
			out.data = bytes.slice(body, mini(bytes.size(), body + size))
		k = body + size + (size & 1)
	return out if out.has("data") and out.has("rate") else {}


## A mono 16-bit WAV file of [param samples] (-1..1) at [param rate].
static func make(samples: PackedFloat32Array, rate: int = 22050) -> PackedByteArray:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var head := PackedByteArray()
	head.resize(44)
	head.encode_u32(0, 0x46464952) # "RIFF"
	head.encode_u32(4, 36 + data.size())
	head.encode_u32(8, 0x45564157) # "WAVE"
	head.encode_u32(12, 0x20746d66) # "fmt "
	head.encode_u32(16, 16)
	head.encode_u16(20, 1)
	head.encode_u16(22, 1)
	head.encode_u32(24, rate)
	head.encode_u32(28, rate * 2)
	head.encode_u16(32, 2)
	head.encode_u16(34, 16)
	head.encode_u32(36, 0x61746164) # "data"
	head.encode_u32(40, data.size())
	return head + data


## Godot's stream for [param pcm] as a sound card gets it (8-bit samples
## are unsigned in WAV, signed in Godot).
static func to_stream(pcm: PackedByteArray, rate: int, channels: int, bits: int) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.mix_rate = rate
	w.stereo = channels == 2
	if bits == 8:
		var signed := pcm.duplicate()
		for i in signed.size():
			signed[i] = (signed[i] + 128) & 255
		w.format = AudioStreamWAV.FORMAT_8_BITS
		w.data = signed
	else:
		w.format = AudioStreamWAV.FORMAT_16_BITS
		w.data = pcm
	return w


## A short tone: [param notes] as [[frequency, seconds]], each fading out.
static func chime(notes: Array, rate: int = 22050, volume: float = 0.5) -> PackedByteArray:
	var samples := PackedFloat32Array()
	for note: Array in notes:
		var n := int(rate * float(note[1]))
		for i in n:
			var t := float(i) / rate
			var env := minf(1.0, t * 200.0) * exp(-t * 6.0)
			samples.append((sin(TAU * float(note[0]) * t) * 0.8 + sin(TAU * float(note[0]) * 2.0 * t) * 0.2) * env * volume)
	return make(samples, rate)
