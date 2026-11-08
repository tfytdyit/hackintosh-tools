#include "smc_lib.h"

int main(int argc, char **argv) {
    if (open_smc() != 0) return 1;
    Entry *e = NULL;
    int n = list_all(&e);
    if (argc > 1 && strcmp(argv[1], "list") == 0) {
        printf("%-5s %-5s %s\n", "KEY", "TYPE", "VALUE");
        for (int i = 0; i < n; i++) printf("%-5s %-5s %s\n", e[i].key, e[i].type, e[i].value);
    } else if (argc > 1 && strcmp(argv[1], "get") == 0 && argc > 2) {
        char b[32]; uint32_t type, size;
        if (smc_read(argv[2], &type, &size, b) != 0) { fprintf(stderr, "读不到键 %s\n", argv[2]); return 1; }
        char tn[8] = {0}; type_name(type, tn);
        char v[64]; decode(tn, b, size, v, sizeof(v));
        printf("%s  %s  %s\n", argv[2], tn, v);
    } else if (argc > 1 && strcmp(argv[1], "watch") == 0) {
        printf("共 %d 个键，持续监控（Ctrl-C 退出）\n", n);
        // 只监控数值型键
        for (int round = 0; round < 1; round++) { }
        int loops = (argc > 2) ? atoi(argv[2]) : 30;
        for (int l = 0; l < loops; l++) {
            printf("\033[2J\033[H[%02d] 键值快照\n", l);
            for (int i = 0; i < n; i++) {
                if (!e[i].numeric) continue;
                char b[32]; uint32_t type, size;
                if (smc_read(e[i].key, &type, &size, b) != 0) continue;
                char v[64]; decode(e[i].type, b, size, v, sizeof(v));
                printf("%-5s %-5s %s\n", e[i].key, e[i].type, v);
            }
            fflush(stdout);
            sleep(1);
        }
    } else {
        printf("共 %d 个键\n", n);
        for (int i = 0; i < n; i++) printf("%-5s %-5s %s\n", e[i].key, e[i].type, e[i].value);
    }
    free(e);
    IOServiceClose(conn);
    return 0;
}
