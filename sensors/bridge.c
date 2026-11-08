// bridge.c — 把 SMC 传感器、系统信息和网络速率打包成简单 C 接口供 SwiftUI 调用
#include "smc_lib.h"

#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/mount.h>
#include <net/route.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/time.h>
#include <time.h>
#include <string.h>
#include <stdlib.h>
#include <IOKit/IOKitLib.h>
#include <libproc.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>

static int g_smc_open = 0;

int sbi_open(void) {
    if (!g_smc_open) g_smc_open = (open_smc() == 0);
    return g_smc_open ? 0 : -1;
}

int sbi_smc_key_count(void) { return g_smc_open ? (int)smc_key_count() : 0; }

static int rd_d(const char *key, double *out) {
    uint32_t type, size; char b[32]; char tn[8];
    if (smc_read(key, &type, &size, b) != 0) return -1;
    type_name(type, tn);
    char v[64];
    if (!decode(tn, b, size, v, sizeof(v))) return -1;
    *out = atof(v);
    return 0;
}

static int rd_i(const char *key, long *out) {
    double d;
    if (rd_d(key, &d) != 0) return -1;
    *out = (long)d;
    return 0;
}

static int rd_flag(const char *key) {
    uint32_t type, size; char b[32];
    if (smc_read(key, &type, &size, b) != 0 || size < 1) return -1;
    return (unsigned char)b[0];
}

double sbi_temp_pkg(void) {
    double v = 0;
    if (rd_d("TC0P", &v) != 0) { v = 0; rd_d("TC0D", &v); }
    return v;
}

int sbi_core_count(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    int n = 0;
    for (int c = 1; c <= 8; c++) {
        char k[8]; snprintf(k, sizeof(k), "TC%dC", c);
        double v = 0;
        if (rd_d(k, &v) == 0) n++;
    }
    cached = n;
    return n;
}

double sbi_temp_core(int idx) {
    char k[8]; snprintf(k, sizeof(k), "TC%dC", idx + 1);
    double v = 0;
    if (rd_d(k, &v) != 0) return 0;
    return v;
}

double sbi_power_cpu(void) { double v = 0; rd_d("PC0R", &v); return v; }
double sbi_power_pl(void)  { double v = 0; if (rd_d("PCPT", &v) != 0 || v <= 0) rd_d("PCTR", &v); return v; }
double sbi_vcore(void)     { double v = 0; rd_d("VC0C", &v); return v; }

int sbi_fan_count(void) {
    long n = 0;
    if (rd_i("FNum", &n) != 0) return 0;
    if (n < 0 || n > 8) return 0;
    return (int)n;
}

double sbi_fan_rpm(int idx) {
    char k[8]; snprintf(k, sizeof(k), "F%dAc", idx);
    double v = 0;
    if (rd_d(k, &v) != 0) return 0;
    return v;
}

double sbi_batt_volt(void)    { double v = 0; rd_d("B0AV", &v); return v / 1000.0; }
double sbi_batt_current(void) { double v = 0; rd_d("B0AC", &v); return v; }
double sbi_batt_remain(void)  { double v = 0; rd_d("B0RM", &v); return v; }
double sbi_batt_full(void)    { double v = 0; rd_d("B0FC", &v); return v; }
double sbi_batt_pct(void)     { double v = 0; rd_d("BFCL", &v); return v; }

int sbi_ac_in(void) {
    int f = rd_flag("ACIN");
    return f > 0 ? 1 : 0;
}

int sbi_batt_present(void) {
    double v = 0;
    return (rd_d("B0FC", &v) == 0 && v > 0) ? 1 : 0;
}

/* ---------------- CPU / 内存 ---------------- */

