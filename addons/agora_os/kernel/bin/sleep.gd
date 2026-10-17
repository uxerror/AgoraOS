extends AgoraProgram


func summary() -> String:
	return "wait for a number of seconds"


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2 or not p.argv[1].is_valid_float():
		return p.fail("invalid time interval", 2)
	await p.sleep(p.argv[1].to_float())
	return 0
