/* Minimal idle process with custom /proc/PID/comm field.
   Usage: _idle <name>
   Sets comm to basename of <name>, then sleeps forever.
   Used by entrypoint.sh to create realistic dummy processes. */
#include <sys/prctl.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    if (argc > 1) {
        char *p = strrchr(argv[1], '/');
        prctl(PR_SET_NAME, p ? p + 1 : argv[1], 0, 0, 0);
        memset(argv[1], 0, strlen(argv[1]));
    }
    for (;;) pause();
}
