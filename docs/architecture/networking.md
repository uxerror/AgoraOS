# Networking

Everything is simulated: a frame is a Dictionary passed between objects and
nothing touches the real network. People who know networking should recognise
the behaviour and the output of every tool. The physical layer (cables, bit
errors, negotiation, duplex) is in [hardware](hardware.md#network-cards-and-cables).

## The stack

`AgoraNetStack` (`kernel/net/netstack.gd`), one per running kernel.

- **Interfaces**: `lo`, one per NIC (unless the onboard LAN is off in the BIOS),
  bridges. Addresses with primary/secondary, the main and local routing tables
  with longest-prefix match, metrics and `proto`.
- **Ethernet and ARP**: frames `{dst, src, type, payload}`; ARP with Linux's
  neighbour states (`AgoraNeighbours`: INCOMPLETE, REACHABLE, STALE, DELAY,
  PROBE, FAILED, PERMANENT).
- **Bridges** (`AgoraBridge`): learning, forwarding, promiscuous ports;
  `stp on` is accepted and does nothing.
- **IPv4 forwarding** with `/proc/sys/net/ipv4/ip_forward` and the other
  sysctls; ICMP (`AgoraIcmp`) echo, unreachable and time exceeded.
- **UDP** (`AgoraUdp`) and **TCP** (`AgoraTcp`): everything travels as segments
  with sequence numbers: handshake (SYN options `mss 1460,nop,nop,sackOK,nop,
  wscale 7`), data (MSS 1460), ACKs, FIN, RST, Nagle (ssh sets TCP_NODELAY).
  Unacknowledged data is retransmitted with a doubling timeout until
  `tcp_retries2` gives up, so a pulled cable or a new firewall rule affects open
  connections. RST, ICMP errors and timeouts give Linux's errno. Programs see a
  connection as two `AgoraStream`s; data is a String where bytes that aren't
  text are U+F700 + byte (`AgoraWire.raw`), so binary protocols put real bytes on
  the wire.
- Packets carry the latency they picked up (`lat`), which `ping` and
  `traceroute` report.

## Netfilter

`AgoraNetfilter` runs the filter and nat tables at Linux's hooks (PREROUTING,
INPUT, FORWARD, OUTPUT, POSTROUTING) with connection tracking
(`AgoraConntrack`). NAT (SNAT, MASQUERADE, DNAT) is decided on a
flow's first packet and undone on replies and on ICMP errors about it.
`iptables` with `-A/-I/-D/-R/-F/-L/-n/-v/-x/--line-numbers`, the common matches
and targets (ACCEPT, DROP, REJECT, LOG, RETURN, user chains), `iptables-save` and `iptables-restore`. There is no FTP helper:
active FTP through NAT fails, passive works.

## Names

`AgoraResolver` works like glibc: `hosts:` in `/etc/nsswitch.conf`,
`/etc/hosts`, then DNS over UDP to `resolv.conf`'s nameservers with its search
list and options. `dnsmasq` answers from `/etc/hosts`, `address=`, `cname=`
and `mx-host=`, forwards the rest and caches it. Tools: `dig`, `host`,
`nslookup` (BIND 9 style; MX records too, and `host` without `-t` names a
domain's mail exchanger), `getent`. `AgoraResolver.mx(p, domain)` gives the
mail exchangers, best first.

## Configuration

- iproute2 `ip` (link, addr, route, neigh) and `bridge`;
  net-tools `ifconfig`, `route`, `arp`, `netstat`; `brctl`; `ethtool`;
  `sysctl`.
- ifupdown: `/etc/network/interfaces` (static, dhcp, manual), `ifup`/`ifdown`,
  the `networking` service.
- DHCP: busybox `udhcpc` (client) and `udhcpd` (server, `dumpleases`); leases
  follow game time.

## Capture

`AgoraCapture` is a packet socket (AF_PACKET). The stack taps frames where
Linux does: a NIC's output, its input after the MAC filter, a bridge both ways,
`lo` once per packet. Promiscuous mode is a counter that bridges and captures
share. `tcpdump` (4.99's formats) decodes ARP, ICMP (with quoted headers under
`-v`), TCP with relative sequence numbers per conversation, UDP, DNS, DHCP and
the ssh banner; options `-i -D -n -c -p -e -v/-vv -q -t..-ttttt -A -x -X -Q -s
-l --version`; filters in a small pcap grammar (and/or/not, parentheses,
qualifier inheritance, host, net, port, portrange, src/dst, ether host,
broadcast, less/greater, protocols). Without `-n` its PTR lookups show up too.
`AgoraWire` (`kernel/net/wire.gd`) gives frames their real bytes (headers,
checksums, DNS and DHCP encoding) for `-A`, `-x` and `-X`.

## What the kernel shows

`/proc/net/{dev,route,arp,tcp,udp,nf_conntrack}`, `/proc/sys/net/ipv4/*`
(writable), `/sys/class/net/*`, and kernel log lines (link up/down with speed
and duplex).

## The router

The router profile (busybox, `router-base`): `br-lan` bridges LAN1-4 at
192.168.1.1/24; udhcpd hands out 192.168.1.100-199; the WAN port asks for an
address with udhcpc; `/etc/init.d/firewall` masquerades the LAN and lets only
replies in; dnsmasq serves the LAN; sshd for administration; the serial console
for everything else.

## ssh

`ssh` and `sshd` run over TCP port 22 with password logins, commands and
interactive shells. Inside the connection `AgoraSshChannel` frames data,
stderr, terminal modes, signals, the window size and the exit status. It is
not encrypted (see [simplifications](../reference/simplifications.md)).

- **Terminals.** A shell gets a pseudo-terminal of the client terminal's
  type and size (the "PTY term cols rows" request, as pty-req). A command
  gets one with `-t`, and `-T` asks for none. When stdin is not a terminal,
  ssh says "Pseudo-terminal will not be allocated because stdin is not a
  terminal." and goes on without one (`-tt` forces it).
- **Full-screen programs.** When the remote terminal goes raw, so does the
  local one, and keys go over one at a time. lynx works through `ssh host`
  as it does locally. A new window size follows (window-change), and Ctrl+C
  reaches the remote program.
