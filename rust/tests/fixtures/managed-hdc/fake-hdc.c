/* A fake `hdc` for the managed HDC server's host tests (TASK-XPA-016):
 * `-s <endpoint> -m` binds the endpoint's port on the IPv4 loopback after a
 * compile-time cold start and accepts forever; `checkserver` answers the
 * registered line with a compile-time server version; anything else is
 * unregistered. EXIT_EARLY ends the server before it binds, NEVER_BIND keeps
 * it alive without a listener, PRINT_PORT reports the server port variable
 * it was given. No real HDC, server or device is involved. */
#include <arpa/inet.h>
#include <netinet/in.h>
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
int main(int argc, char **argv) {
    const char *endpoint = NULL;
    int foreground = 0, check = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-s") == 0 && i + 1 < argc) endpoint = argv[++i];
        else if (strcmp(argv[i], "-m") == 0) foreground = 1;
        else if (strcmp(argv[i], "checkserver") == 0) check = 1;
    }
    if (check) {
        printf("Client version:Ver: 3.2.0d, server version:Ver: " SERVER_VERSION "\n");
        return 0;
    }
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
        int client = accept(fd, NULL, NULL);
        if (client >= 0) close(client);
    }
}