double sbi_cpu_usage(void) {
    static host_cpu_load_info_data_t prev;
    static int inited = 0;
    host_cpu_load_info_data_t cur;
    mach_msg_type_number_t cnt = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&cur, &cnt) != KERN_SUCCESS)
        return 0;
    if (!inited) { prev = cur; inited = 1; return 0; }
    unsigned long long pbusy = prev.cpu_ticks[CPU_STATE_USER] + prev.cpu_ticks[CPU_STATE_SYSTEM] + prev.cpu_ticks[CPU_STATE_NICE];
    unsigned long long pidle = prev.cpu_ticks[CPU_STATE_IDLE];
    unsigned long long cbusy = cur.cpu_ticks[CPU_STATE_USER] + cur.cpu_ticks[CPU_STATE_SYSTEM] + cur.cpu_ticks[CPU_STATE_NICE];
    unsigned long long cidle = cur.cpu_ticks[CPU_STATE_IDLE];
    prev = cur;
    unsigned long long dbusy = cbusy - pbusy, dtotal = (cbusy + cidle) - (pbusy + pidle);
    return dtotal ? 100.0 * (double)dbusy / (double)dtotal : 0.0;
}

double sbi_load1(void)  { double l[3]; if (getloadavg(l, 3) < 0) return 0; return l[0]; }
double sbi_load5(void)  { double l[3]; if (getloadavg(l, 3) < 0) return 0; return l[1]; }
double sbi_load15(void) { double l[3]; if (getloadavg(l, 3) < 0) return 0; return l[2]; }

double sbi_mem_total_gb(void) {
    uint64_t total = 0; size_t sz = sizeof(total);
    sysctlbyname("hw.memsize", &total, &sz, NULL, 0);
    return total / 1073741824.0;
}

double sbi_mem_used_gb(void) {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &n) != KERN_SUCCESS)
        return 0;
    uint64_t page = 4096; size_t sz = sizeof(page);
    sysctlbyname("hw.pagesize", &page, &sz, NULL, 0);
    uint64_t used = ((uint64_t)vm.active_count + vm.wire_count + vm.compressor_page_count) * page;
    return used / 1073741824.0;
}

double sbi_swap_used_gb(void) {
    struct xsw_usage xsu; size_t sz = sizeof(xsu);
    if (sysctlbyname("vm.swapusage", &xsu, &sz, NULL, 0) != 0) return 0;
    return xsu.xsu_used / 1073741824.0;
}

double sbi_thermal_level(void) {
    int v = -1; size_t sz = sizeof(v);
    if (sysctlbyname("machdep.xcpm.cpu_thermal_level", &v, &sz, NULL, 0) != 0) return -1;
    return v;
}

double sbi_uptime(void) {
    struct timeval boot; size_t sz = sizeof(boot);
    if (sysctlbyname("kern.boottime", &boot, &sz, NULL, 0) != 0) return 0;
    return (double)(time(NULL) - boot.tv_sec);
}

/* ---------------- 网络 ---------------- */

static char g_ifname[IFNAMSIZ] = {0};

static int read_interface_choose(uint64_t *rx, uint64_t *tx, char *name, size_t nameLen) {
    int mib[6] = { CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_IFLIST2, 0 };
    size_t len = 0;
    if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0) return -1;
    char *buf = malloc(len);
    if (!buf) return -1;
    if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) { free(buf); return -1; }
    char *p = buf, *end = buf + len;
    int found_en0 = 0;
    uint64_t best = 0;
    char bestName[IFNAMSIZ] = {0};
    uint64_t bestRx = 0, bestTx = 0;
    while (p + sizeof(struct if_msghdr) <= end) {
        struct if_msghdr *ifm = (struct if_msghdr *)p;
        if (ifm->ifm_msglen == 0) break;
        if (ifm->ifm_type == RTM_IFINFO2 && ifm->ifm_msglen >= sizeof(struct if_msghdr2)) {
            struct if_msghdr2 *if2 = (struct if_msghdr2 *)p;
            char nm[IFNAMSIZ] = {0};
            if_indextoname(if2->ifm_index, nm);
            uint64_t r = if2->ifm_data.ifi_ibytes;
            uint64_t t = if2->ifm_data.ifi_obytes;
            if (strcmp(nm, "en0") == 0) {
                *rx = r; *tx = t; found_en0 = 1;
                if (name) snprintf(name, nameLen, "%s", nm);
            } else if (!found_en0 && strncmp(nm, "lo", 2) != 0 && r + t > best) {
                best = r + t; bestRx = r; bestTx = t;
                snprintf(bestName, sizeof(bestName), "%s", nm);
            }
        }
        p += ifm->ifm_msglen;
    }
    if (!found_en0) {
        *rx = bestRx; *tx = bestTx;
        if (name) snprintf(name, nameLen, "%s", bestName);
    }
    free(buf);
    return 0;
}

