# Next steps

Handoff note for continuing work in a new session.

## Where the project stands

The networking plan is done. Run the tests with
`godot --headless --path . -s tests/run_tests.gd`: there are 928 checks, all green
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

## Ping! Messenger (done)

GUI apps for ordinary players come first now; the mail and multiplayer
plan below stays as it is (POP3, fetchmail, several homes).

An ICQ-style messenger of our own. `AgoraPing` (`system/ping_proto.gd`)
describes the protocol, PingNet/1.0: text lines over TCP 5190
(`pingnet` in /etc/services), a trailing ":" argument with `\n` escapes;
REGISTER, LOGIN, STATUS, ADD, DEL, MSG, INFO, SEARCH, NICK, NOP, BYE; the
server sends CONTACT, PRESENCE, MSG, OFFLINE, KICKED, ERROR. Statuses:
online, ffc, away, na, occupied, dnd, invisible (seen as offline).

`pingd` (`system/pingd.gd`, service, package `pingd`, on request):
`/etc/pingd.conf` (name, port, first_uin, register), accounts in
`/var/lib/pingd/accounts` (uin:hash:nick:contacts; "!" locks one), waiting
messages in `/var/lib/pingd/offline/UIN`; a second login kicks the first;
logs to daemon. `AgoraPingClient` (`system/ping_client.gd`): connection,
`request()` with answers and collected lines, keepalive.

`pingmsg` (`gui/apps/pingmsg.gd`, package `pingmsg` in the desktop
profile, menu entry "Ping! Messenger"): login form or "Get a new Ping!
number", contact list (Online / Offline / Not in list) with status lights
drawn in code, status menu, Add, Find, right-click menu (message, info,
remove), a window per conversation (Enter sends, Shift+Enter is a new
line), history in `~/.pingmsg/history/UIN`, account and saved password in
`~/.pingmsg/account` (0600). `/etc/pingmsg.conf` names the server.

In the home world: box `ping` (198.51.100.30, `login.pingmsg.com`,
`www.pingmsg.com` with an FAQ and news, seeded accounts Ping! Team 100001,
kevin 100007, jenna 100012; players get 100013 on), crawled by the Ferret.

Ideas: sounds (the display has no audio yet), a notifier in the panel,
blinking taskbar buttons for new messages, a terminal client, file
transfer, chat rooms, bots on the server, authorization requests.

## Kestrel Navigator (done)

A graphical web browser, the second app for ordinary players.
`AgoraHtmlView` (`gui/html_view.gd`) is the engine: a forgiving DOM
(implied end tags for p, li, dt/dd, tr, td/th, option; tables get missing
rows; forms are numbered while parsing), then layout into a display list:
block margins that collapse, inline runs with word wrap (breaks only at
spaces), headings, ul/ol with markers, dl, blockquote, pre, center and
align, `<font>` size/color/face, b/i/u/tt/big/small, hr, `<a name>`
anchors, images (width/height, border on links, alt boxes while loading),
tables with min/max column widths, colspan, width px/%, cellpadding,
cellspacing, border, bgcolor on table/tr/td, align/valign. Form fields are
real controls with a classic grey theme (`apply_classic`, overrides because
an inherited theme reaches new controls too late); GET and POST forms
send what Netscape sent ("Submit Query", image x/y, checkbox "on").
Fonts: the engine's default sans (bold by embolden, italic by a shear) and
DejaVu Sans Mono. Pictures scale with nearest pixels.

GIF: `AgoraGif` (`gui/gif.gd`) decodes GIF87a/89a itself (LZW, global and
local palettes, interlacing, transparency, frames composed with disposal
methods 1-3, delays with the 0.1 s minimum, NETSCAPE2.0 loops).
`AgoraGifTexture` (`gui/gif_texture.gd`) is a Texture2D whose `_draw*`
pick the frame by the clock (AnimatedTexture is deprecated); the view
redraws while one plays. Fixtures in `tests/fixtures/*.gif` (made with
Pillow; the interlaced one by hand, Pillow 12 writes none).

