extends AgoraProgram


func summary() -> String:
	return "show network interfaces"


func main(p: AgoraProcess) -> int:
	p.outln("lo: inet 127.0.0.1  netmask 255.0.0.0")
	if p.machine.network != null:
		p.outln("eth0: inet %s  netmask 255.255.255.0" % p.machine.ip)
	return 0