static void net_snapshot(uint64_t *rx, uint64_t *tx) {
    char nm[IFNAMSIZ] = {0};
    if (read_interface_choose(rx, tx, nm, sizeof(nm)) != 0) { *rx = 0; *tx = 0; return; }
    snprintf(g_ifname, sizeof(g_ifname), "%s", nm);
}

void sbi_net_rates(double *down_bps, double *up_bps) {
    static uint64_t prevRx = 0, prevTx = 0;
    static double prevT = 0;
    static int inited = 0;
    uint64_t rx = 0, tx = 0;
    net_snapshot(&rx, &tx);
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    double now = ts.tv_sec + ts.tv_nsec / 1e9;
    if (!inited) { prevRx = rx; prevTx = tx; prevT = now; inited = 1; *down_bps = 0; *up_bps = 0; return; }
    double dt = now - prevT;
    if (dt <= 0.001) dt = 1.0;
    double dRx = (double)(rx - prevRx), dTx = (double)(tx - prevTx);
    prevRx = rx; prevTx = tx; prevT = now;
    *down_bps = dRx / dt;
    *up_bps = dTx / dt;
}

void sbi_net_totals(double *rx_bytes, double *tx_bytes) {
    static uint64_t baseRx = 0, baseTx = 0;
    static int inited = 0;
    uint64_t rx = 0, tx = 0;
    net_snapshot(&rx, &tx);
    if (!inited) { baseRx = rx; baseTx = tx; inited = 1; }
    *rx_bytes = (double)(rx - baseRx);
    *tx_bytes = (double)(tx - baseTx);
}

const char *sbi_net_interface(void) {
    if (g_ifname[0] == 0) { uint64_t a, b; net_snapshot(&a, &b); }
    return g_ifname;
}

const char *sbi_net_ipv4(void) {
    static char ip[64] = {0};
    ip[0] = 0;
    if (g_ifname[0] == 0) { uint64_t a, b; net_snapshot(&a, &b); }
    struct ifaddrs *ifa = NULL;
    if (getifaddrs(&ifa) != 0) return ip;
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (strcmp(p->ifa_name, g_ifname) != 0) continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)p->ifa_addr;
        char tmp[INET_ADDRSTRLEN] = {0};
        inet_ntop(AF_INET, &sin->sin_addr, tmp, sizeof(tmp));
        snprintf(ip, sizeof(ip), "%s", tmp);
        break;
    }
    freeifaddrs(ifa);
    return ip;
}

int sbi_net_link_up(void) {
    struct ifaddrs *ifa = NULL;
    int up = 0;
    if (getifaddrs(&ifa) != 0) return 0;
    for (struct ifaddrs *p = ifa; p; p = p->ifa_next) {
        if (strcmp(p->ifa_name, g_ifname) != 0) continue;
        if (p->ifa_flags & IFF_UP) { up = 1; break; }
    }
    freeifaddrs(ifa);
    return up;
}

/* ---------------- 磁盘 / 硬件信息 ---------------- */

double sbi_disk_total_gb(void) {
    struct statfs st;
    if (statfs("/", &st) != 0) return 0;
    return (double)st.f_blocks * st.f_bsize / 1073741824.0;
}

double sbi_disk_free_gb(void) {
    struct statfs st;
    if (statfs("/", &st) != 0) return 0;
    return (double)st.f_bavail * st.f_bsize / 1073741824.0;
}

