// bridge.h — 给 SwiftUI 用的 C 接口（SMC 传感器 + 系统信息 + 网络速率）
#ifndef SENSOR_BAR_BRIDGE_H
#define SENSOR_BAR_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

int    sbi_open(void);
int    sbi_smc_key_count(void);

double sbi_temp_pkg(void);
int    sbi_core_count(void);
double sbi_temp_core(int idx);
double sbi_power_cpu(void);
double sbi_power_pl(void);
double sbi_vcore(void);

int    sbi_fan_count(void);
double sbi_fan_rpm(int idx);

double sbi_batt_volt(void);
double sbi_batt_current(void);
double sbi_batt_remain(void);
double sbi_batt_full(void);
double sbi_batt_pct(void);
int    sbi_batt_cycle(void);
int    sbi_batt_design_mah(void);
int    sbi_batt_maxraw_mah(void);
int    sbi_batt_time_remaining(void);
int    sbi_ac_in(void);
int    sbi_batt_present(void);

double sbi_cpu_usage(void);
double sbi_load1(void);
double sbi_load5(void);
double sbi_load15(void);
double sbi_mem_total_gb(void);
double sbi_mem_wired_gb(void);
double sbi_mem_compressed_gb(void);
double sbi_mem_active_gb(void);
int    sbi_mem_pressure(void);
double sbi_mem_used_gb(void);
double sbi_swap_used_gb(void);
double sbi_thermal_level(void);
double sbi_uptime(void);

// 网络：down/up 为「上次调用以来」的字节/秒；totals 为进程启动以来的累计字节
void   sbi_net_rates(double *down_bps, double *up_bps);
void   sbi_net_totals(double *rx_bytes, double *tx_bytes);
const char *sbi_net_interface(void);
const char *sbi_net_ipv4(void);
int    sbi_net_link_up(void);

void   sbi_disk_io(double *read_bps, double *write_bps, double *read_total, double *write_total);
int    sbi_top_procs(char *buf, int len, int by_memory);
int    sbi_smc_dump(char *buf, int len);
const char *sbi_serial(void);
const char *sbi_board_id(void);
double sbi_disk_total_gb(void);
double sbi_disk_free_gb(void);
const char *sbi_nvme_model(void);
const char *sbi_cpu_brand(void);
const char *sbi_model(void);
int    sbi_physical_cpus(void);
int    sbi_logical_cpus(void);
int    sbi_gpu_util(void);
int    sbi_gpu_util_at_pstate(void);
int    sbi_wireless_battery(char *buf, int len);

#ifdef __cplusplus
}
#endif

#endif
