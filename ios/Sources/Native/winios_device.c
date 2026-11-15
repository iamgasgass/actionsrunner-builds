/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * Host device profile for WindowsiOS Universal. See winios_device.h.
 */
#include "winios_device.h"
#include "winios_jit.h"

#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>

static WinIosDeviceProfile g_profile;
static uint64_t g_ram_override_mb;
static int g_cpu_override;

static int sysctl_int(const char *name, int fallback) {
    int v = 0;
    size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return fallback;
    return v;
}

static uint64_t sysctl_u64(const char *name) {
    uint64_t v = 0;
    size_t len = sizeof v;
    if (sysctlbyname(name, &v, &len, NULL, 0) != 0) return 0;
    return v;
}

/* Model identifier ("iPhone15,2"). hw.machine is the identifier on iOS; on a Mac
   (Designed for iPad) and in the simulator it is "arm64"/"x86_64". */
static void read_model(char *out, size_t cap) {
    size_t len = cap;
    if (sysctlbyname("hw.machine", out, &len, NULL, 0) != 0 || len == 0) {
        snprintf(out, cap, "unknown");
        return;
    }
    out[cap - 1] = 0;
    const char *sim = getenv("SIMULATOR_MODEL_IDENTIFIER");
    if (sim && *sim) snprintf(out, cap, "%s", sim);
}

/* Major number of an "iPhoneNN,x" / "iPadNN,x" identifier, or -1. */
static int model_major(const char *model) {
    const char *p = model;
    if (strncmp(p, "iPhone", 6) == 0) p += 6;
    else if (strncmp(p, "iPad", 4) == 0) p += 4;
    else return -1;
    if (*p < '0' || *p > '9') return -1;
    return atoi(p);
}

/*
 * The guest's ID registers (core/sysreg.c) advertise these features, and the
 * translator copies such instructions to the host unchanged. iOS publishes each
 * one as hw.optional.arm.FEAT_* (iOS 15+). A missing key means "not present"
 * only when the family of keys exists at all, so that a sysctl rename on a future
 * iOS cannot lock out a new device.
 */
static const char *const kRequiredFeatures[] = {
    "FEAT_LSE",     /* CAS/CASP/LDADD...: inline exclusives (translate_excl_pair) */
    "FEAT_LSE2",    /* 16-byte aligned LDP single-copy atomic */
    "FEAT_LRCPC",   /* LDAPR */
    "FEAT_LRCPC2",  /* LDAPUR/STLUR, used by Prism (xtajit64.dll) */
    "FEAT_FlagM",
    "FEAT_DotProd",
    "FEAT_FHM",
    "FEAT_SHA3",
    "FEAT_SHA512",
    "FEAT_JSCVT",
    "FEAT_FCMA",
    "FEAT_DPB",
    "FEAT_FRINTTS", /* Armv8.5: A14 / M1 and later */
    "FEAT_SB",      /* Armv8.5 speculation barrier */
    "FEAT_FP16",
    "FEAT_RDM",
};

static WinIosChipSupport probe_chip(const char *model, char *missing, size_t cap) {
    missing[0] = 0;
    int have_family = sysctl_int("hw.optional.arm.FEAT_LSE", -1) >= 0;
    if (have_family) {
        int lacking = 0;
        for (size_t i = 0; i < sizeof kRequiredFeatures / sizeof kRequiredFeatures[0]; i++) {
            char key[64];
            snprintf(key, sizeof key, "hw.optional.arm.%s", kRequiredFeatures[i]);
            if (sysctl_int(key, 0) == 0) {
                size_t used = strlen(missing);
                snprintf(missing + used, cap - used, "%s%s", used ? ", " : "", kRequiredFeatures[i]);
                lacking++;
            }
        }
        if (lacking == 0) return WINIOS_CHIP_SUPPORTED;
        /* FEAT_* keys exist but some are 0: trust them only if the model agrees,
           since a few keys (FEAT_SB, FEAT_DPB) were added to iOS later than others. */
        int major = model_major(model);
        if (major >= 13) {
            missing[0] = 0;
            return WINIOS_CHIP_SUPPORTED;
        }
        return major < 0 ? WINIOS_CHIP_UNKNOWN : WINIOS_CHIP_TOO_OLD;
    }
    /* No FEAT_* sysctls: decide from the model identifier, as Henge does.
       iPhone13,x is A14 (iPhone 12); iPad13,x is A14/M1. */
    int major = model_major(model);
    if (major < 0) return WINIOS_CHIP_UNKNOWN;
    if (major < 13) {
        snprintf(missing, cap, "Armv8.5 (A14 or newer)");
        return WINIOS_CHIP_TOO_OLD;
    }
    return WINIOS_CHIP_SUPPORTED;
}

