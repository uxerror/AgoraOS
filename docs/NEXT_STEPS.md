# Next steps

Handoff note for continuing work in a new session.

## Where the project stands

The networking plan is done. Run the tests with
`godot --headless --path . -s tests/run_tests.gd`: there are 528 checks, all green
(about a minute, since network timeouts run in real time).

Done before the networking work: kernel, GUI, init (systemd and sysvinit), hardware,
packages and profiles, the install CD. See `docs/architecture.md`, which now has a
Networking section.

Networking, one commit per step:

| Step | Commit | What |
|------|--------|------|
| 1 | `52b8bb5` | `AgoraNetStack`: interfaces, addresses, routes, `/proc/net`, `/sys/class/net` |
| 2 | `c5227c7` | Ethernet frames over cables, ARP with Linux's neighbour states |
| 3 | `426edd2` | iproute2 `ip`; net-tools `ifconfig`, `route`, `arp` |
| 4 | `b0c36e2` | ICMP, a real `ping` (iputils output; busybox format as an applet) |
| 5 | `04bc869` | ifupdown, the `networking` service, `/etc/hosts`, installer network question |
| 6 | `4bf4f10` | Ethernet bridge, `brctl`, `bridge`; `br-lan` on the router |
| 7 | `ae63e52` | UDP; busybox `udhcpd`, `udhcpc`, `dumpleases` |
| 8 | `7f09302`, `79f044b`, `5567167` | forwarding, `/proc/sys`, `sysctl`, `traceroute`; netfilter, conntrack, `iptables`; NAT and the router firewall |
| 9 | `adfe6e3` | TCP; `ssh`/`sshd` over TCP; `nc`, `netstat` |
| 10 | "net: retire AgoraNetwork" | `AgoraNetwork` removed; names come from `/etc/hosts` |
| 11 | `c256c98` | TCP data as segments: sequence numbers, ACKs, retransmission, `tcp_retries2` |
| 12 | `17ce2e1` | glibc-style resolver: nsswitch, `/etc/hosts`, `resolv.conf`, DNS queries |
| 13 | "net: dnsmasq, dig, host, nslookup, getent" | `dnsmasq` on the router, BIND tools |

## Known simplifications

- TCP has retransmission but no congestion or flow control (the window is
  always 65535) and no out-of-order queue (a gap is answered with a duplicate
  ACK and filled by the retransmission).
- DNS is UDP only, with no zones or SOA records: `dnsmasq` serves `/etc/hosts`
  and forwards. `iptables` resolves host names from `/etc/hosts` only.
- No IPv6, no fragmentation (MTU is shown but not enforced), no STP (`stp on` is
  accepted and does nothing).
- The SSH "protocol" inside the connection is plain text lines (`AUTH`, `SHELL`,
  `EXEC`, then base64 channel messages), not encrypted.
- Lease, ARP and conntrack timers: DHCP leases follow the game clock; ARP,
  retransmissions and conntrack follow real time.

## Ideas for what comes next

- A BIND-style authoritative server with zone files, for the game's internet.
- `tcpdump` on an interface (TCP data now travels as packets).
- `telnet`, `ftp`, `scp`, and a small web server and client (`wget`).
- The graphical installer, and disk capacity limits (both postponed earlier).
- Game mechanics that only work with simulation objects are designed separately.

## Requirements from the user (still apply)

- The game is accurate and aimed at people who understand networking. Tools must
  match real Linux tools in behavior and output.
- Everything is simulated inside Godot. No real sockets and no real network.
- Work in small steps and commit after each one, once the tests are green.

## Code conventions

- GDScript 4.7. There are no octal literals: write modes in decimal with an octal
  comment. Don't name members `_set`, `theme`, `load`, `get_script`, `script` or
  `connect`, because they clash with built-ins.
- Typed variables: when a value comes from a Dictionary or Variant, write
  `var x: T =` instead of `:=`.
- New `class_name` scripts need `godot --headless --import` once before the tests
  see them.
- Programs extend `AgoraProgram`, are registered in `kernel/programs.gd`, and belong
  to a package in `system/distro.gd`. Router applets go into `BUSYBOX_APPLETS`. An
  applet can check `multicall == "busybox"` to print busybox's format.
- Callables stored on long-lived objects (signal handlers, signal connections to
  lambdas) must be dropped when the process or connection ends, or they keep the
  objects alive.
- In tests, wait with `until(cond)` instead of fixed delays. Register machines in
  `_machines` so they are shut down after the test. `start()` runs a command in the
  background.
- Commits: author `uxerror`, with the line
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
