/* wifi-watchdog-power: turn Wi-Fi off and on again through MobileWiFi, like the switch in Settings.
 *
 * Restarting wifid (launchctl stop) does not make it rejoin an 802.1X network on iOS 5: after a
 * drop it stays scanning (AirPort STATE 3) for hours. A power cycle through WiFiManager, which is
 * what Settings does, rejoins within seconds. MobileWiFi is a private framework, so it is opened
 * at run time. Usage: wifi-watchdog-power [OFF_SECONDS]   (default 2). Exit 0 if both calls were made.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef void *WiFiManagerClientRef;
typedef WiFiManagerClientRef (*CreateFn)(CFAllocatorRef, int);
typedef void (*SetPowerFn)(WiFiManagerClientRef, Boolean);

int main(int argc, char **argv) {
    unsigned off = argc > 1 ? (unsigned)atoi(argv[1]) : 2;
    void *lib = dlopen("/System/Library/PrivateFrameworks/MobileWiFi.framework/MobileWiFi", RTLD_LAZY);
    CreateFn create = lib ? (CreateFn)dlsym(lib, "WiFiManagerClientCreate") : NULL;
    SetPowerFn setPower = lib ? (SetPowerFn)dlsym(lib, "WiFiManagerClientSetPower") : NULL;
    WiFiManagerClientRef manager;
    if (!create || !setPower) { fprintf(stderr, "MobileWiFi unavailable: %s\n", dlerror()); return 1; }
    manager = create(kCFAllocatorDefault, 0);
    if (!manager) { fprintf(stderr, "WiFiManagerClientCreate failed\n"); return 1; }
    setPower(manager, false);
    sleep(off ? off : 1);
    setPower(manager, true);
    CFRelease(manager);
    return 0;
}
