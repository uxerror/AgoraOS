# Roadmap

What is done, what is being worked on, and what comes next. The order of the
queue is the project owner's; change it here when it changes. When a step is
done, move it to [Done](#done) with its commits, and record what was left out
in [simplifications](reference/simplifications.md).

Current state: 1258 checks in the test suite, all green.

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
| Chat | IRC: ircd (hybrid 7.0 style), ircbot, the Parley client; irc.lanlink.net with LanHelp and tux in the home world | `9f968a4` |
| Messenger | Ping!: file transfer through the server, chat rooms | `423b0bb` |
| Messenger | Ping!: sounds, an icon in the panel's notification area, blinking conversations; urgent windows and the tray in the display | `fd4fdec` |
| Hardware | A sound card: /dev/dsp, play, sounds in the demo | `396c519` |
| Web | Kestrel: floating images, rowspan, frames | `67e3837` |
| Mail | Pigeon Mail: MIME attachments in and out, folders of one's own, an address book, sorting by column | `3247c55` |
| World | Homes for several players: the customer switch, add_home and remove_home, a mailbox each | `34fd89e` |
| Mail | The provider's mail server mail.lanlink.net, MX for lanlink.net; MX in host and nslookup | `f3cc6bd` |
| Mail | fetchmail: POP3 into the local MTA, keep and UIDLs, the daemon | `c2f4b40` |
| 3D | Sounds of the hardware; thin coax from the cable box | `0c1d4ad` |
| Hardware | Console cables between serial ports, minicom, serial line speeds; the cable in 3D | `bc172ad` |
| 3D | The media lying on a desk are saved with the world | `f1de462` |
| 3D | The cable box: patch cables, crimping one's own, new plugs, the tester | `aa6fec3` |
| 3D | The hub, BNC cards, T-connectors, terminators and thin coax in 3D | `1c93372` |
| 3D | Places: the boxes of one place together, cables plug to plug, a rack | `b658333` |
| Hardware | Hubs (one collision domain), thin coax (10BASE2) with T-connectors and terminators, NE2000 cards with BNC | `0385a07` |
| 3D | The inside from the machine's data, the server's interior, parts described under the mouse | `68158ed` |
| Boot | Clear-CMOS jumper and battery in the 3D view | `2db53e9` |
| Boot | `date -s`, `hwclock`, `grub-md5-crypt`, update-grub from the kernel package | `9a5c802` |
| Boot | BIOS: POST, Setup, F12 menu, passwords; GRUB's menu, editor, command line; the router's CFE | `e75b418` |
| Boot | GRUB 0.97 in the boot sector, menu.lst, grub-install, update-grub | `8d70ee3` |
| Boot | Kernel command line, `/proc/cmdline`, single-user mode, sulogin, remount | `239a112` |
| 3D | The hardware in 3D, live and handled with the mouse; the models | `89d99ad`, `e2c2e6a` |
| Packages | apkg: packages of one's own (apkg-build, apkg-scanpackages, maintainer scripts) | `3965aa9` |
| Packages | apkg: upgrades, downgrades, holds, conffiles, Provides, Conflicts | `366178e` |
| Packages | apkg: archives on the net, as apt does it | `0d7b711` |
| Mail | Pigeon Mail; popa3d | `716ae7f` |
| Web | Kestrel Navigator, GIF pictures, copying text | `4098335`, `3846a72` |
| Messenger | Ping! Messenger and pingd; Ping! Networks in the home world | `d464e80`, `8bc0b2a` |
| Mail | exim4 and bsd-mailx; MX records | `0d0b656`, `145a38d` |
| World | The home world's internet; Ferret the search engine | `bda0b73`, `9a62ad9` |
| Web | apache2 with virtual hosts, UserDir, CGI; wget; lynx | `b495458`, `9d445b3`, `f2cfb06` |
| Services | FTP (in.ftpd, ftp); telnet, inetd, tcp_wrappers | `ce96ea9`, `c36f89a`, `36af571` |
| Hardware | Physical layer: cable timing, bit errors, negotiation, duplex, ethtool; the unmanaged switch | `5907780`, `0bf6d5b`, `0fdc183`, `359beea` |
| World | Worlds: AgoraWorld, world specs (resources), the demo desk, project folders onto disks | `ab39b65`, `60b1aed`, `754b6c5`, `1ca7000` |
| Networking | tcpdump and packet sockets | `789c86c` |
| Networking | Resolver, dnsmasq, BIND tools | `65615ed`, `57c0208` |
| Networking | TCP segments, retransmission; ssh, nc, netstat | `3c96d4e`, `968b540` |
| Networking | Forwarding, sysctl, traceroute; netfilter, conntrack, iptables; NAT and the router firewall | `8887371`, `b6d1fc9`, `75db451` |
| Networking | UDP and DHCP (udhcpc, udhcpd) | `738f433` |
| Networking | Bridges, brctl, bridge; the router's br-lan | `2a48ddb` |
| Networking | ifupdown, the networking service, /etc/hosts, the installer's network question | `c5a9a2c` |
| Networking | ICMP and ping | `3e38df1` |
| Networking | ip, ifconfig, route, arp | `5fdfe31` |
| Networking | Ethernet frames over cables, ARP | `15f9efb` |
| Networking | The network stack: interfaces, addresses, routes, /proc/net, /sys/class/net | `11146c7` |
| Base | Kernel, VFS, processes, shell, coreutils; GUI (display server, wm, apps); init (systemd, sysvinit); hardware; packages and profiles; the install CD | |

The first rows (Base) predate this table; `git log` has them.