const char *sbi_nvme_model(void) {
    static char model[128] = {0};
    static int tried = 0;
    if (tried) return model;
    tried = 1;
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeController"), &it) != kIOReturnSuccess && it == 0)
        return model;
    io_object_t obj = IOIteratorNext(it);
    if (obj) {
        CFTypeRef v = IORegistryEntryCreateCFProperty(obj, CFSTR("Model Number"), kCFAllocatorDefault, 0);
        if (v && CFGetTypeID(v) == CFStringGetTypeID())
            CFStringGetCString((CFStringRef)v, model, sizeof(model), kCFStringEncodingUTF8);
        if (v) CFRelease(v);
        IOObjectRelease(obj);
    }
    if (it) IOObjectRelease(it);
    return model;
}

const char *sbi_cpu_brand(void) {
    static char brand[128] = {0};
    static int tried = 0;
    if (tried) return brand;
    tried = 1;
    size_t sz = sizeof(brand);
    if (sysctlbyname("machdep.cpu.brand_string", brand, &sz, NULL, 0) != 0)
        snprintf(brand, sizeof(brand), "Unknown CPU");
    return brand;
}

const char *sbi_model(void) {
    static char model[64] = {0};
    static int tried = 0;
    if (tried) return model;
    tried = 1;
    size_t sz = sizeof(model);
    if (sysctlbyname("hw.model", model, &sz, NULL, 0) != 0)
        snprintf(model, sizeof(model), "Mac");
    return model;
}

int sbi_physical_cpus(void) { int v = 0; size_t sz = sizeof(v); sysctlbyname("hw.physicalcpu", &v, &sz, NULL, 0); return v; }
int sbi_logical_cpus(void)  { int v = 0; size_t sz = sizeof(v); sysctlbyname("hw.logicalcpu", &v, &sz, NULL, 0); return v; }


/* ---------------- 内存细分 / 内存压力 ---------------- */

static uint64_t page_size_bytes(void) {
    uint64_t page = 4096; size_t sz = sizeof(page);
    sysctlbyname("hw.pagesize", &page, &sz, NULL, 0);
    return page;
}

static int vm_stats(vm_statistics64_data_t *vm) {
    mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    return host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)vm, &n) == KERN_SUCCESS;
}

double sbi_mem_wired_gb(void) {
    vm_statistics64_data_t vm;
    if (!vm_stats(&vm)) return 0;
    return (double)vm.wire_count * page_size_bytes() / 1073741824.0;
}

double sbi_mem_compressed_gb(void) {
    vm_statistics64_data_t vm;
    if (!vm_stats(&vm)) return 0;
    return (double)vm.compressor_page_count * page_size_bytes() / 1073741824.0;
}

double sbi_mem_active_gb(void) {
    vm_statistics64_data_t vm;
    if (!vm_stats(&vm)) return 0;
    return (double)vm.active_count * page_size_bytes() / 1073741824.0;
}

int sbi_mem_pressure(void) {
    int v = -1; size_t sz = sizeof(v);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &v, &sz, NULL, 0) != 0) return -1;
    return v;   /* 1 正常 / 2 警告 / 4 严重 */
}

/* ---------------- 电池细节（IORegistry AppleSmartBattery） ---------------- */

static int batt_int(const char *key) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!s) return 0;
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(s, k, kCFAllocatorDefault, 0);
    IOObjectRelease(s);
    int out = 0;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID())
            CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &out);
        CFRelease(v);
    }
    if (k) CFRelease(k);
    return out;
}

int sbi_batt_cycle(void)      { return batt_int("CycleCount"); }
int sbi_batt_design_mah(void) { return batt_int("DesignCapacity"); }
int sbi_batt_maxraw_mah(void) {
    int v = batt_int("AppleRawMaxCapacity");
    if (v <= 0) v = batt_int("MaxCapacity");
    return v;
}
int sbi_batt_time_remaining(void) { return batt_int("TimeRemaining"); }

/* ---------------- 磁盘读写速率（IOBlockStorageDriver.Statistics） ---------------- */