Selection: drag, double-click (a word), Ctrl+A, Ctrl+C (the system
clipboard, which the OS's own text fields paste from); white on dark blue.
Links open on release without a drag. `find_text()` finds case-
insensitively from the selection on and wraps. Kestrel's Edit menu: Copy,
Select All, Find in Page (Ctrl+F), Find Again (F3).

Not done: floats (`<img align>`), rowspan, frames, CSS, JavaScript.

`kestrel` (`gui/apps/kestrel.gd`, package `kestrel` in the desktop
profile, menu "Kestrel Navigator", also the text/html application):
File (New Window, Open Location, Save As, View Source, Close), Go (back,
forward, home, recent pages), Bookmarks (Netscape's bookmarks.html in
`~/.kestrel`, defaults from `/etc/kestrel/bookmarks.html` with the world's
sites), history in `~/.kestrel/history` (visited link colors), homepage
from `/etc/kestrel/kestrel.conf` (www.lanlink.net), Netscape 4 style status
messages and error pages, an animated logo, User-Agent
"Mozilla/4.0 (compatible; Kestrel/1.0; AgoraOS)", about:, file:, text/plain
and images shown directly, other types offered for saving.

Screenshots for checking the look: render under `xvfb-run` into a
SubViewport (see the session of 2026-10-18), not in the headless tests.

## apkg: archives on the net (step 1 of 3, done)

`AgoraArchive` (`system/archive.gd`): archives laid out like Debian's,
`BASE/dists/SUITE/COMPONENT/Packages` (stanzas: Package, Version,
Architecture, Maintainer, Depends, Size, MD5sum, Filename, Description),
`BASE/dists/SUITE/Release`, `BASE/pool/COMPONENT/L/NAME/NAME_VERSION.pkg`;
`write()` and `scan()` (rebuilds the index from the pool), stanza parsing,
`compare_versions()` as dpkg (epoch, upstream, revision, "~" first,
letters before symbols) and `satisfies()` (>=, <=, >>, <<, =).
`AgoraFetch` (`system/fetch.gd`): file:, http: and anonymous passive
ftp: downloads, with apt's error texts.

`apkg` (apt-get 0.5 style output): `/etc/apkg/sources.list` ("apkg URI
SUITE COMPONENT..."; "deb" is accepted too), `update` (Get/Hit/Err,
indexes in /var/lib/apkg/lists), `install [-y] NAME[=VERSION]` (newest
version, dependencies with alternatives and constraints, "extra" and
"NEW" lists, a question on a terminal when extras come along, download to
/var/cache/apkg/archives, size and MD5 checked against the index, dpkg's
Selecting/Unpacking/Setting up), `search`, `show` (every version),
`list [--available]`, `info` (with the candidate), `files`, `remove`,
`clean`. Errors and exit code 100 as apt; not root: "are you root?".
The install CD carries an archive at its root (the installer reads it);
/etc/apkg/repositories is gone.

Default source: `http://ftp.agoraos.org/agora`. In the home world the
`mirror` box (198.51.100.40) is ftp.agoraos.org, www.agoraos.org and
mirror.lanlink.net: the archive in /home/ftp/agora (installer option
"archive"), served by anonymous FTP and by apache (`Alias /agora`, with
listings). Changing the server is editing sources.list; an archive one
controls may serve anything, and the MD5 sums only prove the files match
the index from the same server.

## apkg: versions (step 2 of 3, done)

`AgoraPackages.install` now upgrades and downgrades in place: files of the
old version that the new one lacks are removed; configuration files
(everything under /etc, or listed in "conffiles") are handled as dpkg
does, by the MD5 recorded at install time (control "conffiles"): an
untouched one is replaced, one changed by the user stays and the new one
lands as FILE.dpkg-dist (or, if the user answers Y, the new one is put in
and the old kept as FILE.dpkg-old), one the user deleted stays deleted.
`remove` keeps configuration files (state "config-files", shown by
`info`); `purge` takes them and the record. `resolve()` (the installer)
understands "a | b (>= 1)".

`apkg`: `upgrade` (held packages and those needing new packages are
"kept back"), `dist-upgrade` (installs new dependencies, removes
conflicting packages), `policy [NAME]` (apt-cache policy's table),
`hold`/`unhold` (/var/lib/apkg/hold; `list` marks "[hold]"),
`list --upgradable`, DOWNGRADED and REMOVED sections, "N downgraded",
the dpkg conffile question on a terminal (Y/I/N/O, default N; without a
terminal or with -y the user's file stays), Provides (virtual packages:
dependencies are met by an installed provider or the first available
one; installing a virtual package lists its providers) and Conflicts
(either side; the other package is removed). The cache is reused when a
downloaded file still matches the index. In the catalog exim4 provides
mail-transport-agent and bsd-mailx depends on "exim4 |
mail-transport-agent".

## apkg: packages of one's own (step 3 of 3, done)

`apkg-build DIR [FILE]` (`system/apkg_build.gd`, like dpkg-deb --build):
DIR holds the tree as it will lie on the system plus `APKG/control`
(Package and Version required; Depends, Conflicts, Provides, Replaces,
Maintainer, Description), `APKG/conffiles` and the maintainer scripts
(modes 0555..0775 or the build fails, as dpkg-deb insists). Files keep
their modes and are installed owned by root; files that aren't UTF-8
text go into the package as [base64, mode, "base64"]. Any user may build;
the result is NAME_VERSION.pkg. Native programs still can't be made this
way (a package may carry shell scripts, data, or copies of existing
program stubs).

`apkg-scanpackages [-s SUITE] [-c COMPONENT] [-o ORIGIN] BASE`
(`system/apkg_scan.gd`): indexes BASE/pool/COMPONENT into
BASE/dists/SUITE/..., writing with the caller's own rights; "Wrote N
entries to output Packages file." on stderr. Serve BASE with apache or
ftpd and add it to sources.list.

`apkg install FILE.pkg` (anything with "/" or ending in .pkg) installs a
package file, dependencies from the archives. Maintainer scripts run as
dpkg runs them, through /bin/sh with APKG_MAINTSCRIPT_PACKAGE and
APKG_MAINTSCRIPT_NAME: install: preinst install, unpack, postinst
configure; upgrade: old prerm upgrade NEW, new preinst upgrade OLD,
unpack, old postrm upgrade NEW, new postinst configure OLD; remove: prerm
remove, postrm remove; purge: postrm purge. Scripts are kept in
/var/lib/apkg/info/NAME.SCRIPT (postrm until purge). A failing preinst or
prerm stops that package ("dpkg: error processing NAME (--install): ...",
"Errors were encountered while processing:", exit 100); a failing
postinst leaves it unpacked but reports the same way.

Ideas for later: signed archives (Release.gpg, apt-secure came in 2005);
apkg-build lintian-style checks; a web page per archive (index.html
generated next to dists/); triggers.

## Put aside for later (2026-10-19)

The user paused these to work on apkg first. In this order when we come
back:

1. Mail: `fetchmail` (~/.fetchmailrc, POP3 into the local sendmail).
2. The provider's mail server `mail.lanlink.net` in the home world (exim4
   "internet" with relaying for LanLink customers, popa3d, MX for
   lanlink.net in the ISP's dnsmasq), with a mailbox per player.
3. The internet for several players (see "Handoff" below): a customer
   switch at the ISP, adding and removing a home (PC + router) at run
   time, tests with several homes at once.
4. Pigeon Mail: MIME (attachments, quoted-printable, base64, multipart),
   folders of one's own, an address book, sorting by column.
5. Kestrel: floating images (`<img align>`), rowspan, frames.
6. Ping!: sounds (the display has no audio yet), a notifier in the panel,
   blinking taskbar buttons, file transfer, chat rooms.
7. An IRC client and an `ircd` with channels and bots in the world.
8. scp; character-mode terminals over ssh and telnet; more providers.

## Pigeon Mail and POP3 (done)

`AgoraMbox` (`kernel/mbox.gd`): mbox parsing and writing shared by
`mail`, `popa3d` and Pigeon (parse, parse_message, field, skin,
display_name, to_text, from_line).

`popa3d` (`system/popa3d.gd`, package `popa3d`, from inetd through tcpd,
port 110): greeting "+OK", USER/PASS with the system password (1 s delay
after a failure, 3 tries), STAT, LIST, UIDL (MD5 of the message), RETR and
TOP with dot-stuffing and CR LF, DELE, RSET, NOOP, LAST, QUIT (deletions
only at QUIT; mail that arrived meanwhile is kept), bare "-ERR" as popa3d
answers; "Authentication passed/failed for USER" to daemon.

`AgoraMailNet` (`system/mail_net.gd`): `pop3_fetch` (UIDL, RETR, DELE
unless kept; skips seen UIDLs) and `smtp_send` (HELO, MAIL, RCPT, DATA),
with Outlook Express-like error texts.

`pigeon` (`gui/apps/pigeon.gd`, package `pigeon` in the desktop profile,
menu "Pigeon Mail"): toolbar (New Mail, Reply, Reply All, Forward,
Delete, Send/Recv, Accounts), folders Inbox/Sent/Drafts/Trash as mbox
files in `~/Mail` (unread = no R in Status; bold, counts on the folder),
message list (From, Subject, Received from the From line), reading pane
(headers, text; text/html through AgoraHtmlView), compose windows (To,
Cc, Subject, body; Send, Save Draft; reply quotes "----- Original Message
-----" and "> "), automatic checks every N minutes. Account in
`~/.pigeon/account` (0600): incoming local (/var/mail/USER moved into the
Inbox) or POP3 (leave a copy, seen UIDLs in `~/.pigeon/uidl`), outgoing
sendmail or SMTP. Not done: MIME (attachments, quoted-printable, base64),
folders of one's own, address book, sorting by column.

Still to do from the mail plan: `fetchmail`; the provider's mail server
in the world (mail.lanlink.net) comes with the several-players step.

## Handoff: mail and a multiplayer internet (next session)

The user asked for two things together. Twice a response in this area was
stopped by a safety classifier before finishing, so keep the work plainly
about running services (mail delivery, accounts, routing) and the tests
about normal use.

Done so far (commit "dns: MX records"): dnsmasq takes
`mx-host=DOMAIN[,HOST[,PREF]]` and answers MX queries; `AgoraWire` encodes MX
rdata (preference + name). Not yet done: `AgoraResolver` has no helper for MX
lookups (use `AgoraResolver.query(p, name, "MX")`, records are
`{type: "MX", data: "10 mail.lanlink.net"}`), dig/host print MX as plain
data.

### 1. Mail (Debian Etch style)

Done (commit "mail: exim4 and bsd-mailx"): `exim4` (`system/exim4.gd`, Exim
4.63, setuid root, service `exim4 -bd -q30m`, in the desktop and server
profiles). Links: sendmail, exim, mailq, runq, newaliases; `update-exim4.conf`
is a no-op because the settings are read directly from
`/etc/exim4/update-exim4.conf.conf` (configtype local/internet/smarthost,
dc_other_hostnames, dc_local_interfaces, dc_relay_nets, dc_smarthost) and
`/etc/mailname`. SMTP server (EHLO/HELO, MAIL, RCPT, DATA with dot
stuffing, RSET, NOOP, VRFY 252, HELP, QUIT; 550 Unrouteable address, 550
relay not permitted, rejectlog), Received:/Message-Id/From/Date like Exim,
spool `-H`/`-D` files, routers dnslookup (MX, then A, DNS only)/smarthost/
nonlocal, system_aliases (`/etc/aliases`), userforward (`~/.forward`),
local_user (`/var/mail/USER`, mbox, USER:mail 0660), mail4root
(`/var/mail/mail`). An SMTP client with per-domain batches, defer and retry
(queue runs; give up after 4 days of game time), bounces with Exim's text,
frozen double bounces, `mailq`, `-q`, `-M`, `-Mrm`, `-bt`, mainlog lines
(`<=`, `=>`, `**`, `==`, `Completed`). Delivery after submission runs in
the background (`exim4 -Mc ID`). Accounts `mail` (8) and `Debian-exim` (101).
`mail` (`kernel/bin/mail.gd`, bsd-mailx 8.1.2, package `bsd-mailx`,
`/etc/mail.rc`): sending (-s, -c, -b; Subject/Cc prompts and ~ escapes on a
terminal) and reading (header list, `&` commands: number, Enter, p, n, -, d,
u, h, f, pre, s, r, R, m, q, x, ?; -f, -u, -e, -N; ~/mbox, Status lines,
mail arriving meanwhile is kept). `printf` was added to coreutils.

Not done in mail: pipes and files in aliases/.forward, Exim's retry
database (every queue run retries everything), delay warnings, SMTP AUTH,
dot-locking, `mail`'s paging (crt).

Still to do:

- `fetchmail` (simple): `~/.fetchmailrc` (`poll HOST protocol pop3 user U
  password P`), fetches over POP3, hands messages to the local sendmail.
- fetchmail on request (not in the profiles); POP3 is done (see Pigeon
  Mail above).

### 2. The internet for several players

The world must later host several players, each with a home (PC + router)
on the same provider. Needed and to be tested:

- A customer-side switch between `isp:eth1` and the homes (today the one
  home router is cabled straight to `isp:eth1`).
- `AgoraWorld` API to add a player's home at run time: create boxes from a
  small spec (`AgoraBoxSpec` pc + router), cable them to a free customer port,
  power them on; and to remove one. Names like `home-<player>-pc`.
- A provider mail server box (`mail.lanlink.net`, 198.51.100.25 on the
  backbone switch, MX for lanlink.net in the ISP's dnsmasq) and a mailbox
  account for each player, created when the home is added.
- Tests with two or three homes at once: each router gets its own address
  from the ISP's DHCP; all browse and use FTP/HTTP at the same time; a home
  can't reach another home's LAN (NAT); players mail each other through
  mail.lanlink.net; adding and removing a home while the world runs; saving
  and loading a world with several homes.

Next in the plan after these: scp, remote raw terminals (ssh/telnet
character mode), a bigger net with more providers.

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
