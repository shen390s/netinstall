#!/bin/sh
# net.sh — network bring-up helpers (stage0-netboot-image).
#
# Pure command generators: they emit the shell commands that bring an interface
# up via DHCP or a static configuration, and never execute them. This keeps the
# side-effecting `ip`/`udhcpc` invocations isolated and unit-testable via a
# generated-command check.
#
# The `network` config object from DeploymentConfig maps onto the arguments of
# net_commands as follows:
#
#     net_commands <iface> <network.mode> [network.ipv4] [network.gateway] [network.dns]
#
#   - mode "dhcp":   ipv4/gateway/dns are ignored.
#   - mode "static": ipv4 and gateway are required; dns is optional.
#
# All functions are POSIX sh (busybox ash compatible); no bashisms.

# net_commands <iface> <mode> [ipv4] [gateway] [dns]
# Emit the bring-up commands for <iface>. Returns 0 on success, 1 on invalid or
# incomplete input.
net_commands() {
    _iface=${1:-}
    _mode=${2:-}
    if [ -z "$_iface" ] || [ -z "$_mode" ]; then
        return 1
    fi
    case "$_mode" in
        dhcp)   net_commands_dhcp "$_iface" ;;
        static) net_commands_static "$_iface" "${3:-}" "${4:-}" "${5:-}" ;;
        *)      return 1 ;;
    esac
}

# net_commands_dhcp <iface>
# Emit the commands to obtain a lease over DHCP on <iface>.
net_commands_dhcp() {
    _iface=${1:-}
    [ -n "$_iface" ] || return 1
    printf 'ip link set %s up\n' "$_iface"
    printf 'udhcpc -i %s -f -q -n\n' "$_iface"
}

# net_commands_static <iface> <ipv4> <gateway> [dns]
# Emit the commands to configure <iface> with a static address, default route,
# and (optionally) a resolver.
net_commands_static() {
    _iface=${1:-}
    _ipv4=${2:-}
    _gateway=${3:-}
    _dns=${4:-}
    if [ -z "$_iface" ] || [ -z "$_ipv4" ] || [ -z "$_gateway" ]; then
        return 1
    fi
    printf 'ip addr add %s dev %s\n' "$_ipv4" "$_iface"
    printf 'ip link set %s up\n' "$_iface"
    printf 'ip route add default via %s\n' "$_gateway"
    if [ -n "$_dns" ]; then
        printf 'echo "nameserver %s" > /etc/resolv.conf\n' "$_dns"
    fi
}