static uint64_t disk_bytes(int write) {
    io_iterator_t it = 0;
    uint64_t total = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) != kIOReturnSuccess)
        return 0;
    io_object_t s;
    while ((s = IOIteratorNext(it))) {
        CFTypeRef st = IORegistryEntryCreateCFProperty(s, CFSTR("Statistics"), kCFAllocatorDefault, 0);
        if (st && CFGetTypeID(st) == CFDictionaryGetTypeID()) {
            CFStringRef k = CFStringCreateWithCString(NULL, write ? "Bytes (Write)" : "Bytes (Read)", kCFStringEncodingUTF8);
            CFTypeRef v = CFDictionaryGetValue((CFDictionaryRef)st, k);
            if (v && CFGetTypeID(v) == CFNumberGetTypeID()) {
                long long x = 0;
                CFNumberGetValue((CFNumberRef)v, kCFNumberLongLongType, &x);
                total += (uint64_t)x;
            }
            if (k) CFRelease(k);
        }
        if (st) CFRelease(st);
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return total;
}

static double mach_seconds(void) {
    static mach_timebase_info_data_t tb;
    static int init = 0;
    if (!init) { mach_timebase_info(&tb); init = 1; }
    return (double)mach_absolute_time() * (double)tb.numer / (double)tb.denom / 1e9;
}

static uint64_t d_prev_r = 0, d_prev_w = 0, d_base_r = 0, d_base_w = 0, d_tot_r = 0, d_tot_w = 0;
static double d_prev_t = 0, d_rate_r = 0, d_rate_w = 0;
static double d_last_call = 0;

static void disk_update(void) {
    double now = mach_seconds();
    if (now - d_last_call < 0.2) return;          /* 同一 tick 内只采一次 */
    d_last_call = now;
    uint64_t r = disk_bytes(0), w = disk_bytes(1);
    if (d_prev_t == 0) { d_base_r = r; d_base_w = w; }
    if (d_prev_t > 0 && now > d_prev_t) {
        double dt = now - d_prev_t;
        d_rate_r = (double)(r - d_prev_r) / dt;
        d_rate_w = (double)(w - d_prev_w) / dt;
    }
    d_prev_r = r; d_prev_w = w; d_prev_t = now;
    d_tot_r = r - d_base_r; d_tot_w = w - d_base_w;
}

void sbi_disk_io(double *read_bps, double *write_bps, double *read_total, double *write_total) {
    disk_update();
    if (read_bps)   *read_bps = d_rate_r;
    if (write_bps)  *write_bps = d_rate_w;
    if (read_total) *read_total = (double)d_tot_r;
    if (write_total)*write_total = (double)d_tot_w;
}

/* ---------------- 进程（libproc，CPU% 为单核百分比） ---------------- */

typedef struct { pid_t pid; uint64_t cpu_ns; } ProcPrev;
static ProcPrev p_prev[1024];
static int p_prev_n = 0;
static double p_prev_t = 0;

typedef struct { pid_t pid; double cpu; double rss_mb; char name[64]; } ProcInfo;
static ProcInfo g_list[2048];
static int g_cnt = 0;
static double g_list_t = 0;

static int cmp_cpu_desc(const void *a, const void *b) {
    const ProcInfo *x = (const ProcInfo *)a, *y = (const ProcInfo *)b;
    if (x->cpu < y->cpu) return 1;
    if (x->cpu > y->cpu) return -1;
    return 0;
}
static int cmp_mem_desc(const void *a, const void *b) {
    const ProcInfo *x = (const ProcInfo *)a, *y = (const ProcInfo *)b;
    if (x->rss_mb < y->rss_mb) return 1;
    if (x->rss_mb > y->rss_mb) return -1;
    return 0;
}

