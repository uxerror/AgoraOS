class_name AgoraNetwork
extends RefCounted
## A simulated network that machines attach to. It maps addresses and host
## names to machines. Remote tools such as ssh and ping go through it.
##
## This is deliberately simple for now: one flat network, no routing, and no
## packets. The game can grow it into subnets, firewalls and open ports.

var _by_ip := {} # ip -> AgoraMachine
var _dns := {} # host name -> ip


func attach(machine: AgoraMachine, ip: String, dns_name: String = "") -> void:
	_by_ip[ip] = machine
	machine.ip = ip
	machine.network = self
	var host := dns_name if not dns_name.is_empty() else machine.hostname
	if not host.is_empty():
		_dns[host] = ip


func detach(machine: AgoraMachine) -> void:
	_by_ip.erase(machine.ip)
	for host in _dns.keys():
		if _dns[host] == machine.ip:
			_dns.erase(host)
	machine.network = null


## Address for a host name or address, or "" if unknown.
func resolve(host: String) -> String:
	if _by_ip.has(host):
		return host
	return _dns.get(host, "")


func get_machine(host: String) -> AgoraMachine:
	return _by_ip.get(resolve(host))


func hosts() -> Dictionary:
	return _dns.duplicate()


## Fake but stable round-trip time between two machines, in milliseconds.
func latency_ms(from: AgoraMachine, to: AgoraMachine) -> float:
	if from == to:
		return 0.05
	var h := hash(from.ip + ">" + to.ip) if from.ip < to.ip else hash(to.ip + ">" + from.ip)
	return 8.0 + float(absi(h) % 140)
