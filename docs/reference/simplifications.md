# Simplifications and gaps

Where the simulation is knowingly simpler than the real thing. Gaps that are
planned work are also in the [roadmap](../ROADMAP.md); this page is the place
to look before assuming a behaviour.

## Kernel and shell

- Password hashes in `/etc/shadow` are `$5$salt$sha256hex`, not crypt(3)'s
  SHA-256 (GRUB's `$1$` MD5-crypt is the real one).
- No job control (`fg`, `bg`), here-documents or `set -e` in `sh`.
- No hard links, file locking or quotas. Disk capacity is shown, not enforced.
- `/etc/profile` sets the PATH; root's includes the sbin directories.

## Hardware and firmware

- One partition per disk, so GRUB knows `(hdN,0)` only.
- GRUB: TAB completes command names only; no `lock`, `configfile`,
  `chainloader` or `md5crypt` command; `savedefault` is accepted and does
  nothing.
- BIOS: the IDE/SCSI list in POST and Setup is shown, not settable; Halt On is
  shown only; no LAN boot (PXE); no LS-120 or floppy drives.
- The router's CFE has no prompt (Ctrl+C in raw mode interrupts instead of
  sending ^C).
- No lilo.

## Networking

- Hubs can't be cascaded (a cable between two hubs gives no link); the 5-4-3
  rule isn't checked. On thin coax the minimum distance between T-connectors
  and the 30-station limit aren't checked, and the propagation is taken across
  the whole bus, not between the two stations.
- TCP has retransmission and Nagle but no congestion or flow control (the
  window is always 65535), no delayed ACKs and no out-of-order queue (a gap is
  answered with a duplicate ACK and filled by the retransmission).
- At 100 Mbit/s the simulated hosts emit a segment only every few ms, so the
  wire is mostly idle and collisions are rare; at 10 Mbit/s they are plentiful.
- DNS is UDP only, with no zones or SOA records: dnsmasq serves `/etc/hosts`
  and forwards. `iptables` resolves host names from `/etc/hosts` only.
- No IPv6, no fragmentation (the MTU is shown but not enforced), no STP (`stp
  on` is accepted and does nothing).
- The ssh "protocol" inside the connection is plain text lines (`AUTH`,
  `SHELL`, `EXEC`, then base64 channel messages), not encrypted.
- Timers: DHCP leases and cron follow the game clock; ARP, retransmission and
  conntrack follow real time.
- No FTP conntrack helper: active FTP through NAT fails (as on a real NAT
  without nf_conntrack_ftp), passive works.
- tcpdump: no `-w`/`-r`, no `-vv` decoding of DHCP options, no `tcp[13]`-style
  byte offsets in filters.

## Services

- A console cable joins the far box's console to a terminal program here;
  this box's own getty on ttyS0 isn't part of the line (no "getty wars"), and
  there is no flow control, parity or stty on serial lines.

- inetd: no internal services (echo, daytime...), no UDP or `wait` services.
  tcpd: no host name patterns, no spawn/twist.
- telnet: no escape prompt (^]) or `-l`; no busybox telnetd on the router.
  Remote raw mode over ssh or telnet isn't there (lynx works locally, and
  through `ssh host lynx` only line by line).
- FTP: no REST, APPE, MDTM, STAT, ABOR; no globbing in the server's LIST.
- apache2: no keep-alive, .htaccess, authentication, mod_rewrite or PHP.
- Mail: no pipes or files in aliases and .forward, no retry database (every
  queue run retries everything), no delay warnings, no SMTP AUTH, no
  dot-locking, no paging in `mail`. Pigeon saves attachments to the home
  folder only (no file dialog), drafts keep their attachments but not a
  signature or a format; no HTML mail is written. fetchmail speaks POP3 only (no IMAP, ETRN, SSL), always
  delivers by SMTP to localhost (no `mda`, `smtphost`, multidrop).

## Packages

- Native programs can't be built into packages of one's own (packages may carry
  shell scripts, data, or copies of existing program stubs).
- No signed archives (Release.gpg), no triggers.

## Graphics

- The browser engine has no CSS or JavaScript, no `<table align>` floats and
  no `<iframe>`. Frames can't be resized by dragging; Back and Forward go by
  whole documents, not by frame; Save As, View Source and Find act on the
  frameset document.
- The display has no audio.
- Media taken out of a drive in the 3D view stay on that box's desk and are not
  saved with the world yet.
