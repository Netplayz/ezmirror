#include "ezmirord.h"

static volatile int keep_running = 1;

void stop_metrics_server() {
    keep_running = 0;
}

void *metrics_server(void *arg) {
    (void)arg;
    int server_fd, client_fd;
    struct sockaddr_in addr;
    int opt = 1;

    server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return NULL;
    }

    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(METRICS_PORT);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        return NULL;
    }

    if (listen(server_fd, 5) < 0) {
        perror("listen");
        close(server_fd);
        return NULL;
    }

    struct timeval tv;
    tv.tv_sec = 1;
    tv.tv_usec = 0;

    while (keep_running) {
        fd_set fds;
        FD_ZERO(&fds);
        FD_SET(server_fd, &fds);

        int ret = select(server_fd + 1, &fds, NULL, NULL, &tv);
        if (ret < 0) break;
        if (ret == 0) continue;

        client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) continue;

        char buf[4096] = {0};
        recv(client_fd, buf, sizeof(buf) - 1, 0);

        // Parse request path
        char method[16], path[256];
        sscanf(buf, "%15s %255s", method, path);

        char response[8192];
        int resp_len = 0;

        if (strcmp(path, "/metrics") == 0) {
            // Generate Prometheus metrics
            MirrorList list;
            resp_len = snprintf(response, sizeof(response),
                "HTTP/1.1 200 OK\r\n"
                "Content-Type: text/plain; charset=utf-8\r\n"
                "Connection: close\r\n"
                "Access-Control-Allow-Origin: *\r\n"
                "\r\n"
                "# HELP ezmirror_last_sync Unix timestamp of last sync per mirror\n"
                "# TYPE ezmirror_last_sync gauge\n"
                "# HELP ezmirror_sync_exit_code Exit code of last sync (0=ok)\n"
                "# TYPE ezmirror_sync_exit_code gauge\n"
                "# HELP ezmirror_disk_bytes Disk usage in bytes per mirror\n"
                "# TYPE ezmirror_disk_bytes gauge\n"
                "# HELP ezmirror_upstream_health Upstream health (1=ok, 0=fail)\n"
                "# TYPE ezmirror_upstream_health gauge\n"
                "# HELP ezmirror_upstream_response_ms Upstream response time in ms\n"
                "# TYPE ezmirror_upstream_response_ms gauge\n"
                "# HELP ezmirror_upstream_health_checked Timestamp of last upstream check\n"
                "# TYPE ezmirror_upstream_health_checked gauge\n");

            if (parse_mirrors_conf(MIRRORS_CONF, &list) == 0) {
                for (int i = 0; i < list.count; i++) {
                    MirrorStatus st;
                    char slug_clean[128];
                    // Sanitize slug for Prometheus label
                    for (int j = 0; list.mirrors[i].slug[j]; j++) {
                        slug_clean[j] = list.mirrors[i].slug[j];
                        if (slug_clean[j] == '-') slug_clean[j] = '_';
                        slug_clean[j+1] = '\0';
                    }

                    if (read_status(list.mirrors[i].slug, &st) == 0) {
                        resp_len += snprintf(response + resp_len, sizeof(response) - resp_len,
                            "ezmirror_last_sync{mirror=\"%s\"} %ld\n"
                            "ezmirror_sync_exit_code{mirror=\"%s\"} %d\n"
                            "ezmirror_disk_bytes{mirror=\"%s\"} %ld\n"
                            "ezmirror_upstream_health{mirror=\"%s\"} %d\n"
                            "ezmirror_upstream_response_ms{mirror=\"%s\"} %d\n"
                            "ezmirror_upstream_health_checked{mirror=\"%s\"} %ld\n",
                            slug_clean, (long)st.last_sync,
                            slug_clean, st.exit_code,
                            slug_clean, st.disk_bytes,
                            slug_clean, strcmp(st.upstream_health, "ok") == 0 ? 1 : 0,
                            slug_clean, st.upstream_response_time_ms,
                            slug_clean, (long)st.upstream_health_checked);
                    } else {
                        resp_len += snprintf(response + resp_len, sizeof(response) - resp_len,
                            "ezmirror_last_sync{mirror=\"%s\"} 0\n"
                            "ezmirror_sync_exit_code{mirror=\"%s\"} -1\n"
                            "ezmirror_disk_bytes{mirror=\"%s\"} 0\n"
                            "ezmirror_upstream_health{mirror=\"%s\"} 0\n"
                            "ezmirror_upstream_response_ms{mirror=\"%s\"} 0\n"
                            "ezmirror_upstream_health_checked{mirror=\"%s\"} 0\n",
                            slug_clean, slug_clean, slug_clean, slug_clean, slug_clean, slug_clean);
                    }
                }
                free_mirror_list(&list);
            }
        } else if (strcmp(path, "/healthz") == 0) {
            int healthy = 1;
            MirrorList list;
            if (parse_mirrors_conf(MIRRORS_CONF, &list) == 0) {
                for (int i = 0; i < list.count; i++) {
                    MirrorStatus st;
                    if (read_status(list.mirrors[i].slug, &st) == 0) {
                        if (st.exit_code != 0) { healthy = 0; break; }
                    }
                }
                free_mirror_list(&list);
            }
            resp_len = snprintf(response, sizeof(response),
                "HTTP/1.1 %d OK\r\n"
                "Content-Type: application/json\r\n"
                "Connection: close\r\n"
                "\r\n"
                "{\"status\":\"%s\",\"service\":\"ezmirror\"}\n",
                healthy ? 200 : 503,
                healthy ? "healthy" : "degraded");
        } else {
            resp_len = snprintf(response, sizeof(response),
                "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        }

        send(client_fd, response, resp_len, 0);
        close(client_fd);
    }

    close(server_fd);
    return NULL;
}
