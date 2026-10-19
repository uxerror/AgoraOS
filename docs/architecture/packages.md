# Packages and the installer

## The distribution

`AgoraDistro` (`system/distro.gd`) defines every package: a dictionary of
directories, files (text, or base64 for binary data), programs (native
binaries), symlinks, conffiles, system users, inetd lines and maintainer
scripts. It also defines the profiles:

| Profile | For |
|---|---|
| `desktop` | everything, with the graphical desktop and the apps |
| `server` | the same without graphics, plus inetd |
| `router` | busybox, router configuration, dnsmasq, openssh |
| `live` | the install CD |

The [programs reference](../reference/programs.md) lists every package and
program; regenerate it with `tools/gen_docs.gd`.

`AgoraPackages` (`system/packages.gd`) installs a package onto any VFS and
keeps `/var/lib/apkg/{installed,info/}`. Install, upgrade and downgrade happen
in place: files the new version lacks are removed; configuration files
(everything under `/etc`, or listed in conffiles) are handled as dpkg does, by
the MD5 recorded at install time: an untouched one is replaced, one changed by
the user stays and the new one lands as `FILE.dpkg-dist` (or, if the user
answers Y, the new one goes in and the old is kept as `FILE.dpkg-old`), one the
user deleted stays deleted.

## busybox

On the router `/bin/busybox` is one setuid binary and every applet is a link to
it. The name it runs under picks the applet; applets other than su, passwd and
crontab drop the setuid privilege. An applet can check `multicall ==
"busybox"` to print busybox's format.

## Archives

`AgoraArchive` (`system/archive.gd`) lays archives out like Debian's:
`BASE/dists/SUITE/COMPONENT/Packages` (stanzas: Package, Version,
Architecture, Maintainer, Depends, Size, MD5sum, Filename, Description),
`BASE/dists/SUITE/Release`, `BASE/pool/COMPONENT/L/NAME/NAME_VERSION.pkg`.
`compare_versions()` works as dpkg (epoch, upstream, revision, `~` first,
letters before symbols); `satisfies()` takes `>=`, `<=`, `>>`, `<<`, `=`.
`AgoraFetch` downloads `file:`, `http:` and anonymous passive `ftp:` URLs with
apt's error texts.

## apkg

`apkg` (apt-get 0.5 style output):

- `/etc/apkg/sources.list` (`apkg URI SUITE COMPONENT...`, `deb` accepted);
  the default source is `http://ftp.agoraos.org/agora`.
- `update` (Get/Hit/Err; indexes in `/var/lib/apkg/lists`), `install [-y]
  NAME[=VERSION]` (newest version, dependencies with alternatives and version
  constraints, the "extra" and "NEW" lists, a question on a terminal, download
  to `/var/cache/apkg/archives`, size and MD5 checked against the index, dpkg's
  Selecting/Unpacking/Setting up), `install FILE.pkg`, `remove` (keeps the
  conffiles, state "config-files"), `purge`, `upgrade` (held packages and those
  needing new ones are kept back), `dist-upgrade`, `search`, `show`, `policy`,
  `list [--available|--upgradable]`, `info`, `files`, `hold`/`unhold`, `clean`.
- Provides (virtual packages) and Conflicts (the other package is removed).
- The conffile question (Y/I/N/O, default N; without a terminal or with `-y`
  the user's file stays).
- Errors and exit code 100 as apt; "are you root?" for others.

Maintainer scripts run as dpkg runs them, through `/bin/sh` with
`APKG_MAINTSCRIPT_PACKAGE` and `APKG_MAINTSCRIPT_NAME`. Install: preinst
install, unpack, postinst configure. Upgrade: old prerm upgrade NEW, new
preinst upgrade OLD, unpack, old postrm upgrade NEW, new postinst configure
OLD. Remove: prerm remove, postrm remove; purge: postrm purge. Scripts are kept
in `/var/lib/apkg/info/NAME.SCRIPT`. A failing preinst or prerm stops that
package ("dpkg: error processing...", exit 100); a failing postinst leaves it
unpacked. The kernel package's scripts run `update-grub`.

## Packages of one's own

`apkg-build DIR [FILE]` (like `dpkg-deb --build`): DIR holds the tree as it will
lie on the system plus `APKG/control` (Package and Version required; Depends,
Conflicts, Provides, Replaces, Maintainer, Description), `APKG/conffiles` and
the maintainer scripts (modes 0555-0775 or the build fails). Files keep their
modes and are installed owned by root; non-text files go in as base64. Any user
may build; the result is `NAME_VERSION.pkg`. Native programs can't be made
this way.

`apkg-scanpackages [-s SUITE] [-c COMPONENT] [-o ORIGIN] BASE` indexes
`BASE/pool/COMPONENT` into `BASE/dists/SUITE/...`. Serve BASE with apache or
ftpd and add it to sources.list.

## The installer

`AgoraMedia.installer()` builds the install CD (or stick): a live system whose
inittab runs `getty -n -l /sbin/agora-install` on every console, with a whole
archive at its root. `agora-install` asks in text mode for the disk, the
profile, the host name, the root password, a user, the init system and the
network of eth0 (DHCP, static or none), then runs `mkfs`, installs the packages
from the CD's archive, configures the system, installs GRUB, ejects the CD and
reboots.

`AgoraInstaller` does the same from code: `install_disk(disk, hostname, opts)`
(opts: profile, users, root_password, motd, init, packages, network,
nameservers, archive, root_device) and `upgrade_vfs(vfs)`, which brings a
system saved by an older version up to date by installing what its profile now
lacks, keeping local changes. `AgoraMachine.create()` uses it on a virtual box.
