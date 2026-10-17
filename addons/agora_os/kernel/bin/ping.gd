extends AgoraProgram


func summary() -> String:
	return "check that a host is reachable"


func usage() -> String:
	return "usage: ping [-c count] host"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "c")
	if a.operands.is_empty():
		return p.fail(usage(), 2)
	var host := a.operands[0]
	var count := int(a.value("c", "4"))
	var target := p.machine
	var ip := "127.0.0.1"
	if host not in ["localhost", "127.0.0.1", p.machine.hostname]:
		var net := p.machine.network
		target = net.get_machine(host) if net else null
		if target == null:
			return p.fail("%s: Name or service not known" % host, 2)
		ip = target.ip
	p.outln("PING %s (%s): 56 data bytes" % [host, ip])
	var base := p.machine.network.latency_ms(p.machine, target) if p.machine.network and target != p.machine else 0.05
	var rng := RandomNumberGenerator.new()
	var sent := 0
	for i in count:
		if i > 0:
			await p.sleep(1.0)
		if p.is_dead():
			break
		sent += 1
		p.outln("64 bytes from %s: icmp_seq=%d ttl=64 time=%.2f ms" % [ip, i, base * rng.randf_range(0.9, 1.15)])
	p.outln("--- %s ping statistics ---" % host)
	p.outln("%d packets transmitted, %d received, 0%% packet loss" % [sent, sent])
	return 0
