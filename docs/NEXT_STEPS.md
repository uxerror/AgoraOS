# Next steps

Handoff note for continuing work in a new session.

## Where the project stands

The networking plan is done. Run the tests with
`godot --headless --path . -s tests/run_tests.gd`: there are 658 checks, all green
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
| 13 | `cf18986` | `dnsmasq` on the router, BIND tools |
| 14 | `e7ab011` | packet sockets for tcpdump |
| 15 | "net: tcpdump" | `tcpdump`, `AgoraWire` (frames as bytes) |

## tcpdump (done)

`kernel/bin/tcpdump.gd`, package `tcpdump` (desktop and server profiles; the
router has none). It reads an `AgoraCapture` and prints tcpdump 4.99's formats:
ARP (padded frames from the cable show `length 46`), ICMP with errors and `-v`
quoted headers, TCP with relative sequence numbers per conversation as
print-tcp.c does, UDP, DNS, DHCP, the ssh banner. Options: `-i` (name or `-D`
index), `-D`, `-n`, `-c`, `-p`, `-e`, `-v`/`-vv`, `-q`, `-t` to `-ttttt`, `-A`,
`-x`, `-X` (doubled: with the link header), `-Q`, `-s`, `-l`, `--version`.
Filters: a small pcap grammar with `and`/`or`/`not`, parentheses, qualifier
inheritance (`host a or b`), `host`, `net`, `port`, `portrange`, `src`/`dst`,
`ether host`, `broadcast`, `less`/`greater` and the protocol keywords. Without
`-n`, addresses go through the resolver, so its PTR queries show up too.

`kernel/net/wire.gd` (`AgoraWire`) encodes frames as bytes for `-A`/`-x`/`-X`
and the checksums `-v` prints. TCP SYNs now carry 12 bytes of options
(`mss 1460,nop,nop,sackOK,nop,wscale 7`, Linux with `tcp_timestamps=0`), so a
SYN is 52 bytes. The clock now uses microsecond ticks, for capture timestamps.

Not done: `-w`/`-r` (pcap files could now be written from `AgoraWire` bytes),
`-vv` decoding of DHCP options, `tcp[13]`-style byte offsets in filters.

## Physical layer

Done: `AgoraCable` (`hardware/cable.gd`). Link speed is the slower card's; one
transmit queue per direction; a frame's wire time is (8 preamble+SFD + frame
padded to 60 + 4 FCS) x 8 / speed; the 96-bit interframe gap only delays the
next frame; propagation is about 5 ns/m; delivery keeps order; `txqueuelen`
(`ip link set DEV txqueuelen N`) bounds the queue. Fixed along the way: nc
lost data when the other end half-closed first, and TCP sent one segment per
write (now Nagle, flush before FIN).

Done: bit errors (`AgoraCable.bit_error_rate()`). A sound cable has a BER of
1e-12; beyond its reach (100 m at 100 Mbit/s, 150 m at 10 Mbit/s) it grows
tenfold every 10 m. Defects in `cable.defects` add to it (`untwisted` 1e-7,
`bad_crimp` 1e-6, `crushed` 2e-5 at 100 Mbit/s, a hundredth of that at 10).
Each frame is checked once from BER x bits (padded frame + FCS) with the
cable's `rng`; a hit frame gets `bad_fcs`, and the receiving card counts it in
`rx_errors` and `rx_crc_errors` and drops it before the capture tap. The stack
keeps all `rtnl_link_stats64` counters and `carrier_changes`; they show in
`ip -s -s link` (the RX/TX error lines), ifconfig (`frame:` sums like
`/proc/net/dev`), `netstat -i`, `/proc/net/dev` and `/sys/class/net/*`.

Done: negotiation, duplex and `ethtool`. Cards have a chip (`AgoraNic.driver`:
`e100` 100 Mbit/s on the PC, `e1000` gigabit on the server and the virtual
machine, `b44` on the router) and PHY settings (`autoneg`, `advertising`,
`forced_speed`, `forced_duplex`), reset when the kernel's driver loads. The
cable negotiates like clause 28: both autoneg take the best common mode,
skipping speeds whose BER is at or above `LINK_BER` (1e-3; a 200 m cable comes
up at 10 Mbit/s); an autoneg end facing a forced one detects the speed and takes
half duplex (duplex mismatch); garbled pages (BER at 10 Mbit/s above
`PAGE_BER`, 1e-4) make both fall back to 10/half. Any change to the cable or
the settings renegotiates, with link down/up.

Transmission is a small discrete-event simulation in virtual time. Full/full
links lay frames out ahead as before. With a half-duplex end, starts are only
decided when their time comes: carrier sense defers (`tx_deferred`),
simultaneous starts collide with jam and binary exponential backoff (16 tries,
then `tx_aborted_errors`), and in a mismatch the full-duplex end's frames hit
the half-duplex one mid-frame: late collisions (`tx_window_errors`, frame lost,
no retry), runts (`rx_length_errors`) and CRC errors at the full-duplex end.
TCP then crawls on RTO retransmissions, as on a real mismatch. Note: the
simulated hosts emit a segment only every few ms, so at 100 Mbit/s the wire
is mostly idle and collisions are rare; at 10 Mbit/s they are plentiful.

`ethtool` 5.9 (ioctl-style output): settings with link modes, link partner
(e100 and b44 only, as their MII drivers report it), Speed/Duplex, MDI-X
(e1000), wake-on-LAN (root only), message level, link detected; `-i`, `-S`
with each driver's statistic names, `-s` (speed, duplex, autoneg, advertise;
EPERM, EINVAL for forced gigabit, "not setting" lines), `-r`. Also
`/sys/class/net/*/duplex`, duplex in the kernel's link-up message, STP port
cost by speed.

Next:
- Later, for the game: 90s-2000s media (coax 10BASE2, hubs, shared collision
  domains, modems), so keep the cable model open to other media.

## Worlds

`AgoraWorld` (`hardware/world.gd`): named boxes, the cables between their ports
(length, defects) and one clock. `save`/`load_from` keep everything in one file
(`user://worlds/home.agw` for the demo) with the power state of each box; on
load the cables are plugged back and the boxes that were on boot again
(nothing running survives, as after a power cut). `from_spec`/`from_json`
build a world from a description: boxes with a template, an optional
`install` (the installer's options) and `media`, and cables as
`["box:port", "box:port"]` or `{a, b, length, defects}`. `replace` swaps a box
in place, keeping its cables.

`main.gd` runs `worlds/home.json` (a PC and a router). Each box has a screen:
its monitor, or a terminal on its serial port. A bar on top switches between
them (Scroll Lock too) and has power buttons. A PC saved by an older version
(`user://machines/local.agx`) is moved into the new world on first start.
`tools/repl.gd` now saves to `user://machines/repl.agx`, apart from the GUI.

Next ideas for worlds: an editor for the description (place boxes, draw
cables), cables moved by the player at run time (the bar could list ports),
and a bigger world with an ISP and servers once telnet/ftp/http exist.

## Known simplifications

- TCP has retransmission and Nagle's algorithm (ssh/sshd set TCP_NODELAY) but
  no congestion or flow control (the window is always 65535), no delayed ACKs
  and no out-of-order queue (a gap is answered with a duplicate ACK and filled
  by the retransmission).
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
