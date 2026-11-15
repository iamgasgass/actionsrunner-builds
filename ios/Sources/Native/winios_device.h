/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Host device profile for WindowsiOS Universal.
 *
 * Upstream WindowsiOS was tuned for one device (iPhone Duo, iPhone19,4, A20 Pro,
 * 12 GB): 4.5 GB of guest RAM, a 384 MiB JIT region and 4 vCPUs, fixed. This
 * module sizes those three numbers from the device it is running on, the way
 * Henge does, and checks the chip can run the instructions the guest is told
 * exist (core/sysreg.c advertises an Armv8.5-class CPU: A14 / M1 or newer).
 */
#ifndef WINIOS_DEVICE_H
#define WINIOS_DEVICE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum WinIosChipSupport {
    WINIOS_CHIP_SUPPORTED = 0,  /* every feature the guest sees is present on the host */
    WINIOS_CHIP_TOO_OLD = 1,    /* A13 or older: Windows would hit SIGILL on copied instructions */
    WINIOS_CHIP_UNKNOWN = 2,    /* could not tell (simulator, unknown sysctl): allowed, with a warning */
} WinIosChipSupport;

typedef struct WinIosDeviceProfile {
    char     model[32];          /* hw.machine, e.g. "iPhone15,2" */
    uint64_t physical_mb;        /* hw.memsize in MiB */
    int      host_cpus;          /* hw.ncpu */
    int      perf_cores;         /* hw.perflevel0.physicalcpu (0 if unknown) */
    WinIosChipSupport chip;
    char     missing_features[160]; /* comma-separated FEAT_* the host lacks (empty when supported) */

    /* Recommendations for this device (before any user override). */
    uint64_t recommended_ram_mb;
    size_t   recommended_jit_bytes;
    int      recommended_cpus;
    uint64_t max_ram_mb;         /* largest guest RAM the settings screen offers */
} WinIosDeviceProfile;

/* Probes the host once and caches the result. Thread-safe after the first call. */
const WinIosDeviceProfile *winios_device_profile(void);

/* User overrides (0 = automatic). Must be set before the JIT region is acquired,
   because guest RAM is pre-allocated while the debugger is still attached. */
void     winios_device_set_overrides(uint64_t ram_mb, int cpus);

/* What the VM will actually use: override if set (clamped), else the recommendation. */
uint64_t winios_device_effective_ram_mb(void);
size_t   winios_device_effective_jit_bytes(void);
int      winios_device_effective_cpus(void);

#ifdef __cplusplus
}
#endif

#endif