static void procs_update(double now) {
    if (g_list_t > 0 && now - g_list_t < 0.5) return;
    double dt = (g_list_t > 0 && now > g_list_t) ? (now - g_list_t) : 0;
    int cap = proc_listallpids(NULL, 0);
    if (cap <= 0) return;
    pid_t *pids = (pid_t *)malloc(sizeof(pid_t) * (size_t)cap);
    if (!pids) return;
    int n = proc_listallpids(pids, (int)(sizeof(pid_t) * (size_t)cap));
    if (n <= 0) { free(pids); return; }

    int cnt = 0;
    for (int i = 0; i < n && cnt < 2048; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct rusage_info_v4 ri;
        uint64_t cpu = 0;
        int gotcpu = (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) == 0);
        if (gotcpu) cpu = ri.ri_user_time + ri.ri_system_time;
        struct proc_taskinfo ti;
        int got = (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, sizeof(ti)) == sizeof(ti));
        if (!got && !gotcpu) continue;
        ProcInfo *p = &g_list[cnt];
        memset(p, 0, sizeof(*p));
        p->pid = pid;
        p->rss_mb = got ? (double)ti.pti_resident_size / 1048576.0 : 0;
        if (dt > 0 && gotcpu) {
            uint64_t prev = 0;
            for (int j = 0; j < p_prev_n; j++) if (p_prev[j].pid == pid) { prev = p_prev[j].cpu_ns; break; }
            if (cpu > prev) p->cpu = (double)(cpu - prev) / (dt * 1e9) * 100.0;
        }
        proc_name(pid, p->name, sizeof(p->name));
        if (p->name[0] == 0) snprintf(p->name, sizeof(p->name), "pid %d", pid);
        cnt++;
    }
    free(pids);

    p_prev_n = 0;
    for (int i = 0; i < cnt && p_prev_n < 1024; i++) {
        struct rusage_info_v4 ri;
        if (proc_pid_rusage(g_list[i].pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) continue;
        p_prev[p_prev_n].pid = g_list[i].pid;
        p_prev[p_prev_n].cpu_ns = ri.ri_user_time + ri.ri_system_time;
        p_prev_n++;
    }
    p_prev_t = now;
    g_cnt = cnt;
    g_list_t = now;
}

int sbi_top_procs(char *buf, int len, int by_memory) {
    if (!buf || len < 64) return 0;
    procs_update(mach_seconds());
    if (g_cnt <= 0) return 0;
    ProcInfo *tmp = (ProcInfo *)malloc(sizeof(ProcInfo) * (size_t)g_cnt);
    if (!tmp) return 0;
    memcpy(tmp, g_list, sizeof(ProcInfo) * (size_t)g_cnt);
    qsort(tmp, (size_t)g_cnt, sizeof(ProcInfo), by_memory ? cmp_mem_desc : cmp_cpu_desc);
    int off = 0, out = 0;
    for (int i = 0; i < g_cnt && out < 8 && off < len - 96; i++) {
        ProcInfo *p = &tmp[i];
        if (by_memory) { if (p->rss_mb < 1.0) continue; }
        else { if (p->cpu < 0.05) continue; }
        off += snprintf(buf + off, (size_t)(len - off), "%d|%.1f|%.0f|%s\n",
                        p->pid, p->cpu, p->rss_mb, p->name);
        out++;
    }
    free(tmp);
    return out;
}

/* ---------------- SMC 全量导出 ---------------- */

int sbi_smc_dump(char *buf, int len) {
    if (!g_smc_open || !buf || len < 64) return 0;
    Entry *e = NULL;
    int n = list_all(&e);
    int off = 0;
    for (int i = 0; i < n && off < len - 96; i++)
        off += snprintf(buf + off, (size_t)(len - off), "%s|%s|%s\n", e[i].key, e[i].type, e[i].value);
    free(e);
    return n;
}

/* ---------------- 硬件标识（序列号 / board-id） ---------------- */

static const char *platform_prop(const char *key, char *out, size_t len) {
    out[0] = 0;
    io_service_t p = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
    if (!p) return out;
    CFStringRef k = CFStringCreateWithCString(NULL, key, kCFStringEncodingUTF8);
    CFTypeRef v = IORegistryEntryCreateCFProperty(p, k, kCFAllocatorDefault, 0);
    IOObjectRelease(p);
    if (v) {
        if (CFGetTypeID(v) == CFStringGetTypeID()) {
            CFStringGetCString((CFStringRef)v, out, (CFIndex)len, kCFStringEncodingUTF8);
        } else if (CFGetTypeID(v) == CFDataGetTypeID()) {
            CFDataRef d = (CFDataRef)v;
            CFIndex n = CFDataGetLength(d);
            if (n > (CFIndex)len - 1) n = (CFIndex)len - 1;
            CFDataGetBytes(d, CFRangeMake(0, n), (UInt8 *)out);
            out[n] = 0;
        }
        CFRelease(v);
    }
    if (k) CFRelease(k);
    return out;
}

