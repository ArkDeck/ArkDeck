// Commandless listener facts of one process, for the macOS proof that an HDC
// server already exists. This extracts the kernel's view and nothing more: no
// connect, no spawn, no interpretation. The Rust side classifies addresses.
#include <libproc.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/proc_info.h>
#include <sys/socket.h>

struct arkdeck_listener {
    // AF_INET or AF_INET6 of the local address as the kernel labels it
    // (`insi_vflag`, not the socket family: a dual-stack AF_INET6 socket may
    // hold a plain IPv4 loopback); 0 when it is neither.
    int32_t family;
    // Host byte order.
    uint16_t port;
    // 4 significant bytes for AF_INET, 16 for AF_INET6.
    uint8_t address[16];
};

// Returns how many TCP LISTEN sockets `pid` owns, filling `out` up to
// `capacity` of them; -1 when the descriptor or socket scan failed; -2 when
// the process owns more listeners than `capacity`.
int arkdeck_macos_listening_sockets(pid_t pid, struct arkdeck_listener *out, int capacity) {
    int required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (required <= 0) {
        return -1;
    }
    size_t count = (size_t)required / sizeof(struct proc_fdinfo) + 8;
    struct proc_fdinfo *descriptors = calloc(count, sizeof(struct proc_fdinfo));
    if (descriptors == NULL) {
        return -1;
    }
    int actual = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, descriptors,
                              (int)(count * sizeof(struct proc_fdinfo)));
    if (actual < (int)sizeof(struct proc_fdinfo)) {
        free(descriptors);
        return -1;
    }
    int found = 0;
    size_t returned = (size_t)actual / sizeof(struct proc_fdinfo);
    for (size_t index = 0; index < returned; index++) {
        if (descriptors[index].proc_fdtype != PROX_FDTYPE_SOCKET) {
            continue;
        }
        struct socket_fdinfo info;
        memset(&info, 0, sizeof info);
        if (proc_pidfdinfo(pid, descriptors[index].proc_fd, PROC_PIDFDSOCKETINFO, &info,
                           sizeof info) != (int)sizeof info) {
            continue;
        }
        const struct socket_info *socket = &info.psi;
        if (socket->soi_family != AF_INET && socket->soi_family != AF_INET6) {
            continue;
        }
        if (socket->soi_protocol != IPPROTO_TCP || socket->soi_kind != SOCKINFO_TCP) {
            continue;
        }
        if (socket->soi_proto.pri_tcp.tcpsi_state != TSI_S_LISTEN) {
            continue;
        }
        if (found >= capacity) {
            free(descriptors);
            return -2;
        }
        const struct in_sockinfo *inet = &socket->soi_proto.pri_tcp.tcpsi_ini;
        struct arkdeck_listener *entry = &out[found];
        memset(entry, 0, sizeof *entry);
        entry->port = ntohs((uint16_t)inet->insi_lport);
        uint8_t flags = (uint8_t)inet->insi_vflag;
        if (socket->soi_family == AF_INET || (flags & INI_IPV4) != 0) {
            entry->family = AF_INET;
            memcpy(entry->address, &inet->insi_laddr.ina_46.i46a_addr4, 4);
        } else if ((flags & INI_IPV6) != 0 || flags == 0) {
            entry->family = AF_INET6;
            memcpy(entry->address, &inet->insi_laddr.ina_6, 16);
        } else {
            entry->family = 0;
        }
        found += 1;
    }
    free(descriptors);
    return found;
}
