// sensmon.c — 黑苹果传感器监控（SMC + 系统指标）
// 编译: clang -O2 -o sensmon sensmon.c -framework IOKit -framework CoreFoundation
#include "smc_lib.h"
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <time.h>

typedef struct {
    double cpu_usage;         // 0-100
    double load[3];
    double temp_pkg;          // TC0P
    double temp_max_core;     // max(TC0C..TC6C)
    double cores[8];
    int core_count;
    double power_cpu;         // PC0R
    double power_pl;          // PCPT
    double vcore;             // VC0C
    int thermal_level;
    double batt_volt;         // V
    double batt_current;      // mA
    double batt_remain, batt_full, batt_pct;
    int ac_in, charging;
    int fans;
    double fan_rpm[4];
    double mem_total_gb, mem_used_gb, swap_used_gb;
    unsigned long long ctx_switches;
    int keys;
} Sample;

static int read_key_d(const char *key, double *out) {
    uint32_t type, size; char b[32]; char tn[5];
    if (smc_read(key, &type, &size, b) != 0) return -1;
    type_name(type, tn);
    char v[64];
    if (!decode(tn, b, size, v, sizeof(v))) return -1;
    *out = atof(v);
    return 0;
}

static int read_flag(const char *key) {
    uint32_t type, size; char b[32];
    if (smc_read(key, &type, &size, b) != 0 || size < 1) return -1;
    return (unsigned char)b[0];
}

static int read_key_i(const char *key, long *out) {
    double d;
    if (read_key_d(key, &d) != 0) return -1;
    *out = (long)d;
    return 0;
}

static double cpu_usage_since(host_cpu_load_info_data_t *prev) {
    host_cpu_load_info_data_t cur;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cur, &count) != KERN_SUCCESS)
        return 0;
    unsigned long long pbusy = prev->cpu_ticks[CPU_STATE_USER] + prev->cpu_ticks[CPU_STATE_SYSTEM] + prev->cpu_ticks[CPU_STATE_NICE];
    unsigned long long pidle = prev->cpu_ticks[CPU_STATE_IDLE];
    unsigned long long cbusy = cur.cpu_ticks[CPU_STATE_USER] + cur.cpu_ticks[CPU_STATE_SYSTEM] + cur.cpu_ticks[CPU_STATE_NICE];
    unsigned long long cidle = cur.cpu_ticks[CPU_STATE_IDLE];
    *prev = cur;
    unsigned long long dbusy = cbusy - pbusy, dtotal = (cbusy + cidle) - (pbusy + pidle);
    return dtotal ? 100.0 * (double)dbusy / (double)dtotal : 0.0;
}

static void mem_info(Sample *s) {
    uint64_t total = 0; size_t sz = sizeof(total);
    sysctlbyname("hw.memsize", &total, &sz, NULL, 0);
    vm_statistics64_data_t vm;
    mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &n) == KERN_SUCCESS) {
        uint64_t page = 4096;
        sysctlbyname("hw.pagesize", &page, &sz, NULL, 0);
        uint64_t used = ((uint64_t)vm.active_count + vm.wire_count + vm.compressor_page_count) * page;
        s->mem_total_gb = total / 1073741824.0;
        s->mem_used_gb = used / 1073741824.0;
    }
    struct xsw_usage xsu; sz = sizeof(xsu);
    if (sysctlbyname("vm.swapusage", &xsu, &sz, NULL, 0) == 0)
        s->swap_used_gb = xsu.xsu_used / 1073741824.0;
}

static void sample_all(Sample *s, host_cpu_load_info_data_t *prev) {
    memset(s, 0, sizeof(*s));
    s->cpu_usage = cpu_usage_since(prev);
    getloadavg(s->load, 3);

    long lv = 0;
    if (read_key_i("FNum", &lv) == 0) s->fans = (int)lv;
    else s->fans = 0;
    for (int i = 0; i < s->fans && i < 4; i++) {
        char k[8]; snprintf(k, sizeof(k), "F%dAc", i);
        double v = 0; if (read_key_d(k, &v) == 0) s->fan_rpm[i] = v;
    }
    read_key_d("TC0P", &s->temp_pkg);
    if (s->temp_pkg <= 0) read_key_d("TC0D", &s->temp_pkg);
    for (int c = 1; c <= 8; c++) {   // 本机 SMC 没有 TC0C，核心温度从 TC1C 开始（6 个物理核）
        char k[8]; snprintf(k, sizeof(k), "TC%dC", c);
        double v = 0;
        if (read_key_d(k, &v) == 0) { s->cores[s->core_count++] = v; if (v > s->temp_max_core) s->temp_max_core = v; }
    }
    read_key_d("PC0R", &s->power_cpu);
    read_key_d("PCPT", &s->power_pl);
    if (s->power_pl <= 0) read_key_d("PCTR", &s->power_pl);
    read_key_d("VC0C", &s->vcore);

    size_t sz = sizeof(int);
    if (sysctlbyname("machdep.xcpm.cpu_thermal_level", &s->thermal_level, &sz, NULL, 0) != 0) s->thermal_level = -1;

    long tmp;
    if (read_key_i("B0AV", &tmp) == 0) s->batt_volt = tmp / 1000.0;
    if (read_key_i("B0AC", &tmp) == 0) s->batt_current = (double)tmp;
    if (read_key_i("B0RM", &tmp) == 0) s->batt_remain = (double)tmp;
    if (read_key_i("B0FC", &tmp) == 0) s->batt_full = (double)tmp;
    if (read_key_i("BFCL", &tmp) == 0) s->batt_pct = (double)tmp;
    s->ac_in = read_flag("ACIN"); if (s->ac_in < 0) s->ac_in = 0;
    s->charging = (s->ac_in && s->batt_current > 50) ? 1 : 0;

    mem_info(s);
    s->keys = (int)smc_key_count();
}