/*
 * Memory tiers. hw.memsize reports a little under the marketing size
 * (an 8 GB iPhone reports ~7.5 GB). Guest RAM is ledger-exempt (it does not count
 * against Jetsam's per-app limit) but it still comes out of physical memory, so
 * iOS itself needs room left over. Windows 11 "lite" (scripts/optimize_windows_lite.py)
 * idles at ~1.46 GB.
 *
 *   12 GB+ (iPhone 17 Pro, Duo, M-series iPads)  4608 MiB  384 MiB JIT  4 vCPU
 *    8 GB  (iPhone 15 Pro, 16, 17, Air)          3584 MiB  384 MiB JIT  4 vCPU
 *    6 GB  (iPhone 12 Pro .. 15 Plus)            2560 MiB  320 MiB JIT  4 vCPU
 *    4 GB  (iPhone 12/13 (mini), SE 3)           2048 MiB  256 MiB JIT  2 vCPU  (experimental)
 */
static void recommend(WinIosDeviceProfile *p) {
    uint64_t mb = p->physical_mb;
    if (mb >= 11000) {
        p->recommended_ram_mb = 4608;
        p->recommended_jit_bytes = (size_t)384 << 20;
        p->recommended_cpus = 4;
        p->max_ram_mb = 4608; /* upstream's ceiling: guest RAM + JIT must fit the default user VA space */
    } else if (mb >= 7000) {
        p->recommended_ram_mb = 3584;
        p->recommended_jit_bytes = (size_t)384 << 20;
        p->recommended_cpus = 4;
        p->max_ram_mb = 4608;
    } else if (mb >= 5000) {
        p->recommended_ram_mb = 2560;
        p->recommended_jit_bytes = (size_t)320 << 20;
        p->recommended_cpus = 4;
        p->max_ram_mb = 3584;
    } else if (mb > 0) {
        p->recommended_ram_mb = 2048;
        p->recommended_jit_bytes = (size_t)256 << 20;
        p->recommended_cpus = 2;
        p->max_ram_mb = 2560;
    } else {
        p->recommended_ram_mb = 3072;
        p->recommended_jit_bytes = WINIOS_JIT_DEFAULT_BYTES;
        p->recommended_cpus = 4;
        p->max_ram_mb = 4608;
    }
    /* Never more vCPUs than host cores (leave the UI/audio threads a core). */
    if (p->host_cpus > 1 && p->recommended_cpus > p->host_cpus - 1) p->recommended_cpus = p->host_cpus - 1;
    if (p->recommended_cpus < 1) p->recommended_cpus = 1;
    if (p->recommended_jit_bytes > WINIOS_JIT_DEFAULT_BYTES) p->recommended_jit_bytes = WINIOS_JIT_DEFAULT_BYTES;
}

const WinIosDeviceProfile *winios_device_profile(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WinIosDeviceProfile *p = &g_profile;
        memset(p, 0, sizeof *p);
        read_model(p->model, sizeof p->model);
        p->physical_mb = sysctl_u64("hw.memsize") >> 20;
        p->host_cpus = sysctl_int("hw.ncpu", 6);
        p->perf_cores = sysctl_int("hw.perflevel0.physicalcpu", 0);
        p->chip = probe_chip(p->model, p->missing_features, sizeof p->missing_features);
        recommend(p);
        fprintf(stderr, "[winios-device] %s, %llu MiB, %d cpus (%d P), chip=%d%s%s -> RAM %llu MiB, JIT %zu MiB, %d vCPU\n",
                p->model, (unsigned long long)p->physical_mb, p->host_cpus, p->perf_cores, (int)p->chip,
                p->missing_features[0] ? " missing: " : "", p->missing_features,
                (unsigned long long)p->recommended_ram_mb, p->recommended_jit_bytes >> 20, p->recommended_cpus);
    });
    return &g_profile;
}

void winios_device_set_overrides(uint64_t ram_mb, int cpus) {
    g_ram_override_mb = ram_mb;
    g_cpu_override = cpus;
}

uint64_t winios_device_effective_ram_mb(void) {
    const WinIosDeviceProfile *p = winios_device_profile();
    uint64_t mb = g_ram_override_mb ? g_ram_override_mb : p->recommended_ram_mb;
    if (mb < 1536) mb = 1536;
    if (mb > p->max_ram_mb) mb = p->max_ram_mb;
    return mb & ~(uint64_t)127;
}

size_t winios_device_effective_jit_bytes(void) {
    return winios_device_profile()->recommended_jit_bytes;
}

int winios_device_effective_cpus(void) {
    const WinIosDeviceProfile *p = winios_device_profile();
    int n = g_cpu_override > 0 ? g_cpu_override : p->recommended_cpus;
    int cap = p->host_cpus > 1 ? p->host_cpus : 1;
    if (cap > 8) cap = 8;
    if (n > cap) n = cap;
    if (n < 1) n = 1;
    return n;
}
