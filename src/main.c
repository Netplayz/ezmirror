#include "ezmirord.h"

static volatile sig_atomic_t run = 1;
static MirrorList active_mirrors;
static pthread_t metrics_thread;

void handle_signal(int sig) {
    switch (sig) {
        case SIGTERM:
        case SIGINT:
            run = 0;
            stop_metrics_server();
            break;
        case SIGHUP:
            // Reload config
            free_mirror_list(&active_mirrors);
            parse_mirrors_conf(MIRRORS_CONF, &active_mirrors);
            break;
    }
}

void daemonize() {
    pid_t pid = fork();
    if (pid < 0) exit(EXIT_FAILURE);
    if (pid > 0) exit(EXIT_SUCCESS);

    if (setsid() < 0) exit(EXIT_FAILURE);

    signal(SIGCHLD, SIG_IGN);

    pid = fork();
    if (pid < 0) exit(EXIT_FAILURE);
    if (pid > 0) exit(EXIT_SUCCESS);

    umask(0);
    (void)chdir("/");

    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    close(STDERR_FILENO);

    open("/dev/null", O_RDONLY);
    open("/dev/null", O_WRONLY);
    open("/dev/null", O_RDWR);
}

void write_pid() {
    FILE *fp = fopen(PID_FILE, "w");
    if (fp) {
        fprintf(fp, "%d\n", getpid());
        fclose(fp);
    }
}

void usage(const char *name) {
    fprintf(stderr,
        "Usage: %s [options]\n\n"
        "Options:\n"
        "  -d, --daemon     Run as daemon\n"
        "  -f, --foreground Run in foreground (default)\n"
        "  -p, --port PORT  Metrics HTTP port (default: %d)\n"
        "  -s, --sync       Run sync for all due mirrors once, then exit\n"
        "  --sync-slug=SLUG Sync a specific mirror\n"
        "  --dry-run        Simulate sync without writing\n"
        "  --status         Print status JSON and exit\n"
        "  -h, --help       Show this help\n",
        name, METRICS_PORT);
}

int main(int argc, char **argv) {
    int daemon_mode = 0;
    int run_sync_once = 0;
    int dry_run = 0;
    int show_status = 0;
    char sync_slug[64] = "";
    int metrics_port = METRICS_PORT;

    static struct option long_opts[] = {
        {"daemon",     no_argument,       0, 'd'},
        {"foreground", no_argument,       0, 'f'},
        {"port",       required_argument, 0, 'p'},
        {"sync",       no_argument,       0, 's'},
        {"sync-slug",  required_argument, 0, 'S'},
        {"dry-run",    no_argument,       0, 'n'},
        {"status",     no_argument,       0, 't'},
        {"help",       no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "dfp:sS:nh", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'd': daemon_mode = 1; break;
            case 'f': daemon_mode = 0; break;
            case 'p': metrics_port = atoi(optarg); break;
            case 's': run_sync_once = 1; break;
            case 'S': strncpy(sync_slug, optarg, sizeof(sync_slug)-1); run_sync_once = 1; break;
            case 'n': dry_run = 1; break;
            case 't': show_status = 1; break;
            case 'h': usage(argv[0]); return 0;
            default: usage(argv[0]); return 1;
        }
    }

    if (parse_mirrors_conf(MIRRORS_CONF, &active_mirrors) != 0) {
        fprintf(stderr, "Failed to read %s\n", MIRRORS_CONF);
        return 1;
    }

    if (show_status) {
        for (int i = 0; i < active_mirrors.count; i++) {
            MirrorStatus st;
            if (read_status(active_mirrors.mirrors[i].slug, &st) == 0) {
                printf("%s|%ld|%d|%ld|%s|%s\n",
                    active_mirrors.mirrors[i].slug,
                    (long)st.last_sync, st.exit_code, st.disk_bytes,
                    st.status, st.upstream_health);
            } else {
                printf("%s|0|0|0|unknown|unknown\n", active_mirrors.mirrors[i].slug);
            }
        }
        free_mirror_list(&active_mirrors);
        return 0;
    }

    if (run_sync_once) {
        for (int i = 0; i < active_mirrors.count; i++) {
            if (sync_slug[0] && strcmp(active_mirrors.mirrors[i].slug, sync_slug) != 0) continue;
            run_sync(&active_mirrors.mirrors[i], "/var/www/html", dry_run);
        }
        free_mirror_list(&active_mirrors);
        return 0;
    }

    // Daemon mode
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);
    signal(SIGHUP, handle_signal);

    if (daemon_mode) daemonize();

    write_pid();

    // Start metrics server
    pthread_create(&metrics_thread, NULL, metrics_server, NULL);
    pthread_detach(metrics_thread);

    printf("ezmirord started (pid %d), metrics on :%d\n", getpid(), metrics_port);

    // Main loop - check and sync periodically
    while (run) {
        time_t now = time(NULL);

        // Sync check every minute
        for (int i = 0; i < active_mirrors.count && run; i++) {
            MirrorConfig *cfg = &active_mirrors.mirrors[i];
            int interval_secs = interval_to_seconds(cfg->interval);
            MirrorStatus st;
            time_t last = 0;
            if (read_status(cfg->slug, &st) == 0) last = st.last_sync;

            if (now - last >= interval_secs) {
                run_sync(cfg, "/var/www/html", 0);
            }
        }

        // Sleep for 60 seconds
        for (int i = 0; i < 60 && run; i++) {
            sleep(1);
        }
    }

    free_mirror_list(&active_mirrors);
    unlink(PID_FILE);
    return 0;
}
