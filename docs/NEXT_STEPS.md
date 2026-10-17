# Next steps: networking

Handoff note for continuing work in a new session.

## Where the project stands

The last commit is `1b2a31d`. Run the tests with
`godot --headless --path . -s tests/run_tests.gd`: there are 281 checks, all green.

Already done: kernel (VFS, users, processes, sh with control flow), GUI (display server, wm, apps), init (systemd by default, sysvinit), hardware (`AgoraHardware`, `AgoraDisk`, `AgoraNic` with cables), packages and profiles (desktop / server / router on busybox), the install CD. See `docs/architecture.md`.

Network today: `kernel/network.gd` (`AgoraNetwork`) is a placeholder. It is a flat ip → machine table with no packets; `ping` and `ssh` use it. Ports: `machine.listen()` / `port_info()`; `sshd` listens on 22. NICs and cables already exist (`AgoraNic.plug`, `hardware.connect_port`), and `ip link` shows carrier.

## Requirements from the user

- The game is accurate and aimed at people who understand networking. Tools must not be oversimplified: behavior and output should match real Linux tools (iproute2, busybox udhcpc/udhcpd and so on).
- Everything is simulated inside Godot. No real sockets and no access to the real network. A "packet" is a GDScript dictionary passed between objects.
- Work in small steps and commit after each one, once the tests are green.

## Plan, in order

1. **Kernel network stack, `AgoraNetStack` (one per machine).**
   - Interfaces from the hardware NICs plus `lo`.
   - State: admin up/down, MTU, IPv4 addresses with prefix.
   - A routing table using longest prefix match.
   - `/proc/net/dev`, `/proc/net/route`; `/sys/class/net/*/operstate` should account for admin state.
2. **L2 delivery over cables.**
   - Ethernet frames `{src, dst, type, payload}` go to the peer NIC; the peer's kernel receives them.
   - ARP: request/reply, cache, `ip neigh`.
   - Broadcast.
3. **iproute2.**
   - `ip addr add/del/show`, `ip link set DEV up/down`, `ip route add/del/show` (default via), `ip neigh`.
   - Output format as in real iproute2. Also `ifconfig` and `route -n`.
4. **ICMP.** echo request/reply, TTL, "Destination Host Unreachable". `ping` with real packets and real output (`-c`, `-i`, statistics with min/avg/max). `traceroute` comes after routing works.
5. **Configuration at boot.**
   - `/etc/network/interfaces` (static / dhcp), `ifup` / `ifdown`.
   - A `networking` service: systemd unit plus an init.d script.
   - `/etc/hosts`, `/etc/resolv.conf`.
6. **Bridge on the router.** `br-lan` over eth1–eth4 with MAC learning (`brctl show` / `bridge fdb`).
7. **DHCP.** Server on the router (udhcpd-style, `/etc/udhcpd.conf`, leases in `/var/lib/misc/udhcpd.leases`), client on the PC (udhcpc-style).
8. **Forwarding and NAT on the router.**
   - `net.ipv4.ip_forward` via `/proc/sys/net/ipv4/ip_forward`.
   - Masquerade from LAN to WAN with a connection-tracking table.
9. **Connections between processes.**
   - Replace the port registry with a socket layer: listen on ip:port, connect.
   - Opening a connection is checked at the packet level (route, ARP, NAT, port state). Data then flows through `AgoraStream`.
   - `ssh` switches to it, and authentication moves into `sshd`.
10. **Retire `AgoraNetwork`** (or keep it as a DNS helper). Update the `ping` / `ssh` tests and add tests for every step above.

Game tools beyond standard administration are designed separately later, as game mechanics that work only with simulation objects.

## Code conventions

- GDScript 4.7. There are no octal literals: write modes in decimal with an octal comment. Don't name members `_set`, `theme`, `load` or `get_script`, because they clash with built-ins.
- Typed variables: when a value comes from a Dictionary or Variant, write `var x: T =` instead of `:=`.
- Programs extend `AgoraProgram`, are registered in `kernel/programs.gd`, and belong to a package in `system/distro.gd`. Router applets go into `BUSYBOX_APPLETS`.
- In tests, wait with `until(cond)` instead of fixed delays. Register machines in `_machines` so they are shut down after the test.
- Commits: author `uxerror`, with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
