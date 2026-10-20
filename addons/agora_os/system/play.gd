extends AgoraProgram
## play (sox 12.17): plays sound files on /dev/dsp. WAV files play as they
## are; -r, -c, -b/-w and -u/-s describe raw files.


func summary() -> String:
	return "play sound files (sox)"


func usage() -> String:
	return "play: Usage: play [ fopts ] infile [effect [effopts]]"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "rct")
	if a.operands.is_empty():
		return p.fail(usage(), 1)
	var dsp := "/dev/dsp"
	if not p.exists(dsp):
		return p.fail("play: Can't open output file '%s': No such file or directory" % dsp, 1)
	for file in a.operands:
		if not p.exists(file):
			return p.fail("play: Can't open input file '%s': No such file or directory" % file, 1)
		var bytes := p.read_bytes(file)
		var wav := AgoraWav.parse(bytes)
		var type := str(a.value("t", file.get_extension().to_lower()))
		if wav.is_empty() and type == "wav":
			return p.fail("play: Failed reading %s: WAVE: RIFF header not found" % file, 1)
		if p.write_bytes(dsp, bytes) != AgoraErrno.OK:
			return p.fail("play: Can't open output file '%s': %s" % [dsp, AgoraErrno.describe(p.machine.vfs.errno)], 1)
		# It takes as long as the sound lasts.
		var seconds := 0.0
		if not wav.is_empty():
			seconds = float((wav.data as PackedByteArray).size()) / (int(wav.rate) * int(wav.channels) * int(wav.bits) / 8)
		else:
			seconds = bytes.size() / 8000.0
		await p.sleep(minf(seconds, 30.0))
	return 0
