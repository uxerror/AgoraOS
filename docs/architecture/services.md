# Services

The servers and clients of the era, each matching the real program's protocol,
logs and messages. Which package and profile brings each one is in the
[programs reference](../reference/programs.md).

## inetd and tcp_wrappers

`openbsd-inetd` (`system/inetd.gd`) reads `/etc/inetd.conf` and
`/etc/services` (from `netbase`), listens for TCP `nowait` services and starts
the server with the connection on stdin/stdout (`AgoraProcess.socket` set);
SIGHUP rereads the file. Packages register lines (`"inetd": [...]`, like
update-inetd), and apkg sends inetd SIGHUP after installing or removing.
`tcpd` checks `/etc/hosts.allow` and `/etc/hosts.deny` (ALL, addresses,
`a.b.c.` prefixes, addr/mask, LOCAL, EXCEPT) and logs "connect from" /
"refused connect from" to auth.

## Telnet

`in.telnetd` (netkit 0.17, package `telnetd`) negotiates (DO TTYPE, TSPEED,
XDISPLOC, NEW-ENVIRON; SB TTYPE SEND; WILL SGA, DO NAWS), shows
`/etc/issue.net` and runs `login -h client -p` on a pty; WILL/WONT ECHO
follows the pty's echo; IAC IP interrupts; AYT answers. `login` asks for the
name itself (three tries) and logs failures with FROM. The `telnet` client
answers negotiation but never starts it, so it also works as a raw TCP client
(`telnet host 25`); Ctrl+C sends IP. The password is visible in `tcpdump -A`.

## FTP

