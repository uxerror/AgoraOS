extends AgoraProgram


func summary() -> String:
	return "print a sequence of numbers"


func usage() -> String:
	return "usage: seq [first [step]] last"


func main(p: AgoraProcess) -> int:
	var nums: Array[int] = []
	for o in p.argv.slice(1):
		if not o.is_valid_int():
			return p.fail("invalid argument '%s'" % o)
		nums.append(int(o))
	var first := 1
	var step := 1
	var last := 0
	match nums.size():
		1: last = nums[0]
		2:
			first = nums[0]
			last = nums[1]
		3:
			first = nums[0]
			step = nums[1]
			last = nums[2]
		_: return p.fail("missing operand", 2)
	if step == 0:
		return p.fail("step can't be zero")
	var i := first
	while (step > 0 and i <= last) or (step < 0 and i >= last):
		if not p.outln(str(i)):
			return 1
		await p.tick()
		i += step
	return 0
