# Roadmap

What is done, what is being worked on, and what comes next. The order of the
queue is the project owner's; change it here when it changes. When a step is
done, move it to [Done](#done) with its commits, and record what was left out
in [simplifications](reference/simplifications.md).

Current state: 1116 checks in the test suite, all green.

## Now: the 3D view of the hardware

All six steps are done (models, the live view, handling the box, the inside,
places with cables between boxes, the rack, hubs and thin coax, the cable box; see
[hardware](architecture/hardware.md#the-3d-view)). The rack, the hub and the
BNC parts are made from plain shapes in code until the owner's .glb models
replace them (same names: `hub_hb108`, `bnc_t`, `bnc_terminator`; a BNC card
model `card_ne2k` with its socket node named `bnc`).

Left in this area: save the media lying on the desk with the world; the serial
console in 3D (the router's UART header, the console cable); sounds (fans, the
disk, the CRT); thin coax pieces and T-connectors in the cable box.

## Next

In this order, unless the owner says otherwise.

1. **Mail: fetchmail.** `~/.fetchmailrc` (`poll HOST protocol pop3 user U
   password P`), fetches over POP3 and hands messages to the local sendmail.
   Not in the profiles (on request).
2. **The provider's mail server.** `mail.lanlink.net` in the home world
   (198.51.100.25 on the backbone switch): exim4 "internet" with relaying for
   LanLink's customers, popa3d, MX for lanlink.net in the ISP's dnsmasq, a
   mailbox per player. dnsmasq already answers MX (`mx-host=`) and `AgoraWire`
   encodes it; `AgoraResolver` has no MX helper yet (use
   `AgoraResolver.query(p, name, "MX")`, records are `{type: "MX", data: "10
   mail.lanlink.net"}`), and dig/host print MX as plain data.
3. **The internet for several players.** Each player gets a home (PC + router)
   on the same provider:
   - a customer switch between `isp:eth1` and the homes (today the one router
     is cabled straight to `isp:eth1`);
   - `AgoraWorld` API to add and remove a home at run time (boxes from a small
     spec, cabled to a free customer port, powered on; names like
     `home-<player>-pc`), with a mailbox on mail.lanlink.net for each player;
   - tests with two or three homes at once: each router gets its own address
     from the ISP's DHCP; all browse and use FTP/HTTP at the same time; a home
     can't reach another home's LAN (NAT); players mail each other; adding and
     removing a home while the world runs; saving and loading such a world.
4. **Pigeon Mail**: MIME (attachments, quoted-printable, base64, multipart),
   folders of one's own, an address book, sorting by column.
5. **Kestrel**: floating images (`<img align>`), rowspan, frames.
6. **Ping!**: sounds (the display has no audio yet), a notifier in the panel,
   blinking taskbar buttons, file transfer, chat rooms.
7. **IRC**: a client and an `ircd` with channels and bots in the world.
8. **Remote work**: `scp`; character-mode terminals over ssh and telnet (so
   full-screen programs work remotely); more providers and a bigger net.

Note for whoever implements 2 and 3: responses in this area were twice stopped
by a safety classifier before finishing. Keep the work and the tests plainly
about running services (mail delivery, accounts, routing) and normal use.

## Later

Ideas, not ordered.

- **Firmware**: lilo as an alternative boot loader; GRUB's `lock`,
  `configfile`, `chainloader`; partitions (`fdisk`) so disks have more than one.
- **Kernel and shell**: job control (`fg`, `bg`), here-documents, `set -e`;
  hard links, file locking, quotas; disk capacity limits.
- **Networking**: a BIND-style authoritative server with zone files; DNS over
  TCP; IPv6; fragmentation and MTU; STP; TCP congestion and flow control;
  `tcpdump -w`/`-r` (pcap files from `AgoraWire` bytes), `-vv` DHCP options,
  byte offsets in filters; an FTP conntrack helper.
- **Physical layer**: 90s-2000s media (coax 10BASE2, hubs, shared collision
  domains, modems); keep the cable model open to other media.
- **Services**: inetd internal and UDP services; tcpd host names, spawn/twist;
  busybox telnetd on the router; telnet's escape prompt; FTP REST, APPE, MDTM,
  STAT, ABOR; apache keep-alive, .htaccess, auth; mail aliases with pipes and
  files, a retry database, delay warnings, SMTP AUTH.
- **Packages**: signed archives (Release.gpg; apt-secure came in 2005),
  lintian-style checks in apkg-build, a web page per archive, triggers.
- **Worlds**: a visual editor for world specs (place boxes, draw cables);
  cables moved at run time from the bar.
- **Installer**: a graphical installer.
- **Ping!**: a terminal client, bots on the server, authorization requests.
- **Game**: mechanics that only work with simulation objects are designed
  separately, in the game.

## Done

Newest first. Each line is a step with its main commits; the chapters describe
the result.

| Area | What | Commits |
|---|---|---|
| 3D | The cable box: patch cables, crimping one's own, new plugs, the tester | `d3a3b26` |
| 3D | The hub, BNC cards, T-connectors, terminators and thin coax in 3D | `4110a21` |
| 3D | Places: the boxes of one place together, cables plug to plug, a rack | `3e898d1` |
| Hardware | Hubs (one collision domain), thin coax (10BASE2) with T-connectors and terminators, NE2000 cards with BNC | `cf3ea14` |
| 3D | The inside from the machine's data, the server's interior, parts described under the mouse | `5ac9271` |
| Boot | Clear-CMOS jumper and battery in the 3D view | `3e1a475` |
| Boot | `date -s`, `hwclock`, `grub-md5-crypt`, update-grub from the kernel package | `3cd32f9` |
| Boot | BIOS: POST, Setup, F12 menu, passwords; GRUB's menu, editor, command line; the router's CFE | `60d7641` |
| Boot | GRUB 0.97 in the boot sector, menu.lst, grub-install, update-grub | `217af83` |
| Boot | Kernel command line, `/proc/cmdline`, single-user mode, sulogin, remount | `d5dfe41` |
| 3D | The hardware in 3D, live and handled with the mouse; the models | `edab15c`, `54b05b8` |
| Packages | apkg: packages of one's own (apkg-build, apkg-scanpackages, maintainer scripts) | `14bec79` |
| Packages | apkg: upgrades, downgrades, holds, conffiles, Provides, Conflicts | `455ec2a` |
| Packages | apkg: archives on the net, as apt does it | `a427ede` |
| Mail | Pigeon Mail; popa3d | `972ee11` |
| Web | Kestrel Navigator, GIF pictures, copying text | `03f3a1c`, `74c66f5` |
| Messenger | Ping! Messenger and pingd; Ping! Networks in the home world | `fbf3b3a`, `6842173` |
| Mail | exim4 and bsd-mailx; MX records | `26da820`, `4086447` |
| World | The home world's internet; Ferret the search engine | `57cef8e`, `3d4eb16` |
| Web | apache2 with virtual hosts, UserDir, CGI; wget; lynx | `24db220`, `06b2b53`, `5453447` |
| Services | FTP (in.ftpd, ftp); telnet, inetd, tcp_wrappers | `e9cb89f`, `07b5a59`, `e6a1c7d` |
| Hardware | Physical layer: cable timing, bit errors, negotiation, duplex, ethtool; the unmanaged switch | `b355c64`, `c51e5b8`, `cd848e4`, `c0b5d3e` |
| World | Worlds: AgoraWorld, world specs (resources), the demo desk, project folders onto disks | `1559fcc`, `7240451`, `84179e6`, `ab9de39` |
| Networking | tcpdump and packet sockets | `e7ab011` |
| Networking | Resolver, dnsmasq, BIND tools | `17ce2e1`, `cf18986` |
| Networking | TCP segments, retransmission; ssh, nc, netstat | `c256c98`, `adfe6e3` |
| Networking | Forwarding, sysctl, traceroute; netfilter, conntrack, iptables; NAT and the router firewall | `7f09302`, `79f044b`, `5567167` |
| Networking | UDP and DHCP (udhcpc, udhcpd) | `ae63e52` |
| Networking | Bridges, brctl, bridge; the router's br-lan | `4bf4f10` |
| Networking | ifupdown, the networking service, /etc/hosts, the installer's network question | `04bc869` |
| Networking | ICMP and ping | `b0c36e2` |
| Networking | ip, ifconfig, route, arp | `426edd2` |
| Networking | Ethernet frames over cables, ARP | `c5227c7` |
| Networking | The network stack: interfaces, addresses, routes, /proc/net, /sys/class/net | `52b8bb5` |
| Base | Kernel, VFS, processes, shell, coreutils; GUI (display server, wm, apps); init (systemd, sysvinit); hardware; packages and profiles; the install CD | |

The first rows (Base) predate this table; `git log` has them.