`in.ftpd` (`system/ftpd.gd`, linux-ftpd 0.17 / OpenBSD ftpd replies) from inetd
through tcpd: USER/PASS (`/etc/ftpusers` refuses root and system accounts;
`anonymous`/`ftp` logs in as the ftp user, locked into its home), SYST, PWD,
CWD/CDUP, TYPE A/I, PORT, PASV, LIST (runs `/bin/ls -lA` as the user), NLST,
RETR, STOR, SIZE, DELE, MKD, RMD, RNFR/RNTO, NOOP, HELP, QUIT. File access uses
the user's credentials. Active mode connects from port 20; passive listens on
an ephemeral port. Logs to daemon ("FTP LOGIN FROM", "ANONYMOUS FTP LOGIN
FROM"...).

The `ftp` client (netkit 0.17) logs in by itself (Name/Password prompts),
switches to binary after "UNIX Type: L8", and has open, user, ls/dir, nlist,
cd, cdup, pwd, get/recv, put/send, mget, mput, delete, mkdir, rmdir, rename,
size, system, ascii/binary/type, passive, verbose, lcd, status, help, close,
bye/quit; `-p`, `-n`, `-v`. Binary transfers are byte-exact. Behind NAT use
passive (`ftp -p`): an active data connection gets the server's 425.

## The web

`apache2` (`system/apache2.gd`, Apache 2.2.3 as Debian ships it) reads
`apache2.conf` and its Includes (ports.conf, conf.d/, sites-enabled/): Listen,
User, ServerName, DocumentRoot, DirectoryIndex, ScriptAlias, Alias, ErrorLog,
CustomLog, ServerTokens, ServerSignature, IndexIgnore, Options per
`<Directory>` (Indexes), name-based virtual hosts, UserDir and `AddHandler
cgi-script`. One request per connection, HTTP/0.9 to 1.1, GET/HEAD/POST, 501
for the rest. Files are read as www-data. Directories without a slash get a 301,
then DirectoryIndex, an autoindex listing or 403. CGI with the CGI/1.1
environment, the body on stdin, Status/Location/Content-Type headers, and
Apache's 500s ("Premature end of script headers"). access.log in the combined
format, error.log with Apache's messages and error pages.

Clients: `wget` 1.10.2 (the log on stderr, `-O`, `-q`, `-S`, `-U`,
`--post-data`, `-T`, redirects, `index.html.1`); `lynx` 2.8.5 full screen in raw
mode (links, history, paging, `/` search, `\` source, `g`, forms with fields,
buttons, checkboxes, radios and selects), `-dump` with references, `-source`,
`-head` (`AgoraHtml` lays HTML out as Lynx does, `AgoraHttp` fetches URLs);
Kestrel Navigator, the graphical browser (see [graphics](gui.md)).

## Mail

- **exim4** (`system/exim4.gd`, Exim 4.63, setuid root, service `exim4 -bd
  -q30m`). Links: sendmail, exim, mailq, runq, newaliases. Settings come from
  `/etc/exim4/update-exim4.conf.conf` (configtype local/internet/smarthost,
  dc_other_hostnames, dc_local_interfaces, dc_relay_nets, dc_smarthost) and
  `/etc/mailname`; `update-exim4.conf` is a no-op. The SMTP server (EHLO/HELO,
  MAIL, RCPT, DATA, RSET, NOOP, VRFY 252, HELP, QUIT; "550 Unrouteable
  address", "550 relay not permitted", rejectlog), Received:/Message-Id/From/
  Date as Exim writes them, spool `-H`/`-D` files, the routers dnslookup (MX,
  then A), smarthost, system_aliases (`/etc/aliases`), userforward
  (`~/.forward`) and local_user (`/var/mail/USER`). An SMTP client with
  per-domain batches, defer and retry (give up after 4 days of game time),
  bounces, frozen double bounces, `mailq`, `-q`, `-M`, `-Mrm`, `-bt`, and
  mainlog lines (`<=`, `=>`, `**`, `==`, `Completed`).
- **mail** (bsd-mailx 8.1.2): sending (`-s`, `-c`, `-b`, prompts and `~`
  escapes on a terminal) and reading (header list, the `&` commands, `-f`,
  `-u`, `-e`, `-N`, `~/mbox`, Status lines).
- **popa3d** (POP3, port 110, from inetd): USER/PASS with the system password
  (1 s delay after a failure, 3 tries), STAT, LIST, UIDL, RETR, TOP, DELE, RSET,
  NOOP, LAST, QUIT; deletions only at QUIT.
- **fetchmail** 6.3.6 (package `fetchmail`, on request): `~/.fetchmailrc` (no
  more than 0700; `poll HOST protocol pop3 user U password P`, `keep`,
  `fetchall`, `set daemon N`, the noise words), each message handed to the
  local MTA by SMTP on localhost:25 with fetchmail's Received: line; `keep`
  remembers UIDLs in `~/.fetchids`. `-c`, `-v` (the POP3 dialogue, `PASS *`),
  `-k`, `-K`, `-a`, `-u`, `-f`, `-d N` (a daemon logging to syslog, woken by
  another run), `-q`; exit statuses 0, 1 (no mail), 2 (socket), 3 (auth), 5,
  10 (SMTP), 13.
- **Pigeon Mail**, the graphical client (see [graphics](gui.md)).
  `AgoraMailNet` has `pop3_fetch` and `smtp_send`; `AgoraMbox` parses and
  writes mbox files for all of them.
- dnsmasq answers MX records (`mx-host=`).

## Ping! Messenger

An ICQ-style messenger of our own. `AgoraPing` (`system/ping_proto.gd`) is the
protocol, PingNet/1.0: text lines over TCP 5190 (`pingnet` in /etc/services);
REGISTER, LOGIN, STATUS, ADD, DEL, MSG, INFO, SEARCH, NICK, NOP, BYE; the server
sends CONTACT, PRESENCE, MSG, OFFLINE, KICKED, ERROR. Files go through the
server to someone online (FILE, ACCEPT/DECLINE, DATA in base64 lines, DONE; at
most 1 MB); chat rooms "#name" are made by the first one in and gone with the
last (JOIN, PART, SAY, ROOMS; JOINED, MEMBER, PARTED, SAID); leaving the
network leaves every room. Statuses: online, ffc,
away, na, occupied, dnd, invisible.

`pingd` (service, package `pingd`): `/etc/pingd.conf` (name, port, first_uin,
register), accounts in `/var/lib/pingd/accounts` (`uin:hash:nick:contacts`,
`!` locks one), offline messages in `/var/lib/pingd/offline/UIN`; a second login
kicks the first. `AgoraPingClient` is the client side; the `pingmsg` app is in
[graphics](gui.md).

## IRC

`AgoraIrc` (`system/irc_proto.gd`) takes RFC 1459 lines apart; TCP 6667.

- `ircd` (service `ircd-hybrid`, package `ircd-hybrid`, on request), after
  ircd-hybrid 7.0.3. It reads `serverinfo { name, description, network_name }`,
  `listen { port }` and `admin { email }` from `/etc/ircd-hybrid/ircd.conf`
  (other blocks are ignored) and sends `/etc/ircd-hybrid/ircd.motd`.
  - Clients register with NICK and USER and get the hostname notices
    (reverse lookups through the resolver), 001-005, LUSERS and the MOTD.
  - Commands: JOIN, PART, PRIVMSG, NOTICE, TOPIC, NAMES, LIST, WHO, WHOIS,
    AWAY, ISON, USERHOST, MODE, KICK, INVITE, MOTD, LUSERS, VERSION, TIME,
    ADMIN, PING and QUIT, with the usual numerics and errors.
  - Channels are `#` and `&`. The first one in is an operator; new
    channels are `+nt`. Channel modes are i, m, n, s and t; members can be
    given +o and +v.
  - A client that is silent for 15 minutes is dropped. Connections are
    logged to daemon.
- `ircbot` (service and package `ircbot`, on request): each
  `/etc/ircbot/*.conf` is a bot with these settings:
  - `server`, `nick`, `user` and `name`;
  - `channel` lines;
  - `topic CHANNEL TEXT`, set when the bot holds the channel;
  - `greet` for whoever joins;
  - `on WORD`, which answers messages starting with WORD, and `hear WORD`,
    which answers messages containing it.

  Answers can use $nick, $channel, $time and $me. Bots answer in channels
  and in private, and connect again a minute after losing the server.
- `AgoraIrcClient` (`system/irc_client.gd`) is the client side. It handles
  registration (a taken nick gets "_" added) and PING. The Parley app is
  described in [graphics](gui.md).

## The search engine

`ferretd` (www.ferret.org in the home world) crawls the seeds in
`/etc/ferret/ferret.conf` and submitted URLs every 30 minutes, honours
robots.txt and writes `/var/lib/ferret/index`. The CGI `/usr/lib/cgi-bin/search`
ranks results (title bonus) ten to a page; `addurl` queues sites.

## Serial consoles

`minicom` 2.1 (package `minicom`, on request) is a terminal on a serial port:
the banner, Ctrl-A Z (the command summary), Ctrl-A X / Q (leave), Ctrl-A C
(clear), Ctrl-A E (local echo), Ctrl-A F (break). With a console cable in the
port it is the console terminal of the box at the other end: that box's
output shows, and typing reaches it as a terminal's line discipline would
(a line at a time with echo while the console is canonical, keys one by one in
raw mode; Ctrl+C interrupts there, not here). `/etc/minicom/minirc.dfl` has the
port and speed (`pu port`, `pu baudrate`); `-D` and `-b` override them. At
another speed than the far console's, its output arrives as line noise and the
keys don't get through. The port needs read and write access (`dialout`).

## Other daemons

`sshd` (see [networking](networking.md#ssh)), `syslogd`, `crond` (see
[boot](boot.md#shared-daemons)), `dnsmasq`, `udhcpd`/`udhcpc`.
