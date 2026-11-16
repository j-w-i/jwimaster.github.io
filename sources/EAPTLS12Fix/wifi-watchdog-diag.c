/* wifi-watchdog-diag: print the Wi-Fi-related system log (ASL) since a time.
 *
 * The watchdog calls this when the link drops or a check fails, so the reason survives ASL
 * rotation: the Broadcom driver's join/disassociate lines, wifid, eapolclient (EAP/PEAP outcome,
 * TLS hook), configd/IPConfiguration (DHCP, captive), and anything mentioning the Wi-Fi stack.
 * Usage: wifi-watchdog-diag SINCE_EPOCH_SECONDS
 */
#include <asl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int relevant(const char *sender, const char *msg) {
    /* Everything these daemons log is about the network stack. */
    static const char *senders[] = {"wifid", "eapolclient", "configd", "IPConfiguration", "WiFiPicker", NULL};
    /* From any other sender (kernel driver, Preferences, apps), keep only Wi-Fi/EAP/DHCP lines. */
    static const char *words[] = {"BCMWLAN", "80211", "802.1X", "WiFi", "wifi", "Wi-Fi", "en0", "EAP",
                                  "DHCP", "SSID", "BSSID", "Joined", "ASSOCIATE", "deauth", "Deauth",
                                  "disassoc", "Disassoc", "beacon", "roam", "Roam", NULL};
    int i;
    if (!msg) return 0;
    for (i = 0; sender && senders[i]; i++)
        if (strcmp(sender, senders[i]) == 0) return 1;
    for (i = 0; words[i]; i++)
        if (strstr(msg, words[i])) return 1;
    return 0;
}

int main(int argc, char **argv) {
    aslmsg query, m;
    aslresponse r;
    if (argc != 2) { fprintf(stderr, "usage: wifi-watchdog-diag SINCE_EPOCH_SECONDS\n"); return 2; }
    query = asl_new(ASL_TYPE_QUERY);
    asl_set_query(query, ASL_KEY_TIME, argv[1], ASL_QUERY_OP_GREATER_EQUAL | ASL_QUERY_OP_NUMERIC);
    r = asl_search(NULL, query);
    while ((m = aslresponse_next(r)) != NULL) {
        const char *t = asl_get(m, ASL_KEY_TIME), *s = asl_get(m, ASL_KEY_SENDER), *x = asl_get(m, ASL_KEY_MSG);
        char stamp[32] = "?";
        if (!relevant(s, x)) continue;
        if (t) { time_t secs = (time_t)strtol(t, NULL, 10); strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", localtime(&secs)); }
        printf("%s %s: %s\n", stamp, s ? s : "?", x);
    }
    aslresponse_free(r);
    asl_free(query);
    return 0;
}
