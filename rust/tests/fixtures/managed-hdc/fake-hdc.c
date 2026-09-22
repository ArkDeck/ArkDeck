/* A fake `hdc` for the managed HDC server's host tests (TASK-XPA-016):
 * `-s <endpoint> -m` binds the endpoint's port on the IPv4 loopback after a
 * compile-time cold start and accepts forever; `checkserver` answers the
 * registered line with a compile-time server version; anything else is
 * unregistered. EXIT_EARLY ends the server before it binds, NEVER_BIND keeps
 * it alive without a listener, PRINT_PORT reports the server port variable
 * it was given. LIST_EMPTY answers `list targets -v` with no target, and
 * RECORD_CALLS names a file every invocation appends its arguments to, one
 * line each, before it does anything else (TASK-XPA-014). No real HDC,
 * server or device is involved. */
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#ifndef SERVER_VERSION
#define SERVER_VERSION "3.2.0d"
#endif
#ifndef COLD_MS
#define COLD_MS 0
#endif
#ifdef RECORD_CALLS
/* One line of this invocation's arguments, appended in one write. */
static void record_call(int argc, char **argv) {
    char line[4096];
    size_t used = 0;
    for (int i = 1; i < argc; i++) {
        size_t length = strlen(argv[i]);
        if (used + length + 2 > sizeof line) break;
        if (i > 1) line[used++] = ' ';
        memcpy(line + used, argv[i], length);
        used += length;
    }
    line[used++] = '\n';
    int fd = open(RECORD_CALLS, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (fd >= 0) {
        (void)write(fd, line, used);
        close(fd);
    }
}
#endif
int main(int argc, char **argv) {
#ifdef RECORD_CALLS
    record_call(argc, argv);
#endif
    const char *endpoint = NULL;
    int foreground = 0, check = 0, list = 0, kill_command = 0, restart = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) endpoint = argv[++i];
        else if (strcmp(argv[i], "-m") == 0) foreground = 1;
        else if (strcmp(argv[i], "checkserver") == 0) check = 1;
        else if (strcmp(argv[i], "list") == 0) list = 1;
        else if (strcmp(argv[i], "kill") == 0) kill_command = 1;
        else if (strcmp(argv[i], "-r") == 0) restart = 1;
    }
    if (check) {
        printf("Client version:Ver: 3.2.0d, server version:Ver: " SERVER_VERSION "\n");
        return 0;
    }
#ifdef LIST_EMPTY
    if (list) {
        printf("[Empty]\n");
        return 0;
    }
#else
    (void)list;
#endif
#ifdef RESTART_DIR
    if (kill_command && endpoint != NULL) {
#ifdef FAIL_RESTART
        fprintf(stderr, "kill: unexpected condition\n");
        return 0;
#endif
        int marker = open(RESTART_DIR "/stop", O_WRONLY | O_CREAT, 0600);
        if (marker < 0) return 66;
        close(marker);
        const char *colon = strrchr(endpoint, ':');
        if (colon == NULL) return 64;
        struct sockaddr_in address;
        memset(&address, 0, sizeof address);
        address.sin_len = sizeof address;
        address.sin_family = AF_INET;
        address.sin_port = htons((unsigned short)atoi(colon + 1));
        address.sin_addr.s_addr = inet_addr("127.0.0.1");
        for (int i = 0; i < 200; i++) {
            int probe = socket(AF_INET, SOCK_STREAM, 0);
            int reachable = connect(probe, (struct sockaddr *)&address, sizeof address) == 0;
            close(probe);
            if (!reachable) break;
            usleep(20000);
        }
        if (!restart) return 0;
        unlink(RESTART_DIR "/stop");
        pid_t child = fork();
        if (child < 0) return 68;
        if (child == 0) {
            setsid();
            int null = open("/dev/null", O_RDWR);
            if (null >= 0) { dup2(null, 0); dup2(null, 1); dup2(null, 2); if (null > 2) close(null); }
            char *args[] = { (char *)SELF_PATH, "-s", (char *)endpoint, "-m", NULL };
            execv(SELF_PATH, args);
            _exit(69);
        }
        return 0;
    }
#else
    (void)kill_command;
    (void)restart;
#endif
    if (!foreground || endpoint == NULL) {
        fprintf(stderr, "unregistered fixture output\n");
        return 23;
    }
#ifdef EXIT_EARLY
    return EXIT_EARLY;
#endif
#ifdef PRINT_PORT
    const char *port_variable = getenv("OHOS_HDC_SERVER_PORT");
    printf("OHOS_HDC_SERVER_PORT=%s\n", port_variable ? port_variable : "unset");
    fflush(stdout);
#endif
#ifdef NEVER_BIND
    for (;;) sleep(3600);
#endif
    if (COLD_MS > 0) usleep(COLD_MS * 1000);
    const char *colon = strrchr(endpoint, ':');
    if (colon == NULL) return 64;
    int port = atoi(colon + 1);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 65;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in address;
    memset(&address, 0, sizeof address);
    address.sin_len = sizeof address;
    address.sin_family = AF_INET;
    address.sin_port = htons((unsigned short)port);
    address.sin_addr.s_addr = inet_addr("127.0.0.1");
    if (bind(fd, (struct sockaddr *)&address, sizeof address) != 0 || listen(fd, 4) != 0) return 67;
    for (;;) {
#ifdef RESTART_DIR
        if (access(RESTART_DIR "/stop", F_OK) == 0) return 0;
        struct pollfd waiting = { fd, POLLIN, 0 };
        if (poll(&waiting, 1, 20) <= 0) continue;
#endif
        int client = accept(fd, NULL, NULL);
        if (client >= 0) close(client);
    }
}
