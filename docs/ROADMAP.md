# Roadmap

What is done, what is being worked on, and what comes next. The order of the
queue is the project owner's; change it here when it changes. When a step is
done, move it to [Done](#done) with its commits, and record what was left out
in [simplifications](reference/simplifications.md).

Current state: 1257 checks in the test suite, all green.

## Now: the apps

The provider's side is done: its mail server and players' homes (see
[Done](#done)). The queue goes on with the apps.

## Next

In this order, unless the owner says otherwise.

1. **Remote work**: `scp`; character-mode terminals over ssh and telnet (so
   full-screen programs work remotely); more providers and a bigger net.

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
- **3D**: real models for the rack, the hub and the BNC parts; hubs cascaded;
  the inside of the router (its UART header); a keyboard and a screen in 3D
  for the servers in the rack (a KVM).
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
| Chat | IRC: ircd (hybrid 7.0 style), ircbot, the Parley client; irc.lanlink.net with LanHelp and tux in the home world | |
| Messenger | Ping!: file transfer through the server, chat rooms | `7a7b8e2` |
| Messenger | Ping!: sounds, an icon in the panel's notification area, blinking conversations; urgent windows and the tray in the display | `25709d4` |
| Hardware | A sound card: /dev/dsp, play, sounds in the demo | `ce2117f` |
| Web | Kestrel: floating images, rowspan, frames | `43ccd5a` |
| Mail | Pigeon Mail: MIME attachments in and out, folders of one's own, an address book, sorting by column | `a3cd2b4` |
| World | Homes for several players: the customer switch, add_home and remove_home, a mailbox each | `0338b21` |
| Mail | The provider's mail server mail.lanlink.net, MX for lanlink.net; MX in host and nslookup | `39ec141` |
| Mail | fetchmail: POP3 into the local MTA, keep and UIDLs, the daemon | `e25a3b0` |
| 3D | Sounds of the hardware; thin coax from the cable box | `d675911` |
| Hardware | Console cables between serial ports, minicom, serial line speeds; the cable in 3D | `8574215` |
| 3D | The media lying on a desk are saved with the world | `28dd0ec` |
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
