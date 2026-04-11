/*
 * wlan_keepalive — lightweight monitor interface keepalive daemon
 *
 * WHY: The BCM43436B0 WiFi chip (Pi Zero 2W) connects via SDIO bus.
 * When no process actively reads frames from the monitor interface, the
 * SDIO bus goes idle and the firmware crashes ("Firmware has halted").
 * Bettercap's wifi.recon accidentally provides this keepalive, but costs
 * ~50MB RAM. This daemon does the same job at ~20KB.
 *
 * HOW: Opens a raw packet socket on wlan0mon in promiscuous mode and
 * drains frames in a loop. Periodically sends broadcast probe requests
 * to ensure the driver stays active even when there's no nearby traffic.
 * If frames stop arriving, reconnects the socket. If the interface
 * disappears (firmware crash, AO restart), waits and reconnects.
 *
 * WHAT HAPPENS WITHOUT IT: WiFi dies every 1-3 minutes. The bull shows
 * "WiFi down!", captures stop, and only a GPIO power cycle or reboot
 * brings WiFi back. If bettercap is running, you don't need this.
 *
 * Build:  gcc -O2 -o wlan_keepalive wlan_keepalive.c
 * Usage:  wlan_keepalive [interface] [poll_ms]
 *         Default: wlan0mon, 100ms poll
 * No dependencies. Pure C, pure Linux syscalls.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>
#include <net/if.h>
#include <poll.h>

/* Interval between probe request injections (seconds) */
#define PROBE_INTERVAL 3

static volatile int running = 1;

static void sig_handler(int sig) {
    (void)sig;
    running = 0;
}

static int open_raw_socket(const char *iface) {
    int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (fd < 0) return -1;

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, iface, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0) {
        close(fd);
        return -1;
    }
    int ifindex = ifr.ifr_ifindex;

    /* Enable promiscuous mode on the interface */
    struct packet_mreq mreq;
    memset(&mreq, 0, sizeof(mreq));
    mreq.mr_ifindex = ifindex;
    mreq.mr_type = PACKET_MR_PROMISC;
    setsockopt(fd, SOL_PACKET, PACKET_ADD_MEMBERSHIP, &mreq, sizeof(mreq));

    struct sockaddr_ll sll;
    memset(&sll, 0, sizeof(sll));
    sll.sll_family = AF_PACKET;
    sll.sll_ifindex = ifindex;
    sll.sll_protocol = htons(ETH_P_ALL);
    if (bind(fd, (struct sockaddr *)&sll, sizeof(sll)) < 0) {
        close(fd);
        return -1;
    }

    return fd;
}

/*
 * Inject a minimal 802.11 broadcast probe request via the raw socket.
 * This generates driver TX activity even when there's no nearby WiFi
 * traffic, keeping the SDIO bus alive. The frame is a standard probe
 * request with a radiotap header (required for monitor mode injection).
 */
static void send_probe(int fd, const char *iface) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, iface, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFINDEX, &ifr) < 0) return;

    /* Radiotap header (8 bytes, minimal) + 802.11 probe request */
    unsigned char probe[] = {
        /* Radiotap header */
        0x00, 0x00,             /* version, pad */
        0x08, 0x00,             /* length = 8 */
        0x00, 0x00, 0x00, 0x00, /* present flags: none */
        /* 802.11 header: probe request */
        0x40, 0x00,             /* frame control: probe request */
        0x00, 0x00,             /* duration */
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, /* DA: broadcast */
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, /* SA: zero (anonymous) */
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, /* BSSID: broadcast */
        0x00, 0x00,             /* seq/frag */
        /* Tagged params: SSID (empty = wildcard) */
        0x00, 0x00,             /* tag: SSID, length: 0 */
        /* Supported rates */
        0x01, 0x04, 0x02, 0x04, 0x0b, 0x16,
    };

    struct sockaddr_ll dest;
    memset(&dest, 0, sizeof(dest));
    dest.sll_family = AF_PACKET;
    dest.sll_ifindex = ifr.ifr_ifindex;
    dest.sll_halen = 6;
    memset(dest.sll_addr, 0xff, 6);

    sendto(fd, probe, sizeof(probe), 0,
           (struct sockaddr *)&dest, sizeof(dest));
}

static int iface_exists(const char *iface) {
    char path[128];
    snprintf(path, sizeof(path), "/sys/class/net/%s", iface);
    struct stat st;
    return stat(path, &st) == 0;
}

int main(int argc, char *argv[]) {
    const char *iface = argc > 1 ? argv[1] : "wlan0mon";
    int poll_ms = argc > 2 ? atoi(argv[2]) : 100;
    if (poll_ms < 10) poll_ms = 10;
    if (poll_ms > 5000) poll_ms = 5000;

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    unsigned char buf[512];
    unsigned long frames = 0;
    time_t last_log = 0;

    fprintf(stderr, "wlan_keepalive: interface=%s poll=%dms\n", iface, poll_ms);

    while (running) {
        /* Wait for interface to appear */
        while (running && !iface_exists(iface)) {
            sleep(1);
        }
        if (!running) break;

        int fd = open_raw_socket(iface);
        if (fd < 0) {
            fprintf(stderr, "wlan_keepalive: can't open %s: %s\n", iface, strerror(errno));
            sleep(2);
            continue;
        }

        fprintf(stderr, "wlan_keepalive: listening on %s (promisc)\n", iface);

        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        time_t last_probe = 0;

        while (running) {
            int ret = poll(&pfd, 1, poll_ms);
            if (ret > 0 && (pfd.revents & POLLIN)) {
                while (recv(fd, buf, sizeof(buf), MSG_DONTWAIT) > 0) {
                    frames++;
                }
            }
            if (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) {
                fprintf(stderr, "wlan_keepalive: %s error, reconnecting...\n", iface);
                break;
            }

            time_t now = time(NULL);

            /* Send probe request every PROBE_INTERVAL seconds.
             * This is the core keepalive: TX activity keeps the SDIO bus
             * alive even when AO owns the RX path and we see 0 frames. */
            if (now - last_probe >= PROBE_INTERVAL) {
                send_probe(fd, iface);
                last_probe = now;
            }

            /* Log stats every 60s */
            if (now - last_log >= 60) {
                fprintf(stderr, "wlan_keepalive: %lu frames, probes every %ds\n",
                        frames, PROBE_INTERVAL);
                last_log = now;
            }
        }

        close(fd);
        if (running) sleep(1);
    }

    fprintf(stderr, "wlan_keepalive: stopped (%lu total frames)\n", frames);
    return 0;
}
