// OS-only control transport primitives. No JSON, Runtime or device semantics.
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

typedef void (*arkdeck_frame_handler)(void *, const void *, size_t, uid_t, pid_t,
                                     void *, void (*)(void *, const void *, size_t));

static int process_info(pid_t pid, uid_t uid, struct proc_bsdinfo *info) {
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, info, sizeof(*info)) == sizeof(*info)
        && info->pbi_pid == (uint32_t)pid && info->pbi_uid == uid
        && info->pbi_pgid > 0 && info->e_tpgid > 0 && info->pbi_pgid == info->e_tpgid
        && info->e_tdev != 0 && info->e_tdev != UINT32_MAX;
}
static int terminal(pid_t pid, int descriptor, uint32_t device) {
    struct vnode_fdinfo info = {0};
    return proc_pidfdinfo(pid, descriptor, PROC_PIDFDVNODEINFO, &info, sizeof(info)) == sizeof(info)
        && (info.pvi.vi_stat.vst_mode & S_IFMT) == S_IFCHR
        && info.pvi.vi_stat.vst_rdev == device;
}
int arkdeck_origin(int fd, uid_t *uid, pid_t *pid) {
    gid_t gid;
    socklen_t size = sizeof(*pid);
    *pid = 0;
    if (getpeereid(fd, uid, &gid) || *uid != geteuid()) return -1;
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, pid, &size) || size != sizeof(*pid)
        || *pid <= 1 || *pid == getpid()) return 0;
    struct proc_bsdinfo before = {0}, after = {0};
    return process_info(*pid, *uid, &before)
        && terminal(*pid, STDIN_FILENO, before.e_tdev)
        && terminal(*pid, STDERR_FILENO, before.e_tdev)
        && process_info(*pid, *uid, &after)
        && before.pbi_start_tvsec == after.pbi_start_tvsec
        && before.pbi_start_tvusec == after.pbi_start_tvusec
        && before.pbi_pgid == after.pbi_pgid && before.e_tpgid == after.e_tpgid
        && before.e_tdev == after.e_tdev;
}
struct reply_context { xpc_connection_t peer; xpc_object_t reply; };
static void send_reply(void *context, const void *bytes, size_t length) {
    struct reply_context *r = context;
    xpc_dictionary_set_data(r->reply, "frame", bytes, length);
    xpc_connection_send_message(r->peer, r->reply);
}
// Handler and context live for the listener's process lifetime. libxpc serializes
// events for each peer; dispatching work here never blocks the listener queue.
int arkdeck_mach_listen(const char *name, const char *requirement,
                       arkdeck_frame_handler handler, void *context) {
    xpc_connection_t listener = xpc_connection_create_mach_service(
        name, NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    if (!listener) return -1;
    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION) return;
        if (xpc_connection_get_euid(peer) != geteuid()
            || xpc_connection_set_peer_code_signing_requirement(peer, requirement) != 0) {
            xpc_connection_cancel(peer);
            return;
        }
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
            if (xpc_get_type(event) != XPC_TYPE_DICTIONARY) return;
            xpc_object_t reply = xpc_dictionary_create_reply(event);
            if (!reply) { xpc_connection_cancel(peer); return; }
            size_t length = 0;
            const void *bytes = xpc_dictionary_get_data(event, "frame", &length);
            if (xpc_dictionary_get_count(event) != 1 || !bytes || length >= 4 * 1024 * 1024) {
                bytes = ""; length = 0;
            }
            struct reply_context r = { peer, reply };
            handler(context, bytes, length, xpc_connection_get_euid(peer),
                    xpc_connection_get_pid(peer), &r, send_reply);
            xpc_release(reply);
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
    return 0;
}
