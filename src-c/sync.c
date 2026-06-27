#include "ezmirord.h"

static int is_sync_due(MirrorConfig *cfg) {
    MirrorStatus st;
    if (read_status(cfg->slug, &st) != 0) return 1;
    int interval_secs = interval_to_seconds(cfg->interval);
    return (time(NULL) - st.last_sync) >= interval_secs;
}

static int check_upstream_health(MirrorConfig *cfg) {
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    char cmd[1024];
    int ret;

    if (strcmp(cfg->method, "original") == 0) return 1;

    if (strcmp(cfg->method, "rsync") == 0 || strcmp(cfg->method, "mirror") == 0) {
        snprintf(cmd, sizeof(cmd), "timeout 10 rsync --list-only \"%s\" >/dev/null 2>&1", cfg->upstream);
    } else if (strcmp(cfg->method, "rclone-http") == 0) {
        snprintf(cmd, sizeof(cmd), "timeout 10 curl -sI \"%s\" >/dev/null 2>&1", cfg->upstream);
    } else if (strcmp(cfg->method, "rclone-sftp") == 0) {
        char remote[128];
        strncpy(remote, cfg->upstream, sizeof(remote)-1);
        char *colon = strchr(remote, ':');
        if (colon) *colon = '\0';
        snprintf(cmd, sizeof(cmd), "timeout 10 rclone lsd \"%s:\" >/dev/null 2>&1", remote);
    } else {
        return 0;
    }

    ret = system(cmd);

    clock_gettime(CLOCK_MONOTONIC, &t1);
    long ms = (t1.tv_sec - t0.tv_sec) * 1000 + (t1.tv_nsec - t0.tv_nsec) / 1000000;

    MirrorStatus st;
    memset(&st, 0, sizeof(st));
    st.last_sync = time(NULL);
    st.exit_code = ret == 0 ? 0 : 1;
    st.upstream_response_time_ms = (int)ms;
    st.upstream_health_checked = time(NULL);
    strncpy(st.upstream_health, ret == 0 ? "ok" : "fail", sizeof(st.upstream_health)-1);
    strncpy(st.status, ret == 0 ? "ok" : "error", sizeof(st.status)-1);

    // Get disk usage
    char dir_path[512];
    snprintf(dir_path, sizeof(dir_path), "%s/%s", "/var/www/html", cfg->slug);
    struct stat st_buf;
    if (stat(dir_path, &st_buf) == 0 && S_ISDIR(st_buf.st_mode)) {
        char du_cmd[1024];
        snprintf(du_cmd, sizeof(du_cmd), "du -sb \"%s\" 2>/dev/null | awk '{print $1}'", dir_path);
        FILE *du_fp = popen(du_cmd, "r");
        if (du_fp) {
            char buf[32];
            if (fgets(buf, sizeof(buf), du_fp)) st.disk_bytes = atol(buf);
            pclose(du_fp);
        }
    }

    update_status(cfg->slug, &st);
    return ret == 0 ? 1 : 0;
}

int run_sync(MirrorConfig *cfg, const char *mirror_dir, int dry_run) {
    MirrorStatus st;
    memset(&st, 0, sizeof(st));

    if (!check_upstream_health(cfg)) {
        fprintf(stderr, "[%s] upstream unreachable, skipping\n", cfg->slug);
        return 1;
    }

    if (!is_sync_due(cfg)) {
        printf("[%s] synced within %s, skipping\n", cfg->slug, cfg->interval);
        return 0;
    }

    char local_dir[512];
    snprintf(local_dir, sizeof(local_dir), "%s/%s", mirror_dir, cfg->slug);
    mkdir(local_dir, 0755);

    char cmd[4096];
    int ret = 0;

    if (strcmp(cfg->method, "rsync") == 0 || strcmp(cfg->method, "mirror") == 0) {
        char bw[32] = "";
        if (cfg->bandwidth > 0) snprintf(bw, sizeof(bw), "--bwlimit=%dm", cfg->bandwidth);
        snprintf(cmd, sizeof(cmd), "rsync -rlptv --delete --safe-links --hard-links "
            "--timeout=300 --contimeout=60 --exclude='*.part' --exclude='*.tmp' %s %s \"%s\" \"%s/\"",
            bw, dry_run ? "--dry-run" : "", cfg->upstream, local_dir);
    } else if (strcmp(cfg->method, "original") == 0) {
        printf("[%s] original mirror, no upstream sync\n", cfg->slug);
        return 0;
    } else if (strcmp(cfg->method, "rclone-http") == 0) {
        snprintf(cmd, sizeof(cmd), "rclone sync \":http,url=%s:\" \"%s/\" --transfers 4 "
            "--checkers 8 --retries 3 --exclude '*.part' %s",
            cfg->upstream, local_dir, dry_run ? "--dry-run" : "");
    } else {
        fprintf(stderr, "[%s] unknown method: %s\n", cfg->slug, cfg->method);
        return 1;
    }

    printf("[%s] syncing...\n", cfg->slug);
    ret = system(cmd);
    ret = WIFEXITED(ret) ? WEXITSTATUS(ret) : 1;

    st.last_sync = time(NULL);
    st.exit_code = ret;
    strncpy(st.status, ret == 0 ? "ok" : "error", sizeof(st.status)-1);
    strncpy(st.upstream_health, "ok", sizeof(st.upstream_health)-1);

    char du_cmd[1024];
    snprintf(du_cmd, sizeof(du_cmd), "du -sb \"%s\" 2>/dev/null | awk '{print $1}'", local_dir);
    FILE *du_fp = popen(du_cmd, "r");
    if (du_fp) {
        char buf[32];
        if (fgets(buf, sizeof(buf), du_fp)) st.disk_bytes = atol(buf);
        pclose(du_fp);
    }

    update_status(cfg->slug, &st);

    // Generate SHA256SUMS for top-level files
    if (!dry_run) {
        char sha_cmd[2048];
        snprintf(sha_cmd, sizeof(sha_cmd),
            "find \"%s\" -maxdepth 1 -type f ! -name '*.html' ! -name 'SHA256SUMS' "
            "! -name 'files.json' ! -name '*.torrent' -exec sha256sum {} \\; > \"%s/SHA256SUMS\" 2>/dev/null || true",
            local_dir, local_dir);
        (void)system(sha_cmd);
    }

    return ret;
}
