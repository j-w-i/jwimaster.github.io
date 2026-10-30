/* Local compatibility fix: enable existing iOS 5 SecureTransport TLS 1.2
 * only for EAP contexts in eapolclient. No certificate or credential hooks.
 * Removing the dylib/filter reverses the change. */
typedef int OSStatus;
typedef unsigned int SSLProtocol;
typedef void *SSLContextRef;
typedef unsigned char Boolean;
typedef OSStatus (*ReadFunc)(void *, void *, unsigned long *);
typedef OSStatus (*WriteFunc)(void *, const void *, unsigned long *);
extern void *dlsym(void *, const char *);
extern void *dlopen(const char *, int);
static void (*hook_function)(void *, void *, void **);
extern void syslog(int, const char *, ...);
extern const char *getprogname(void);
extern int strcmp(const char *, const char *);
static SSLContextRef (*original_create)(SSLProtocol, Boolean, ReadFunc, WriteFunc, void *, char *, OSStatus *);
static OSStatus (*set_min)(SSLContextRef, SSLProtocol);
static OSStatus (*set_max)(SSLContextRef, SSLProtocol);
static void (*dispose_context)(SSLContextRef);
static SSLContextRef create_tls12(SSLProtocol protocol, Boolean server, ReadFunc readfn, WriteFunc writefn, void *handle, char *peer, OSStatus *status) {
    SSLContextRef ctx = original_create(protocol, server, readfn, writefn, handle, peer, status);
    if (!ctx || server || protocol != 5) return ctx;
    /* kTLSProtocol12 = 8. Both APIs exist in this device's Security image. */
    OSStatus maximum = set_max(ctx, 8);
    OSStatus minimum = maximum ? maximum : set_min(ctx, 8);
    if (maximum || minimum) {
        syslog(3, "EAPTLS12Fix: protocol setup failed max=%d min=%d", maximum, minimum);
        dispose_context(ctx);
        if (status) *status = maximum ? maximum : minimum;
        return (void *)0;
    }
    syslog(5, "EAPTLS12Fix: EAP context restricted to TLS 1.2; certificate validation unchanged");
    return ctx;
}
__attribute__((constructor)) static void install(void) {
    if (strcmp(getprogname(), "eapolclient")) return;
    void *global = (void *)-2; /* RTLD_DEFAULT on Darwin */
    void *target = dlsym(global, "EAPSSLContextCreate");
    set_min = dlsym(global, "SSLSetProtocolVersionMin");
    set_max = dlsym(global, "SSLSetProtocolVersionMax");
    dispose_context = dlsym(global, "SSLDisposeContext");
    if (!target || !set_min || !set_max || !dispose_context) {
        syslog(3, "EAPTLS12Fix: required API missing; no hook installed");
        return;
    }
    void *substrate = dlopen("/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate", 2);
    hook_function = substrate ? dlsym(substrate, "MSHookFunction") : (void *)0;
    if (!hook_function) {
        syslog(3, "EAPTLS12Fix: Substrate hook API unavailable; no hook installed");
        return;
    }
    hook_function((void *)((unsigned long)target | 1), (void *)create_tls12, (void **)&original_create);
    syslog(5, "EAPTLS12Fix: installed scoped EAP TLS 1.2 compatibility hook");
}