const char *sbi_serial(void) {
    static char s[64] = {0};
    static int tried = 0;
    if (!tried) { tried = 1; platform_prop("IOPlatformSerialNumber", s, sizeof(s)); }
    return s;
}

const char *sbi_board_id(void) {
    static char s[64] = {0};
    static int tried = 0;
    if (!tried) { tried = 1; platform_prop("board-id", s, sizeof(s)); }
    return s;
}

/* ---------- GPU 占用（Intel 核显） ---------- */
static int gpu_stat_int(const char *key) {
    io_service_t acc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IntelAccelerator"));
    if (!acc) acc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"));
    if (!acc) return -1;
    int result = -1;
    CFTypeRef statsRef = IORegistryEntryCreateCFProperty(acc, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
    if (statsRef && CFGetTypeID(statsRef) == CFDictionaryGetTypeID()) {
        CFStringRef keyRef = CFStringCreateWithCString(kCFAllocatorDefault, key, kCFStringEncodingUTF8);
        CFNumberRef n = keyRef ? (CFNumberRef)CFDictionaryGetValue((CFDictionaryRef)statsRef, keyRef) : NULL;
        if (n && CFGetTypeID(n) == CFNumberGetTypeID()) {
            int v = 0;
            if (CFNumberGetValue(n, kCFNumberIntType, &v)) result = v;
        }
        if (keyRef) CFRelease(keyRef);
    }
    if (statsRef) CFRelease(statsRef);
    IOObjectRelease(acc);
    return result;
}

int sbi_gpu_util(void) { return gpu_stat_int("Device Utilization %"); }
int sbi_gpu_util_at_pstate(void) { return gpu_stat_int("Device Utilization % at cur p-state"); }

/* ---------- 无线外设电量（蓝牙 HID / IORegistry BatteryPercent） ---------- */
int sbi_wireless_battery(char *buf, int len) {
    if (len <= 0) return 0;
    buf[0] = 0;
    int count = 0;
    io_iterator_t it = 0;
    CFMutableDictionaryRef match = IOServiceMatching("AppleDeviceManagementHIDEventService");
    if (!match) return 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != kIOReturnSuccess) return 0;
    io_object_t obj;
    while ((obj = IOIteratorNext(it))) {
        int pct = -1;
        char name[128] = {0};
        CFTypeRef b = IORegistryEntryCreateCFProperty(obj, CFSTR("BatteryPercent"), kCFAllocatorDefault, 0);
        if (b) {
            if (CFGetTypeID(b) == CFNumberGetTypeID()) CFNumberGetValue((CFNumberRef)b, kCFNumberIntType, &pct);
            CFRelease(b);
        }
        if (pct < 0) { IOObjectRelease(obj); continue; }
        CFTypeRef pr = IORegistryEntryCreateCFProperty(obj, CFSTR("Product"), kCFAllocatorDefault, 0);
        if (pr) {
            if (CFGetTypeID(pr) == CFStringGetTypeID())
                CFStringGetCString((CFStringRef)pr, name, sizeof(name), kCFStringEncodingUTF8);
            CFRelease(pr);
        }
        if (name[0] == 0) {
            CFTypeRef tr = IORegistryEntryCreateCFProperty(obj, CFSTR("Transport"), kCFAllocatorDefault, 0);
            if (tr) {
                if (CFGetTypeID(tr) == CFStringGetTypeID())
                    CFStringGetCString((CFStringRef)tr, name, sizeof(name), kCFStringEncodingUTF8);
                CFRelease(tr);
            }
        }
        if (name[0] == 0) snprintf(name, sizeof(name), "HID 设备");
        int n = snprintf(buf + strlen(buf), len - (int)strlen(buf), "%s|%d\n", name, pct);
        if (n <= 0) break;
        count++;
        IOObjectRelease(obj);
    }
    IOObjectRelease(it);
    return count;
}
