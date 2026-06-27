#include "ezmirord.h"

int update_status(const char *slug, MirrorStatus *st) {
    FILE *fp = fopen(STATUS_FILE, "r");
    char *json = NULL;
    long fsize;

    if (fp) {
        fseek(fp, 0, SEEK_END);
        fsize = ftell(fp);
        rewind(fp);
        json = malloc(fsize + 1);
        if (fread(json, 1, fsize, fp) != (size_t)fsize) { free(json); json = NULL; }
        json[fsize] = '\0';
        fclose(fp);
    }

    if (!json) {
        json = strdup("{\"generated\":0,\"mirrors\":{}}");
    }

    char *mirrors_start = strstr(json, "\"mirrors\"");
    if (!mirrors_start) {
        free(json);
        json = strdup("{\"generated\":0,\"mirrors\":{}}");
        mirrors_start = strstr(json, "\"mirrors\"");
    }

    char *insert_point = strchr(mirrors_start, '{');
    if (!insert_point) { free(json); return -1; }
    insert_point++;

    char entry[2048];
    snprintf(entry, sizeof(entry),
        "\"%s\":{"
        "\"last_sync\":%ld,"
        "\"exit_code\":%d,"
        "\"disk_bytes\":%ld,"
        "\"status\":\"%s\","
        "\"upstream_health\":\"%s\","
        "\"upstream_health_checked\":%ld,"
        "\"upstream_response_time_ms\":%d"
        "},",
        slug, (long)st->last_sync, st->exit_code, st->disk_bytes,
        st->status, st->upstream_health,
        (long)st->upstream_health_checked, st->upstream_response_time_ms);

    size_t new_len = strlen(json) + strlen(entry) + 64;
    char *new_json = malloc(new_len);

    // Rebuild JSON
    char *slug_start = strstr(json, entry);
    if (slug_start) {
        char *slug_end = strchr(slug_start, '}');
        if (slug_end) slug_end = strchr(slug_end + 1, ',');
        if (!slug_end) slug_end = strchr(slug_start, '}');
        if (slug_end) slug_end++;
        size_t prefix_len = slug_start - json;
        snprintf(new_json, new_len, "%.*s%s%s", (int)prefix_len, json, entry, slug_end ? slug_end : "");
    } else {
        snprintf(new_json, new_len, "%.*s%s%s", (int)(insert_point - json), json, entry, insert_point);
    }

    // Update generated timestamp
    time_t now = time(NULL);
    char ts_field[64];
    snprintf(ts_field, sizeof(ts_field), "\"generated\":%ld", (long)now);
    char *ts_start = strstr(new_json, "\"generated\"");
    if (ts_start) {
        char *ts_val = strchr(ts_start, ':');
        if (ts_val) {
            ts_val++;
            while (*ts_val == ' ') ts_val++;
            char *end = ts_val;
            while (*end && *end != ',' && *end != '}') end++;
            size_t ts_len = ts_val - new_json;
            size_t rest_len = strlen(end);
            memmove(new_json + ts_len + strlen(ts_field) - 1, end, rest_len + 1);
            memcpy(new_json + ts_len, ts_field, strlen(ts_field));
        }
    }

    fp = fopen(STATUS_FILE ".tmp", "w");
    if (!fp) { free(json); free(new_json); return -1; }
    fputs(new_json, fp);
    fclose(fp);

    rename(STATUS_FILE ".tmp", STATUS_FILE);
    (void)chown(STATUS_FILE, 33, 33);
    free(json);
    free(new_json);
    return 0;
}

int read_status(const char *slug, MirrorStatus *st) {
    memset(st, 0, sizeof(MirrorStatus));
    FILE *fp = fopen(STATUS_FILE, "r");
    if (!fp) return -1;

    fseek(fp, 0, SEEK_END);
    long size = ftell(fp);
    rewind(fp);
    char *json = malloc(size + 1);
    if (!json) { fclose(fp); return -1; }
    if (fread(json, 1, size, fp) != (size_t)size) { free(json); fclose(fp); return -1; }
    json[size] = '\0';
    fclose(fp);

    char search[128];
    snprintf(search, sizeof(search), "\"%s\"", slug);
    char *p = strstr(json, search);
    if (!p) { free(json); return -1; }

    p = strchr(p, '{');
    if (!p) { free(json); return -1; }

    char *end = strchr(p, '}');
    if (!end) { free(json); return -1; }
    *end = '\0';

    char *val;
    if ((val = strstr(p, "\"last_sync\""))) st->last_sync = atol(val + 11);
    if ((val = strstr(p, "\"exit_code\""))) st->exit_code = atoi(val + 11);
    if ((val = strstr(p, "\"disk_bytes\""))) st->disk_bytes = atol(val + 12);
    if ((val = strstr(p, "\"status\""))) {
        val = strchr(val, ':') + 2;
        char *q = strchr(val, '"');
        if (q) { *q = '\0'; strncpy(st->status, val, sizeof(st->status)-1); }
    }
    if ((val = strstr(p, "\"upstream_health\""))) {
        val = strchr(val, ':') + 2;
        char *q = strchr(val, '"');
        if (q) { *q = '\0'; strncpy(st->upstream_health, val, sizeof(st->upstream_health)-1); }
    }
    if ((val = strstr(p, "\"upstream_health_checked\""))) st->upstream_health_checked = atol(val + 24);
    if ((val = strstr(p, "\"upstream_response_time_ms\""))) st->upstream_response_time_ms = atoi(val + 28);

    *end = '}';
    free(json);
    return 0;
}