static const char *temp_color(double t) {
    if (t >= 85) return "\033[1;31m";   // 红
    if (t >= 70) return "\033[1;33m";   // 黄
    if (t >= 50) return "\033[1;32m";   // 绿
    return "\033[1;36m";                // 青
}

static void print_json(Sample *s) {
    printf("{\"cpu_usage\":%.1f,\"load\":[%.2f,%.2f,%.2f],"
           "\"temp_pkg\":%.2f,\"temp_max_core\":%.2f,\"cores\":[",
           s->cpu_usage, s->load[0], s->load[1], s->load[2], s->temp_pkg, s->temp_max_core);
    for (int i = 0; i < s->core_count; i++) printf("%s%.2f", i ? "," : "", s->cores[i]);
    printf("],\"power_cpu\":%.2f,\"power_pl\":%.2f,\"vcore\":%.4f,\"thermal_level\":%d,"
           "\"battery\":{\"volt\":%.2f,\"current_ma\":%.0f,\"remain_mah\":%.0f,\"full_mah\":%.0f,\"pct\":%.0f,\"ac\":%d,\"charging\":%d},"
           "\"fans\":%d,\"fan_rpm\":[",
           s->power_cpu, s->power_pl, s->vcore, s->thermal_level,
           s->batt_volt, s->batt_current, s->batt_remain, s->batt_full, s->batt_pct, s->ac_in, s->charging, s->fans);
    for (int i = 0; i < s->fans; i++) printf("%s%.0f", i ? "," : "", s->fan_rpm[i]);
    printf("],\"memory_gb\":{\"total\":%.1f,\"used\":%.1f},\"smc_keys\":%d}\n",
           s->mem_total_gb, s->mem_used_gb, s->keys);
}

static void print_screen(Sample *s) {
    time_t now = time(NULL);
    char ts[32]; strftime(ts, sizeof(ts), "%H:%M:%S", localtime(&now));
    printf("\033[2J\033[H");
    printf("\033[1m黑苹果传感器监控\033[0m   %s     SMC 键 %d 个\n", ts, s->keys);
    printf("--------------------------------------------------------------\n");
    printf("CPU\n");
    printf("  使用率        \033[1;35m%5.1f%%\033[0m    负载 %.2f %.2f %.2f\n", s->cpu_usage, s->load[0], s->load[1], s->load[2]);
    printf("  封装温度      %s%5.1f °C\033[0m   (TC0P)\n", temp_color(s->temp_pkg), s->temp_pkg);
    printf("  核心温度     ");
    for (int i = 0; i < s->core_count; i++) printf(" %s%.0f\033[0m", temp_color(s->cores[i]), s->cores[i]);
    printf("   °C  (最高 %s%.1f\033[0m)\n", temp_color(s->temp_max_core), s->temp_max_core);
    printf("  功耗          %5.2f W   (PL/上限 %.2f W)   CPU 电压 %.4f V\n", s->power_cpu, s->power_pl, s->vcore);
    printf("  热压力等级    %d%s\n", s->thermal_level, s->thermal_level <= 0 ? "（正常）" : "");
    printf("\n电池\n");
    printf("  电量          %5.0f%%    %s   电压 %.2f V\n", s->batt_pct,
           s->ac_in ? (s->charging ? "\033[1;33m充电中\033[0m" : "\033[1;32m已接电源（未充电）\033[0m")
                    : "\033[1;36m放电中\033[0m",
           s->batt_volt);
    printf("  电流          %5.0f mA   剩余 %.0f / 满 %.0f mAh\n", s->batt_current, s->batt_remain, s->batt_full);
    printf("\n风扇\n");
    if (s->fans <= 0) printf("  \033[2m没有风扇传感器（FNum=0，本机 SMC 未暴露风扇键）\033[0m\n");
    else for (int i = 0; i < s->fans; i++) printf("  风扇 %d        %5.0f RPM\n", i, s->fan_rpm[i]);
    printf("\n内存\n");
    printf("  已用          %5.1f / %.1f GB    交换 %.2f GB\n", s->mem_used_gb, s->mem_total_gb, s->swap_used_gb);
    printf("--------------------------------------------------------------\n");
    printf("\033[2mCtrl-C 退出\033[0m\n");
}

int main(int argc, char **argv) {
    int json = 0, once = 0, loops = 0, interval_ms = 1000;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--json")) json = 1;
        else if (!strcmp(argv[i], "--once")) once = 1;
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) loops = atoi(argv[++i]);
        else if (!strcmp(argv[i], "-i") && i + 1 < argc) interval_ms = atoi(argv[++i]);
        else { fprintf(stderr, "用法: %s [--json] [--once] [-n 次数] [-i 毫秒]\n", argv[0]); return 2; }
    }
    if (open_smc() != 0) return 1;
    host_cpu_load_info_data_t prev;
    mach_msg_type_number_t cnt = HOST_CPU_LOAD_INFO_COUNT;
    host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&prev, &cnt);

    Sample s;
    for (int l = 0; loops == 0 || l < loops; l++) {
        if (l > 0 || loops == 0) usleep(interval_ms * 1000);
        sample_all(&s, &prev);
        if (json) print_json(&s);
        else print_screen(&s);
        fflush(stdout);
        if (once) break;
    }
    IOServiceClose(conn);
    return 0;
}
