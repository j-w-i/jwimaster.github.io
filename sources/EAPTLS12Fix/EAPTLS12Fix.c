/* EAP TLS 1.2 compatibility fix for iOS 5/6/7.
 *
 * TLS part:
 *   The legacy eapolclient creates its TLS context with kTLSProtocol1Only (iOS
 *   5/6) or kTLSProtocol1 with min=max=TLS 1.0 (iOS 7), so PEAP/TTLS only
 *   advertise TLS 1.0 and servers that require TLS 1.2 reject the handshake.
 *   This tweak raises the *maximum* protocol version to TLS 1.2 for EAP client
 *   contexts, leaving the minimum at TLS 1.0 so re-auth and session reuse can
 *   still fall back instead of failing the link.
 *
 * The Wi-Fi recovery watchdog is a separate launchd job (com.jwi.wifiwatchdog).
 * Up to 1.5.0 this dylib also forked the watchdog from inside wifid and
 * eapolclient; those children inherited the daemons' descriptors, were never
 * reaped, and raced each other into duplicate watchdogs that each restarted
 * wifid. launchd now owns the watchdog and this dylib loads into eapolclient only.
 *
 * Certificate validation, trust anchors, server-name checks and credentials
 * are untouched. Removing the dylib/filter fully reverses the change.
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
static void (*hook_function)(void *, void *, void **);
static SSLContextRef (*original_create)(SSLProtocol, Boolean, ReadFunc, WriteFunc, void *, char *, OSStatus *);
static OSStatus (*set_max)(SSLContextRef, SSLProtocol);

#define kTLSProtocol1 4
#define kTLSProtocol1Only 5
#define kTLSProtocol12 8

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
