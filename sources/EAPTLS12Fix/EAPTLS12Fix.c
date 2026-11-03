/* EAP TLS 1.2 compatibility fix for iOS 5/6.
 *
 * The legacy eapolclient creates its TLS context with kTLSProtocol1Only, so
 * PEAP/TTLS only advertise TLS 1.0 and servers that require TLS 1.2 reject
 * the handshake. This tweak raises the *maximum* protocol version to TLS 1.2
 * for EAP client contexts, leaving the minimum at TLS 1.0 so that re-auth and
 * session resumption can still fall back instead of failing the link.
 *
 * Certificate validation, trust anchors, server-name checks and credentials
 * are untouched. Only eapolclient is instrumented; removing the dylib/filter
 * fully reverses the change.
 */
typedef int OSStatus;
typedef unsigned int SSLProtocol;
typedef void *SSLContextRef;
typedef unsigned char Boolean;
typedef OSStatus (*ReadFunc)(void *, void *, unsigned long *);
typedef OSStatus (*WriteFunc)(void *, const void *, unsigned long *);

extern void *dlsym(void *, const char *);
extern void *dlopen(const char *, int);
extern void syslog(int, const char *, ...);
extern const char *getprogname(void);
extern int strcmp(const char *, const char *);

static void (*hook_function)(void *, void *, void **);
static SSLContextRef (*original_create)(SSLProtocol, Boolean, ReadFunc, WriteFunc, void *, char *, OSStatus *);
static OSStatus (*set_max)(SSLContextRef, SSLProtocol);

#define kTLSProtocol1Only 5
#define kTLSProtocol12 8

static SSLContextRef create_with_tls12(SSLProtocol protocol, Boolean server,
                                       ReadFunc readfn, WriteFunc writefn,
                                       void *handle, char *peer, OSStatus *status) {
    SSLContextRef ctx = original_create(protocol, server, readfn, writefn, handle, peer, status);
    if (ctx == (void *)0 || server || protocol != kTLSProtocol1Only) {
        return ctx;
    }
    /* Raise the ceiling only: min stays TLS 1.0 so a failed/rekeyed or resumed
     * session can still negotiate downward instead of breaking authentication. */
    OSStatus maximum = set_max(ctx, kTLSProtocol12);
    if (maximum != 0) {
        /* Leave the stock context intact rather than failing the connection. */
        syslog(3, "EAPTLS12Fix: SSLSetProtocolVersionMax failed (%d); using default TLS", maximum);
        return ctx;
    }
    syslog(5, "EAPTLS12Fix: EAP context may negotiate up to TLS 1.2 (min TLS 1.0)");
    return ctx;
}

__attribute__((constructor)) static void install(void) {
    if (strcmp(getprogname(), "eapolclient") != 0) {
        return;
    }
    void *global = (void *)-2; /* RTLD_DEFAULT on Darwin */
    void *target = dlsym(global, "EAPSSLContextCreate");
    set_max = dlsym(global, "SSLSetProtocolVersionMax");
    if (target == (void *)0 || set_max == (void *)0) {
        syslog(3, "EAPTLS12Fix: required API missing; no hook installed");
        return;
    }
    void *substrate = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", 2);
    hook_function = substrate ? dlsym(substrate, "MSHookFunction") : (void *)0;
    if (hook_function == (void *)0) {
        syslog(3, "EAPTLS12Fix: Substrate hook API unavailable; no hook installed");
        return;
    }
    hook_function((void *)((unsigned long)target | 1), (void *)create_with_tls12, (void **)&original_create);
    syslog(5, "EAPTLS12Fix: installed EAP TLS 1.2 ceiling hook");
}
