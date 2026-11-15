/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * On-device Windows 11 installer media, the way Henge prepares macOS on the iPhone:
 * no Mac, no PC. From Microsoft's own ARM64 ESD this builds a two-partition GPT disk
 * image that the VM boots as its second NVMe disk:
 *
 *   partition 1  FAT32  WinPE (bootaa64.efi, \boot, \sources\boot.wim with our startnet.cmd)
 *                       + \winios\ (unattend.xml, registry files, drivers, tools)
 *   partition 2  exFAT  \sources\install.esd (Microsoft's ESD as downloaded, not recompressed)
 *
 * WinPE then partitions the NVMe system disk, applies the Pro edition with DISM, adds the
 * drivers and runs bcdboot (see the startnet.cmd the app writes), and reboots into Windows'
 * own unattended first setup. Same steps as scripts/provision_windows_arm64.py on a Mac.
 */
#ifndef HV_WIN_INSTALLER_H
#define HV_WIN_INSTALLER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*HvWinInstProgress)(double fraction, const char *stage, void *opaque);

typedef struct HvWinInstEsdInfo {
    int  pro_index;          /* image index of Windows 11 Pro (EDITIONID Professional), 0 if absent */
    int  pe_index;           /* image index of Windows PE (normally 2) */
    int  image_count;
    char pro_name[128];
    char build[32];          /* e.g. "26100" */
    char arch[16];           /* "arm64" when the ESD is right for this VM */
} HvWinInstEsdInfo;

/* Reads the ESD's image list. 0 on success. */
int hv_wininst_inspect(const char *esd_path, HvWinInstEsdInfo *info, char *err, size_t errlen);

typedef struct HvWinInstOpts {
    const char *esd_path;     /* Microsoft's ARM64 ESD */
    const char *out_img;      /* installer disk image to create (sparse) */
    const char *work_dir;     /* scratch directory (WinPE files, boot.wim), removed afterwards */
    const char *startnet_cmd; /* file to install as X:\Windows\System32\startnet.cmd in WinPE */
    const char *payload_dir;  /* optional: copied to partition 1 as \winios (unattend, .reg, drivers, tools) */
    int delete_esd;           /* 1: remove esd_path once it is on the installer disk */
} HvWinInstOpts;

/* Builds the installer disk. Runs for minutes (boot.wim export, a ~5 GB copy); call it off the
   main thread. 0 on success. */
int hv_wininst_build(const HvWinInstOpts *opts, HvWinInstProgress progress, void *opaque,
                     char *err, size_t errlen);

/* A small GPT disk image with one FAT32 volume (label, up to 11 characters) holding src_dir.
   Written to out_img.tmp, then renamed. 0 on success. */
int hv_wininst_build_data_disk(const char *src_dir, const char *out_img, const char *label,
                               char *err, size_t errlen);

/* Creates an empty sparse disk image of the given size (the Windows system disk). 0 on success. */
int hv_wininst_create_disk(const char *path, uint64_t bytes, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif
