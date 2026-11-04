/* EAP TLS 1.2 compatibility fix for iOS 5/6, plus Wi-Fi watchdog bootstrap.
 *
 * TLS part:
 *   The legacy eapolclient creates its TLS context with kTLSProtocol1Only (iOS
 *   5/6) or kTLSProtocol1 with min=max=TLS 1.0 (iOS 7), so PEAP/TTLS only
 *   advertise TLS 1.0 and servers that require TLS 1.2 reject the handshake.
 *   This tweak raises the *maximum* protocol version to TLS 1.2 for EAP client
 *   contexts, leaving the minimum at TLS 1.0 so re-auth and session reuse can
 *   still fall back instead of failing the link.
 *
 * Watchdog part:
 *   wifid/eapolclient start as root and can keep a dead association alive
 *   ("connected", no traffic). When loaded into either process this tweak
 *   starts /usr/bin/wifi-watchdog.sh detached if it is not already
 *   running, so the recovery daemon is re-established on every Wi-Fi restart.
 *
 * Certificate validation, trust anchors, server-name checks and credentials
 * are untouched. Only eapolclient/wifid are instrumented; removing the
 * dylib/filter fully reverses the change.
 */
typedef int OSStatus;
typedef unsigned int SSLProtocol;
typedef void *SSLContextRef;
typedef unsigned char Boolean;
typedef OSStatus (*ReadFunc)(void *, void *, unsigned long *);
typedef OSStatus (*WriteFunc)(void *, const void *, unsigned long *);

extern void *dlsym(void *, const char *);
extern void *dlopen(const char *, int);
extern int access(const char *, int);
extern void syslog(int, const char *, ...);
extern const char *getprogname(void);
extern int strcmp(const char *, const char *);
extern unsigned int geteuid(void);
extern int open(const char *, int, ...);
extern long read(int, void *, unsigned long);
extern int close(int);
extern int kill(int, int);
extern int fork(void);
extern int setsid(void);
extern int execl(const char *, const char *, ...);
extern void _exit(int);

static void (*hook_function)(void *, void *, void **);
static SSLContextRef (*original_create)(SSLProtocol, Boolean, ReadFunc, WriteFunc, void *, char *, OSStatus *);
static OSStatus (*set_max)(SSLContextRef, SSLProtocol);

#define kTLSProtocol1 4
#define kTLSProtocol1Only 5
#define kTLSProtocol12 8
#define O_RDONLY 0

static int watchdog_running(void) {
    char buf[32];
    long n;
    int fd = open("/var/run/wifi-watchdog.pid", O_RDONLY);
    if (fd < 0) fd = open("/tmp/wifi-watchdog.pid", O_RDONLY);
    int pid = 0;
    char *p;
    if (fd < 0) return 0;
    n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return 0;
    buf[n] = '\0';
    for (p = buf; *p >= '0' && *p <= '9'; p++) pid = pid * 10 + (*p - '0');
    return (pid > 1 && kill(pid, 0) == 0) ? 1 : 0;
}

static const char *first_existing(const char *a, const char *b, const char *c) {
    if (a && access(a, 0) == 0) return a;
    if (b && access(b, 0) == 0) return b;
    if (c && access(c, 0) == 0) return c;
    return (const char *)0;
}

static void ensure_watchdog(void) {
    int child;
    const char *script, *shell;
    if (geteuid() != 0) return;
    if (watchdog_running()) return;
    script = first_existing("/usr/bin/wifi-watchdog.sh",
                            "/var/jb/usr/bin/wifi-watchdog.sh", (const char *)0);
    shell = first_existing("/bin/bash", "/var/jb/bin/bash", "/var/jb/usr/bin/bash");
    if (!script) return;
    if (!shell) shell = "/bin/sh";
    child = fork();
    if (child == 0) {
        setsid();
        execl(shell, "bash", script, (char *)0);
        _exit(127);
    }
}

static SSLContextRef create_with_tls12(SSLProtocol protocol, Boolean server,
                                       ReadFunc readfn, WriteFunc writefn,
                                       void *handle, char *peer, OSStatus *status) {
    SSLContextRef ctx = original_create(protocol, server, readfn, writefn, handle, peer, status);
    if (ctx == (void *)0 || server || (protocol != kTLSProtocol1 && protocol != kTLSProtocol1Only)) {
        return ctx;
    }
    /* Raise the ceiling only: min stays TLS 1.0 so a failed/rekeyed or resumed
     * session can still negotiate downward instead of breaking authentication. */
    OSStatus maximum = set_max(ctx, kTLSProtocol12);
    if (maximum != 0) {
        syslog(3, "EAPTLS12Fix: SSLSetProtocolVersionMax failed (%d); using default TLS", maximum);
        return ctx;
    }
    syslog(5, "EAPTLS12Fix: EAP context may negotiate up to TLS 1.2 (was proto %d)", protocol);
    return ctx;
}

__attribute__((constructor)) static void install(void) {
    const char *prog = getprogname();
    void *global = (void *)-2; /* RTLD_DEFAULT on Darwin */

    /* Keep the Wi-Fi recovery daemon alive on every wifid/eapolclient start. */
    if (strcmp(prog, "wifid") == 0 || strcmp(prog, "eapolclient") == 0) {
        ensure_watchdog();
    }
    if (strcmp(prog, "eapolclient") != 0) {
        return;
    }

    {
        void *target = dlsym(global, "EAPSSLContextCreate");
        set_max = dlsym(global, "SSLSetProtocolVersionMax");
        if (target == (void *)0 || set_max == (void *)0) {
            syslog(3, "EAPTLS12Fix: required API missing; no hook installed");
            return;
        }
        {
            static const char *paths[] = {
                "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                "/usr/lib/libsubstrate.dylib",
                "/var/jb/usr/lib/libsubstrate.dylib",
                (const char *)0
            };
            void *substrate = (void *)0;
            int i;
            for (i = 0; paths[i] != (const char *)0 && substrate == (void *)0; i++) {
                if (access(paths[i], 0) == 0) substrate = dlopen(paths[i], 2);
            }
            hook_function = substrate ? dlsym(substrate, "MSHookFunction") : (void *)0;
            if (hook_function == (void *)0) {
                syslog(3, "EAPTLS12Fix: Substrate hook API unavailable; no hook installed");
                return;
            }
#if defined(__arm64__) || defined(__aarch64__)
            hook_function(target, (void *)create_with_tls12, (void **)&original_create);
#else
            hook_function((void *)((unsigned long)target | 1), (void *)create_with_tls12, (void **)&original_create);
#endif
        }
    }
    syslog(5, "EAPTLS12Fix: installed EAP TLS 1.2 ceiling hook");
}
