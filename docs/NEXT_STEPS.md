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
| 13 | `cf18986` | `dnsmasq` on the router, BIND tools |
| 14 | "net: packet capture in the kernel" | packet sockets for tcpdump (the program is still to do) |

## In progress: tcpdump

The kernel side is done and committed ("net: packet capture in the kernel");
the `tcpdump` program itself is not written yet. An earlier attempt was cut off
before the file was finished, so start the program from scratch.

### What the kernel already provides

- `kernel/net/capture.gd` — `AgoraCapture`, a packet socket like AF_PACKET:
  `device` (an interface name or `"any"`), `promisc`, `direction` (`"in"`,
  `"out"`, `"inout"`, for `-Q`), `inbox`, `pid`, `close()`.
- `AgoraNetStack.open_capture(p, device, promiscuous) -> AgoraCapture`, or null
  with `last_capture_error`: `EPERM` for non-root, `ENODEV` for an unknown
  device, `ENETDOWN` for a device that is down. `"any"` never turns on
  promiscuous mode.
- Each `inbox` entry is `{time, iface, dir, otherhost, frame}`:
  - `time` is the machine clock (`clock.now()`, with fractions);
  - `dir` is `"in"` or `"out"`;
  - `otherhost` is true for a frame addressed to another MAC that the card only
    accepted because it is promiscuous;
  - `frame` is a deep copy `{dst, src, type, payload, len}`. `type` is
    `ETH_P_IP` (payload: the IP packet dictionary) or `ETH_P_ARP` (payload:
    `{op, sha, spa, tha, tpa}`).
- Where frames are tapped (`AgoraNetStack._tap`):
  - a NIC in `xmit`, only when the frame really goes out, so not without carrier;
  - a NIC in `_on_frame` after the card's MAC filter;
  - a bridge both ways: `send_frame` for its own output, `AgoraBridge._up` for
    frames delivered to it, and its ports see everything as NICs do;
  - `lo` once per packet, in `_loopback`, with zero MAC addresses.
- `set_promisc(iface, ±1)` is a counter that the bridge and captures share.
  Moving between 0 and 1 logs "device X entered/left promiscuous mode", as
  Linux does. While it is above 0 the card accepts every unicast frame; the
  stack still drops frames that are not for it, after tapping them.
- Captures close when their process exits (`close_captures_for`) and when the
  kernel stops.

### What the program should do (tcpdump 4.99)

- **Files and packaging.** `kernel/bin/tcpdump.gd`, installed at
  `/usr/bin/tcpdump` (add it to `PATHS` in `programs.gd`), a `tcpdump` package,
  in the desktop and server profiles. The router has no tcpdump: busybox
  1.1.3 had none.
- **Interface choice.** `-i IFACE`, or the first interface that is up and not
  loopback, by index. `-D` lists interfaces: `1.eth0 [Up, Running, Connected]`,
  then `any (Pseudo-device that captures on all interfaces) [Up, Running]` and
  `lo [Up, Running, Loopback]`.
- **Options.**
  - `-n` (no names);
  - `-c N`;
  - `-p` (not promiscuous);
  - `-e` (link-level header);
  - `-v` (IP header);
  - `-q`;
  - `-t` / `-tttt`;
  - `-A` (payload as text: plain protocols show their data, ssh shows its
    base64 channel lines);
  - `-Q in|out|inout`;
  - `-s`, `-l` (accepted).
  - `-w`/`-r` can wait: packets are dictionaries, not bytes.
- **Startup lines (stderr).** `tcpdump: verbose output suppressed, use
  -v[v]... for full protocol decode` (without `-v`), then `listening on eth0,
  link-type EN10MB (Ethernet), snapshot length 262144 bytes`. For `any`:
  `link-type LINUX_SLL2 (Linux cooked v2)`.
- **End (stderr), after `-c` or SIGINT/SIGTERM.** `N packets captured`, `N
  packets received by filter`, `0 packets dropped by kernel`, with the
  singular "packet" for 1.
- **Errors.**
  - `tcpdump: eth0: You don't have permission to capture on that device` with
    `(socket: Operation not permitted)` on the next line;
  - `tcpdump: eth9: No such device exists` with `(SIOCGIFHWADDR: No such
    device)`;
  - `tcpdump: eth1: That device is not up`;
  - bad filters: `tcpdump: can't parse filter expression: syntax error`.
- **Line layout.**
  - Timestamp `HH:MM:SS.uuuuuu` in local time.
  - For `any`: the interface padded to 5 characters, then `In ` / `Out` / `B  `
    (a broadcast received).
  - With `-e`: `MAC > MAC, ethertype IPv4 (0x0800), length N:`, and the
    following `IP ` is dropped.
- **Protocols.**
  - ARP: `ARP, Request who-has A tell B, length 28`; `ARP, Reply A is-at MAC,
    length 28`.
  - ICMP: `IP A > B: ICMP echo request, id I, seq S, length L`, where L is the
    ICMP length.
  - ICMP errors:
    - `ICMP host X unreachable`;
    - `ICMP net X unreachable`;
    - `ICMP X udp port P unreachable`;
    - `ICMP time exceeded in-transit`;
    - the `- admin prohibited` variants.
  - TCP: `IP A.p > B.q: Flags [S], seq N, win 65535, options [mss 1460], length 0`.
    - Flags are `S`, `S.`, `.`, `P.`, `F.`, `R`, `R.`.
    - Sequence numbers are absolute on SYNs and relative to the first one seen
      in each direction afterwards: `seq 1:32, ack 1`.
    - `seq` is shown for data, SYN, FIN and RST; `ack` whenever ACK is set.
  - UDP: `UDP, length N`.
  - DNS, on port 53:
    - query: `ID+ A? name. (size)`;
    - reply: `ID 1/0/0 A 1.2.3.4 (size)`, with `*` after the ID when aa is
      set, `NXDomain`/`ServFail`/`Refused`, and PTR/CNAME answers.
  - DHCP, on ports 67/68: `BOOTP/DHCP, Request from MAC, length 300` /
    `BOOTP/DHCP, Reply, length 300`.
  - With `-v`: `IP (tos 0x0, ttl T, id I, offset 0, flags [DF], proto ICMP (1),
    length L)`, then a newline and 4 spaces before the rest.
- **Names.** Without `-n`, addresses go through `AgoraResolver.reverse` (cached;
  it sends DNS queries, which tcpdump then sees, like the real one) and ports go
  through a services table (`ssh`, `domain`, `bootps`, ...).
- **Filters (a small BPF parser).**
  - Primitives:
    - `[src|dst] host H`;
    - `[src|dst] net N[/len]`;
    - `[src|dst] port P`;
    - `portrange A-B`;
    - `tcp`, `udp`, `icmp`, `arp`, `ip`;
    - `tcp port 22`;
    - `ether host MAC`;
    - `less N`, `greater N`.
  - Combine them with `and`/`&&`, `or`/`||`, `not`/`!` and parentheses.
  - `host` also matches ARP sender and target addresses. Host names are
    resolved before the capture starts.

### Tests to add

- `tcpdump -n -c 4 -i eth0 icmp` while pinging: echo request/reply lines, then
  the stats.
- ARP lines on a fresh neighbour.
- A TCP handshake with relative sequence numbers (nc), `-A` showing the
  transferred text.
- DNS query/reply lines through the router.
- `-i any` with In/Out.
- Promiscuous mode in the kernel log.
- The filter errors and the non-root error.

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
