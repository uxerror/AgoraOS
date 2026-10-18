# Next steps

Handoff note for continuing work in a new session.

## Where the project stands

The networking plan is done. Run the tests with
`godot --headless --path . -s tests/run_tests.gd`: there are 742 checks, all green
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
(nothing running survives, as after a power cut). A world is described by
an `AgoraWorldSpec` resource (`hardware/world_spec.gd`, a .tres edited in the
inspector): `AgoraBoxSpec` boxes (template, power, media, and the installed
system: profile, hostname, root password, more installer options in
`options`) and `AgoraCableSpec` cables (`a`, `b` as "box:port", length,
defects), plus the start time and clock speed. `build()` makes the world or
returns null with `error`. `replace` swaps a box
in place, keeping its cables.

`main.gd` runs `worlds/home.tres` (a PC and a router). Each box has a screen:
its monitor, or a terminal on its serial port. A bar on top switches between
them (Scroll Lock too) and has power buttons. A PC saved by an older version
(`user://machines/local.agx`) is moved into the new world on first start.
`tools/repl.gd` now saves to `user://machines/repl.agx`, apart from the GUI.

Next ideas for worlds: a visual editor for world specs (place boxes, draw
cables), cables moved by the player at run time (the bar could list ports),
and a bigger world with an ISP and servers once telnet/ftp/http exist.

## 2000s services

Data on TCP and UDP is a String; bytes that aren't text (and NUL) are the
characters U+F700 + byte (`AgoraWire.raw`, `raw_byte`, `byte_of`,
`encode`), so binary protocols put real bytes on the wire. `AgoraStream.read_some`
waits for whatever arrives, like read(2).

Telnet (done): `openbsd-inetd` (`system/inetd.gd`, `/etc/inetd.conf`,
`/etc/services` from `netbase`; TCP nowait services; SIGHUP rereads) starts
servers with the connection on stdin/stdout and `AgoraProcess.socket` set.
`tcpd` (`system/tcpd.gd`) checks `/etc/hosts.allow` and `/etc/hosts.deny`
(ALL, addresses, "a.b.c." prefixes, addr/mask, LOCAL, EXCEPT) and logs
"connect from"/"refused connect from" to auth. Packages can register inetd
lines (`"inetd": [...]`, like update-inetd); apkg sends inetd SIGHUP after
installing or removing. `in.telnetd` (netkit 0.17) negotiates (DO TTYPE,
TSPEED, XDISPLOC, NEW-ENVIRON; SB TTYPE SEND; WILL SGA, DO NAWS), shows
`/etc/issue.net` and runs `login -h client -p` on a pty; WILL/WONT ECHO
follows the pty's echo (BSD's line mode kludge), IAC IP interrupts, AYT
answers. `login` now asks for the name itself without one (three tries) and
logs util-linux style failures with FROM. The `telnet` client (netkit 0.17)
answers negotiation but never starts it, so it works as a raw TCP client
("telnet host 25"); Ctrl+C sends IP; end of input half-closes. The client
is in the desktop and server profiles, inetd in the server profile, the
server (`telnetd`) only on request. The password shows in `tcpdump -A`.

Not done: busybox telnetd on the router, inetd internal services
(echo, daytime...), UDP and "wait" services, tcpd host name patterns and
spawn/twist options, telnet's escape prompt (^]) and -l.

FTP (done): `ftpd` (`system/ftpd.gd`, linux-ftpd 0.17 / OpenBSD ftpd 6.4
replies) runs from inetd through tcpd. USER/PASS (`/etc/ftpusers` refuses
root and system accounts; "anonymous"/"ftp" logs in as the ftp user, locked
into its home), SYST, PWD, CWD/CDUP, TYPE A/I, PORT, PASV, LIST (runs
`/bin/ls -lA` as the user), NLST, RETR, STOR, SIZE, DELE, MKD, RMD,
RNFR/RNTO, NOOP, HELP, QUIT. File access uses the user's credentials. Active
mode connects from port 20 (`open_connection` now takes `sport` and `src`);
passive listens on an ephemeral port (`listen(p, 0)`). Logs go to daemon:
"FTP LOGIN FROM", "FTP LOGIN FAILED FROM", "ANONYMOUS FTP LOGIN FROM". The
`ftp` client (netkit 0.17; in the desktop and server profiles) logs in
automatically (Name/Password prompts), switches to binary after "UNIX Type:
L8", and has open, user, ls/dir, nlist, cd, cdup, pwd, get/recv, put/send,
mget, mput, delete, mkdir, rmdir, rename, size, system, ascii/binary/type,
passive, verbose, lcd, status, help, close, bye/quit; -p, -n, -v. Without a
terminal it is quiet except for errors. Binary transfers are byte-exact.

