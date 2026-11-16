/* wifi-watchdog-reap: SIGKILL every running copy of wifi-watchdog.sh.
 *
 * Used by the package scripts before launchd (re)starts the watchdog. iOS 5 ships no
 * ps/pkill, and 1.5.0 left unmanaged copies behind (started with nohup or from inside
 * wifid/eapolclient, with a TERM trap that did not exit). Matches on the process's
 * own argument vector, so a PID reused by an unrelated process is never touched.
 * Usage: wifi-watchdog-reap [-n]   (-n: list only)
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

static int is_watchdog(pid_t pid) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    char buf[4096];
    size_t len = sizeof(buf);
    int argc, i;
    char *p, *end;
    if (sysctl(mib, 3, buf, &len, NULL, 0) != 0 || len <= sizeof(int)) return 0;
    memcpy(&argc, buf, sizeof(int));
    p = buf + sizeof(int);
    end = buf + len;
    while (p < end && *p) p++;          /* executable path */
    while (p < end && !*p) p++;         /* padding */
    for (i = 0; i < argc && p < end; i++) {
        const char *arg = p;
        size_t n = strnlen(p, (size_t)(end - p));
        size_t s = strlen("wifi-watchdog.sh");
        if (i > 0 && n >= s && strcmp(arg + n - s, "wifi-watchdog.sh") == 0) return 1;
        p += n + 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    int list_only = argc > 1 && strcmp(argv[1], "-n") == 0;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    struct kinfo_proc *procs;
    int count, i, found = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return 2;
    size += size / 8;
    procs = malloc(size);
    if (!procs || sysctl(mib, 4, procs, &size, NULL, 0) != 0) return 2;
    count = (int)(size / sizeof(*procs));
    for (i = 0; i < count; i++) {
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 1 || pid == getpid() || !is_watchdog(pid)) continue;
        found++;
        if (list_only) { printf("%d\n", pid); continue; }
        if (kill(pid, SIGKILL) == 0) printf("killed %d\n", pid);
    }
    free(procs);
    return found ? 0 : 1;
}
