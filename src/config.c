#include "ezmirord.h"

int parse_mirrors_conf(const char *path, MirrorList *list) {
    FILE *fp = fopen(path, "r");
    if (!fp) return -1;

    list->mirrors = NULL;
    list->count = 0;
    list->capacity = 0;

    char line[2048];
    while (fgets(line, sizeof(line), fp)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\0') continue;

        char *nl = strchr(p, '\n');
        if (nl) *nl = '\0';

        if (list->count >= list->capacity) {
            int new_cap = list->capacity ? list->capacity * 2 : 16;
            MirrorConfig *tmp = realloc(list->mirrors, new_cap * sizeof(MirrorConfig));
            if (!tmp) { fclose(fp); return -1; }
            list->mirrors = tmp;
            list->capacity = new_cap;
        }

        MirrorConfig *cfg = &list->mirrors[list->count];
        memset(cfg, 0, sizeof(MirrorConfig));

        char *fields[12] = {0};
        int fi = 0;
        char *tok = p;
        while (fi < 12) {
            char *sep = strchr(tok, '|');
            if (sep) *sep = '\0';
            fields[fi++] = tok;
            if (!sep) break;
            tok = sep + 1;
        }

        if (fi >= 1) strncpy(cfg->slug, fields[0], sizeof(cfg->slug)-1);
        if (fi >= 2) strncpy(cfg->name, fields[1], sizeof(cfg->name)-1);
        if (fi >= 3) strncpy(cfg->desc, fields[2], sizeof(cfg->desc)-1);
        if (fi >= 4) strncpy(cfg->upstream, fields[3], sizeof(cfg->upstream)-1);
        if (fi >= 5) strncpy(cfg->method, fields[4], sizeof(cfg->method)-1);
        if (fi >= 6) strncpy(cfg->size, fields[5], sizeof(cfg->size)-1);
        if (fi >= 8) strncpy(cfg->interval, fields[7], sizeof(cfg->interval)-1);
        if (fi >= 9) cfg->bandwidth = atoi(fields[8]);
        if (fi >= 10) cfg->retention_days = atoi(fields[9]);
        if (fi >= 11) cfg->retention_max_gib = atoi(fields[10]);
        if (cfg->interval[0] == '\0') strcpy(cfg->interval, "6h");

        list->count++;
    }

    fclose(fp);
    return 0;
}

void free_mirror_list(MirrorList *list) {
    free(list->mirrors);
    list->mirrors = NULL;
    list->count = 0;
    list->capacity = 0;
}

int interval_to_seconds(const char *interval) {
    int num = atoi(interval);
    char unit = interval[strlen(interval)-1];
    switch (unit) {
        case 'm': case 'M': return num * 60;
        case 'h': case 'H': return num * 3600;
        case 'd': case 'D': return num * 86400;
        default: return num * 3600;
    }
}
