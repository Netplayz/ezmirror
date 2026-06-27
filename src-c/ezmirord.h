#ifndef EZMIRORD_H
#define EZMIRORD_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <time.h>
#include <errno.h>
#include <pthread.h>
#include <getopt.h>
#include <dirent.h>
#include <sys/wait.h>
#include <arpa/inet.h>

#define PID_FILE "/var/run/ezmirord.pid"
#define STATUS_FILE "/var/www/html/status.json"
#define METRICS_PORT 9633
#define CONFIG_DIR "/etc/ezmirror"
#define MIRRORS_CONF CONFIG_DIR "/mirrors.conf"

typedef struct {
    char slug[64];
    char name[128];
    char desc[256];
    char upstream[512];
    char method[32];
    char size[32];
    char interval[16];
    int bandwidth;
    int retention_days;
    int retention_max_gib;
} MirrorConfig;

typedef struct {
    MirrorConfig *mirrors;
    int count;
    int capacity;
} MirrorList;

typedef struct {
    time_t last_sync;
    int exit_code;
    long disk_bytes;
    char status[16];
    char upstream_health[16];
    time_t upstream_health_checked;
    int upstream_response_time_ms;
} MirrorStatus;

// config.c
int parse_mirrors_conf(const char *path, MirrorList *list);
void free_mirror_list(MirrorList *list);

// sync.c
int run_sync(MirrorConfig *cfg, const char *mirror_dir, int dry_run);

// status.c
int update_status(const char *slug, MirrorStatus *status);
int read_status(const char *slug, MirrorStatus *status);

// metrics.c
void *metrics_server(void *arg);
void stop_metrics_server(void);

// config.c
int interval_to_seconds(const char *interval);

#endif