Not done: no FTP conntrack helper, so active mode through the router's NAT
fails (as on a real NAT without nf_conntrack_ftp) and passive works; no
REST, APPE, MDTM, STAT, ABOR; no globbing in the server's LIST.

Web (done): `apache2` (`system/apache2.gd`, Apache 2.2.3 as Debian ships it,
a service, not by default) reads apache2.conf and its Includes (ports.conf,
conf.d/, sites-enabled/): Listen, User, ServerName, DocumentRoot,
DirectoryIndex, ScriptAlias, Alias, ErrorLog, CustomLog, ServerTokens,
ServerSignature, IndexIgnore, and Options per <Directory> (Indexes). One
request per connection (Connection: close), HTTP/0.9 to 1.1, GET/HEAD/POST,
others 501. Files are read as www-data (uid 33, created by the package:
packages may declare system `users` now, created locked and without
/etc/skel). Directories without a slash get a 301; then DirectoryIndex, an
autoindex listing, or 403. CGI under ScriptAlias with the CGI/1.1
environment, the body on stdin, Status/Location/Content-Type headers, 500
with "Premature end of script headers" or "malformed header". access.log in
the combined format, error.log with Apache's messages, Apache's error pages.
`wget` 1.10.2 (desktop and server profiles): the log on stderr, -O (and -),
-q, -S, -U, --post-data, -T; redirects; index.html.1 for existing names.
Fixed on the way: `cat` from stdin added a newline to a last partial line.

Not done: keep-alive, virtual hosts by name, .htaccess, auth, mod_rewrite,
PHP; a text browser (lynx) would suit the era.

Lynx (done): raw mode on the tty (`AgoraTty.raw`, `type_key`, `cols`/`rows`;
the terminal view sends VT100 key sequences and knows reverse video and
`ESC[?25l`). `lynx` 2.8.5 full screen (links, history, paging, `/` search,
`\` source, `g`, forms with text fields, buttons, checkboxes, radios,
selects), `-dump` with references, `-source`, `-head`. `AgoraHtml` lays HTML
out as Lynx does; `AgoraHttp` fetches URLs, resolves relative links and
encodes forms. Remote raw mode over ssh/telnet is not done (lynx works
locally and through `ssh host lynx` only line by line).

The home world's internet (done): `worlds/home.tres` starts on 2003-10-18
21:30. `isp` (LanLink's border box: 203.0.113.1 for customers with udhcpd,
198.51.100.1 on the backbone, ip_forward, dnsmasq serving its /etc/hosts as
the net's DNS), `sw` (an unmanaged switch: template "switch", no OS, a
learning bridge in the hardware), `www1` (www.lanlink.net,
members.lanlink.net, ~kevin and ~jenna with a counter CGI), `www2`
(www.penguinpit.org, www.byteslash.org with a robots.txt-hidden /admin/),
`www3` (www.staticnoise.org, www.demozone.net, anonymous FTP), `search`
(www.ferret.org: `ferretd` crawls the seeds in /etc/ferret/ferret.conf and
submitted URLs every 30 minutes, honours robots.txt, writes
/var/lib/ferret/index; `/usr/lib/cgi-bin/search` ranks with title bonus and
pages ten at a time; `addurl` queues sites). Site files live under
`worlds/home/<box>/` and are copied by `AgoraBoxSpec.files` (with a
`.modes` file for special modes). apache2 gained name-based virtual hosts,
UserDir and `AddHandler cgi-script`. sh gained backquotes. The ftp client
now reports the server's 425 when an active data connection can't reach it
(behind NAT: use passive, `ftp -p`).

Exporting: the site files are not Godot resources; an export preset needs
`worlds/home/*` in its non-resource filter.

Next in the plan: a mail server.

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
- `scp`; remote raw terminals over ssh and telnet (character mode).
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
