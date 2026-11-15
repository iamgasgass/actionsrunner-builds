/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * On-device Windows 11 installer media. See win_installer.h.
 *
 * Uses wimlib (LGPL-3.0-or-later) to read Microsoft's ESD and to write WinPE's boot.wim,
 * and FatFs (ChaN, BSD-style) to format and fill the FAT32 and exFAT partitions inside
 * the disk image, so nothing needs mounting: iOS apps cannot mount disk images.
 */
#include "win_installer.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#include <wimlib.h>

/* FatFs names its directory type DIR, as POSIX does: rename it here (this file uses POSIX opendir). */
#define DIR FF_DIR
#include "../third_party/fatfs/ff.h"
#include "../third_party/fatfs/diskio.h"
#undef DIR

#define SECTOR 512u
#define MIB (1024ull * 1024ull)

static void seterr(char *err, size_t n, const char *fmt, ...) __attribute__((format(printf, 3, 4)));
static void seterr(char *err, size_t n, const char *fmt, ...) {
    if (!err || !n) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, n, fmt, ap);
    va_end(ap);
}

/* ------------------------------------------------------------------ progress */

typedef struct Prog {
    HvWinInstProgress cb;
    void *opaque;
    double base, span;   /* the current stage's slice of 0..1 */
    const char *stage;
} Prog;

static void prog_stage(Prog *p, double base, double span, const char *stage) {
    p->base = base;
    p->span = span;
    p->stage = stage;
    if (p->cb) p->cb(base, stage, p->opaque);
}

static void prog_at(Prog *p, double f) {
    if (f < 0) f = 0;
    if (f > 1) f = 1;
    if (p->cb) p->cb(p->base + p->span * f, p->stage, p->opaque);
}

/* ------------------------------------------------------------------ FatFs disk driver */

/* Each FatFs drive is one partition of the image, seen as an unpartitioned volume (FM_SFD). */
typedef struct Part {
    int fd;
    uint64_t first_lba;
    uint64_t sectors;
} Part;
static Part g_parts[FF_VOLUMES];

DSTATUS disk_initialize(BYTE pdrv) { return (pdrv < FF_VOLUMES && g_parts[pdrv].fd >= 0) ? 0 : STA_NOINIT; }
DSTATUS disk_status(BYTE pdrv) { return disk_initialize(pdrv); }

DRESULT disk_read(BYTE pdrv, BYTE *buff, LBA_t sector, UINT count) {
    if (pdrv >= FF_VOLUMES || g_parts[pdrv].fd < 0) return RES_NOTRDY;
    Part *p = &g_parts[pdrv];
    if (sector + count > p->sectors) return RES_PARERR;
    size_t len = (size_t)count * SECTOR;
    off_t off = (off_t)((p->first_lba + sector) * SECTOR);
    while (len) {
        ssize_t r = pread(p->fd, buff, len, off);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) {
            if (r == 0) { memset(buff, 0, len); return RES_OK; } /* sparse tail */
            return RES_ERROR;
        }
        buff += r; len -= (size_t)r; off += r;
    }
    return RES_OK;
}

DRESULT disk_write(BYTE pdrv, const BYTE *buff, LBA_t sector, UINT count) {
    if (pdrv >= FF_VOLUMES || g_parts[pdrv].fd < 0) return RES_NOTRDY;
    Part *p = &g_parts[pdrv];
    if (sector + count > p->sectors) return RES_PARERR;
    size_t len = (size_t)count * SECTOR;
    off_t off = (off_t)((p->first_lba + sector) * SECTOR);
    while (len) {
        ssize_t r = pwrite(p->fd, buff, len, off);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return RES_ERROR;
        buff += r; len -= (size_t)r; off += r;
    }
    return RES_OK;
}

DRESULT disk_ioctl(BYTE pdrv, BYTE cmd, void *buff) {
    if (pdrv >= FF_VOLUMES || g_parts[pdrv].fd < 0) return RES_NOTRDY;
    switch (cmd) {
    case CTRL_SYNC: return fsync(g_parts[pdrv].fd) == 0 ? RES_OK : RES_ERROR;
    case GET_SECTOR_COUNT: *(LBA_t *)buff = (LBA_t)g_parts[pdrv].sectors; return RES_OK;
    case GET_SECTOR_SIZE: *(WORD *)buff = SECTOR; return RES_OK;
    case GET_BLOCK_SIZE: *(DWORD *)buff = 2048; return RES_OK; /* 1 MiB erase blocks: aligns the data area */
    default: return RES_OK;
    }
}

/* ------------------------------------------------------------------ GPT */

static void random_bytes(uint8_t *b, size_t n) {
#if defined(__APPLE__)
    arc4random_buf(b, n);
#else
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0 || read(fd, b, n) != (ssize_t)n) {
        for (size_t i = 0; i < n; i++) b[i] = (uint8_t)rand();
    }
    if (fd >= 0) close(fd);
#endif
}

static void random_guid(uint8_t g[16]) {
    random_bytes(g, 16);
    g[7] = (uint8_t)((g[7] & 0x0f) | 0x40); /* version 4 (byte 7 holds the high half of time_hi in GPT's mixed endian) */
    g[8] = (uint8_t)((g[8] & 0x3f) | 0x80);
}

static void put16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void put64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }

/* Microsoft basic data partition EBD0A0A2-B9E5-4433-87C0-68B6B72699C7, in GPT byte order. */
static const uint8_t kBasicData[16] = {0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44,
                                       0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7};

typedef struct GptPart { uint64_t first, last; const char *name; } GptPart;

static int write_all(int fd, const void *buf, size_t len, off_t off) {
    const uint8_t *b = buf;
    while (len) {
        ssize_t r = pwrite(fd, b, len, off);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) return -1;
        b += r; len -= (size_t)r; off += r;
    }
    return 0;
}

static int write_gpt(int fd, uint64_t total_sectors, const GptPart *parts, int nparts) {
    /* Protective MBR */
    uint8_t mbr[SECTOR] = {0};
    mbr[446 + 4] = 0xEE;
    mbr[446 + 1] = 0x00; mbr[446 + 2] = 0x02; mbr[446 + 3] = 0x00; /* CHS start 0/0/2 */
    mbr[446 + 5] = 0xFF; mbr[446 + 6] = 0xFF; mbr[446 + 7] = 0xFF;
    put32(mbr + 446 + 8, 1);
    put32(mbr + 446 + 12, total_sectors - 1 > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)(total_sectors - 1));
    mbr[510] = 0x55; mbr[511] = 0xAA;
    if (write_all(fd, mbr, SECTOR, 0)) return -1;

    /* Partition entries: 128 x 128 bytes = 32 sectors */
    uint8_t entries[128 * 128];
    memset(entries, 0, sizeof entries);
    for (int i = 0; i < nparts; i++) {
        uint8_t *e = entries + 128 * i;
        memcpy(e, kBasicData, 16);
        random_guid(e + 16);
        put64(e + 32, parts[i].first);
        put64(e + 40, parts[i].last);
        put64(e + 48, 0);
        for (int c = 0; parts[i].name[c] && c < 36; c++) put16(e + 56 + 2 * c, (uint16_t)(unsigned char)parts[i].name[c]);
    }
    uint32_t entries_crc = (uint32_t)crc32(0, entries, sizeof entries);

    uint8_t disk_guid[16];
    random_guid(disk_guid);
    uint64_t last_lba = total_sectors - 1;
    uint64_t backup_entries_lba = last_lba - 32;

    for (int backup = 0; backup < 2; backup++) {
        uint8_t h[SECTOR] = {0};
        memcpy(h, "EFI PART", 8);
        put32(h + 8, 0x00010000);
        put32(h + 12, 92);
        put64(h + 24, backup ? last_lba : 1);          /* my LBA */
        put64(h + 32, backup ? 1 : last_lba);          /* alternate LBA */
        put64(h + 40, 34);                              /* first usable */
        put64(h + 48, backup_entries_lba - 1);          /* last usable */
        memcpy(h + 56, disk_guid, 16);
        put64(h + 72, backup ? backup_entries_lba : 2); /* entries LBA */
        put32(h + 80, 128);
        put32(h + 84, 128);
        put32(h + 88, entries_crc);
        put32(h + 16, (uint32_t)crc32(0, h, 92));
        if (write_all(fd, h, SECTOR, (off_t)((backup ? last_lba : 1) * SECTOR))) return -1;
        if (write_all(fd, entries, sizeof entries, (off_t)((backup ? backup_entries_lba : 2) * SECTOR))) return -1;
    }
    return 0;
}

/* ------------------------------------------------------------------ FatFs helpers */

static const char *fr_str(FRESULT r) {
    static const char *names[] = {"OK", "DISK_ERR", "INT_ERR", "NOT_READY", "NO_FILE", "NO_PATH", "INVALID_NAME",
                                  "DENIED", "EXIST", "INVALID_OBJECT", "WRITE_PROTECTED", "INVALID_DRIVE",
                                  "NOT_ENABLED", "NO_FILESYSTEM", "MKFS_ABORTED", "TIMEOUT", "LOCKED",
                                  "NOT_ENOUGH_CORE", "TOO_MANY_OPEN_FILES", "INVALID_PARAMETER"};
    return (unsigned)r < sizeof names / sizeof names[0] ? names[r] : "?";
}

/* mkdir -p on a FatFs volume ("0:/a/b/c"). */
static FRESULT f_mkdirs(const char *path) {
    char buf[1024];
    snprintf(buf, sizeof buf, "%s", path);
    for (char *p = buf + 3; *p; p++) {
        if (*p == '/') {
            *p = 0;
            FRESULT r = f_mkdir(buf);
            if (r != FR_OK && r != FR_EXIST) return r;
            *p = '/';
        }
    }
    FRESULT r = f_mkdir(buf);
    return (r == FR_EXIST) ? FR_OK : r;
}

typedef struct CopyCtx {
    Prog *prog;
    uint64_t done, total;
    uint8_t *buf;
    size_t bufsz;
    char *err;
    size_t errlen;
} CopyCtx;

static int copy_file_in(CopyCtx *c, const char *src, const char *dst, int expand) {
    int fd = open(src, O_RDONLY);
    if (fd < 0) { seterr(c->err, c->errlen, "Cannot read %s: %s", src, strerror(errno)); return -1; }
    struct stat st;
    fstat(fd, &st);
    FIL f;
    FRESULT r = f_open(&f, dst, FA_CREATE_ALWAYS | FA_WRITE);
    if (r != FR_OK) { close(fd); seterr(c->err, c->errlen, "Cannot create %s (%s)", dst, fr_str(r)); return -1; }
    if (expand && st.st_size > 0) f_expand(&f, (FSIZE_t)st.st_size, 1); /* contiguous: best effort */
    for (;;) {
        ssize_t n = read(fd, c->buf, c->bufsz);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { seterr(c->err, c->errlen, "Read error on %s: %s", src, strerror(errno)); goto fail; }
        if (n == 0) break;
        UINT w = 0;
        r = f_write(&f, c->buf, (UINT)n, &w);
        if (r != FR_OK || w != (UINT)n) {
            seterr(c->err, c->errlen, "Write error on %s (%s): the installer disk may be full", dst, fr_str(r));
            goto fail;
        }
        c->done += (uint64_t)n;
        if (c->total) prog_at(c->prog, (double)c->done / (double)c->total);
    }
    close(fd);
    r = f_close(&f);
    if (r != FR_OK) { seterr(c->err, c->errlen, "Cannot close %s (%s)", dst, fr_str(r)); return -1; }
    return 0;
fail:
    close(fd);
    f_close(&f);
    return -1;
}

static uint64_t tree_bytes(const char *dir) {
    uint64_t total = 0;
    DIR *d = opendir(dir);
    if (!d) return 0;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char p[2048];
        snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
        struct stat st;
        if (lstat(p, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) total += tree_bytes(p);
        else if (S_ISREG(st.st_mode)) total += (uint64_t)st.st_size;
    }
    closedir(d);
    return total;
}

/* Copies a host directory tree into a FatFs directory. */
static int copy_tree_in(CopyCtx *c, const char *src_dir, const char *dst_dir) {
    FRESULT r = strlen(dst_dir) <= 3 ? FR_OK : f_mkdirs(dst_dir); /* "0:" is the root */
    if (r != FR_OK) { seterr(c->err, c->errlen, "Cannot create %s (%s)", dst_dir, fr_str(r)); return -1; }
    DIR *d = opendir(src_dir);
    if (!d) { seterr(c->err, c->errlen, "Cannot list %s", src_dir); return -1; }
    struct dirent *e;
    int rc = 0;
    while (rc == 0 && (e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        char sp[2048], dp[2048];
        snprintf(sp, sizeof sp, "%s/%s", src_dir, e->d_name);
        snprintf(dp, sizeof dp, "%s/%s", dst_dir, e->d_name);
        struct stat st;
        if (lstat(sp, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) rc = copy_tree_in(c, sp, dp);
        else if (S_ISREG(st.st_mode)) rc = copy_file_in(c, sp, dp, 0);
    }
    closedir(d);
    return rc;
}

/* ------------------------------------------------------------------ host fs helpers */

static void rm_rf(const char *path) {
    struct stat st;
    if (lstat(path, &st) != 0) return;
    if (S_ISDIR(st.st_mode)) {
        DIR *d = opendir(path);
        if (d) {
            struct dirent *e;
            while ((e = readdir(d))) {
                if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
                char p[2048];
                snprintf(p, sizeof p, "%s/%s", path, e->d_name);
                rm_rf(p);
            }
            closedir(d);
        }
        rmdir(path);
    } else {
        unlink(path);
    }
}

static int mkdir_p(const char *path) {
    char buf[2048];
    snprintf(buf, sizeof buf, "%s", path);
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') { *p = 0; mkdir(buf, 0755); *p = '/'; }
    }
    return (mkdir(buf, 0755) == 0 || errno == EEXIST) ? 0 : -1;
}

/* ------------------------------------------------------------------ wimlib */

static int g_wimlib_ready;

static int wim_init(void) {
    if (g_wimlib_ready) return 0;
    /* Windows paths are case-insensitive: "/efi" must find "\EFI". */
    if (wimlib_global_init(WIMLIB_INIT_FLAG_DEFAULT_CASE_INSENSITIVE) != 0) return -1;
    g_wimlib_ready = 1;
    return 0;
}

int hv_wininst_inspect(const char *esd_path, HvWinInstEsdInfo *info, char *err, size_t errlen) {
    memset(info, 0, sizeof *info);
    if (wim_init()) { seterr(err, errlen, "wimlib could not start"); return -1; }
    WIMStruct *wim = NULL;
    int r = wimlib_open_wim(esd_path, 0, &wim);
    if (r) { seterr(err, errlen, "Not a Windows image (%s)", wimlib_get_error_string((enum wimlib_error_code)r)); return -1; }
    struct wimlib_wim_info wi;
    wimlib_get_wim_info(wim, &wi);
    info->image_count = (int)wi.image_count;
    for (int i = 1; i <= info->image_count; i++) {
        const char *name = wimlib_get_image_name(wim, i);
        const char *edition = wimlib_get_image_property(wim, i, "WINDOWS/EDITIONID");
        const char *arch = wimlib_get_image_property(wim, i, "WINDOWS/ARCH");
        const char *build = wimlib_get_image_property(wim, i, "WINDOWS/VERSION/BUILD");
        if (!info->pe_index && name && strstr(name, "Windows PE")) info->pe_index = i;
        if (!info->pro_index && edition && !strcmp(edition, "Professional")) {
            info->pro_index = i;
            snprintf(info->pro_name, sizeof info->pro_name, "%s", name ? name : "Windows Pro");
            if (build) snprintf(info->build, sizeof info->build, "%s", build);
            /* WIM ARCH values: 0 x86, 5 ARM, 9 x64, 12 ARM64 */
            snprintf(info->arch, sizeof info->arch, "%s", arch && !strcmp(arch, "12") ? "arm64" : arch ? arch : "?");
        }
    }
    if (!info->pe_index && info->image_count >= 2) info->pe_index = 2;
    wimlib_free(wim);
    if (!info->pro_index) { seterr(err, errlen, "This image has no Windows Pro edition"); return -1; }
    if (strcmp(info->arch, "arm64") != 0) { seterr(err, errlen, "This is not an ARM64 image (arch %s)", info->arch); return -1; }
    return 0;
}

typedef struct WimProgCtx { Prog *prog; } WimProgCtx;

static enum wimlib_progress_status on_wim_progress(enum wimlib_progress_msg msg, union wimlib_progress_info *info, void *ctx) {
    WimProgCtx *c = ctx;
    if (msg == WIMLIB_PROGRESS_MSG_WRITE_STREAMS && info->write_streams.total_bytes)
        prog_at(c->prog, (double)info->write_streams.completed_bytes / (double)info->write_streams.total_bytes);
    return WIMLIB_PROGRESS_STATUS_CONTINUE;
}

/* Extracts the boot files of image 1 (Windows Setup Media) and writes WinPE (image pe_index) as
   boot.wim with startnet.cmd replaced. */
static int stage_winpe(const HvWinInstOpts *o, const HvWinInstEsdInfo *info, const char *pe_dir,
                       const char *boot_wim, Prog *prog, char *err, size_t errlen) {
    WIMStruct *src = NULL, *dst = NULL;
    int rc = -1, r;

    r = wimlib_open_wim(o->esd_path, 0, &src);
    if (r) { seterr(err, errlen, "Cannot open the ESD (%s)", wimlib_get_error_string((enum wimlib_error_code)r)); goto out; }

    /* The media's UEFI boot files: \efi (bootaa64.efi, BCD), \boot, \bootmgr.efi */
    static const char *const paths[] = {"/efi", "/boot", "/bootmgr.efi"};
    int extracted = 0;
    for (size_t i = 0; i < sizeof paths / sizeof paths[0]; i++) {
        r = wimlib_extract_paths(src, 1, pe_dir, &paths[i], 1,
                                 WIMLIB_EXTRACT_FLAG_NO_ACLS | WIMLIB_EXTRACT_FLAG_NO_ATTRIBUTES);
        if (r == 0) extracted++;
        else if (r != WIMLIB_ERR_PATH_DOES_NOT_EXIST) {
            seterr(err, errlen, "Cannot extract %s (%s)", paths[i], wimlib_get_error_string((enum wimlib_error_code)r));
            goto out;
        }
    }
    if (!extracted) { seterr(err, errlen, "The ESD has no UEFI boot files"); goto out; }

    r = wimlib_create_new_wim(WIMLIB_COMPRESSION_TYPE_XPRESS, &dst);
    if (r) { seterr(err, errlen, "wimlib: %s", wimlib_get_error_string((enum wimlib_error_code)r)); goto out; }
    r = wimlib_export_image(src, info->pe_index, dst, NULL, NULL, WIMLIB_EXPORT_FLAG_BOOT);
    if (r) { seterr(err, errlen, "Cannot export Windows PE (%s)", wimlib_get_error_string((enum wimlib_error_code)r)); goto out; }

    WimProgCtx pc = {prog};
    wimlib_register_progress_function(dst, on_wim_progress, &pc);
    r = wimlib_write(dst, boot_wim, WIMLIB_ALL_IMAGES, 0, 0);
    if (r) { seterr(err, errlen, "Cannot write boot.wim (%s)", wimlib_get_error_string((enum wimlib_error_code)r)); goto out; }
    wimlib_free(dst);
    dst = NULL;

    /* An exported image cannot be changed in place: add startnet.cmd to the written boot.wim. */
    r = wimlib_open_wim(boot_wim, WIMLIB_OPEN_FLAG_WRITE_ACCESS, &dst);
    if (r) { seterr(err, errlen, "Cannot reopen boot.wim (%s)", wimlib_get_error_string((enum wimlib_error_code)r)); goto out; }
    struct wimlib_update_command cmd;
    memset(&cmd, 0, sizeof cmd);
    cmd.op = WIMLIB_UPDATE_OP_ADD;
    cmd.add.fs_source_path = (char *)o->startnet_cmd;
    cmd.add.wim_target_path = (char *)"/Windows/System32/startnet.cmd";
    r = wimlib_update_image(dst, 1, &cmd, 1, 0);
    if (r) { seterr(err, errlen, "Cannot add startnet.cmd (%s)", wimlib_get_error_string((enum wimlib_error_code)r)); goto out; }
    r = wimlib_overwrite(dst, 0, 0);
    if (r) { seterr(err, errlen, "Cannot update boot.wim (%s)", wimlib_get_error_string((enum wimlib_error_code)r)); goto out; }
    rc = 0;
out:
    if (dst) wimlib_free(dst);
    if (src) wimlib_free(src);
    return rc;
}

/* ------------------------------------------------------------------ build */

int hv_wininst_create_disk(const char *path, uint64_t bytes, char *err, size_t errlen) {
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { seterr(err, errlen, "Cannot create %s: %s", path, strerror(errno)); return -1; }
    int rc = ftruncate(fd, (off_t)bytes); /* sparse: takes no space until Windows writes */
    close(fd);
    if (rc) { seterr(err, errlen, "Cannot size %s: %s", path, strerror(errno)); unlink(path); return -1; }
    return 0;
}

/* A small GPT disk with one FAT32 volume holding src_dir: the "WindowsiOS Tools" drive Windows sees
   at every boot (drivers and scripts), the way VM tools discs work elsewhere. */
int hv_wininst_build_data_disk(const char *src_dir, const char *out_img, const char *label, char *err, size_t errlen) {
    Prog prog = {NULL, NULL, 0, 0, ""};
    int fd = -1, rc = -1;
    uint8_t *work = NULL, *buf = NULL;
    FATFS *fs = NULL;
    for (int i = 0; i < FF_VOLUMES; i++) g_parts[i].fd = -1;
    uint64_t content = tree_bytes(src_dir);
    uint64_t part = ((content + 64 * MIB) + MIB - 1) / MIB * MIB;
    if (part < 128 * MIB) part = 128 * MIB; /* FAT32 needs at least ~33 MB; leave room */
    uint64_t total = MIB + part + MIB;
    char tmp[2048];
    snprintf(tmp, sizeof tmp, "%s.tmp", out_img);
    fd = open(tmp, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || ftruncate(fd, (off_t)total) != 0) { seterr(err, errlen, "Cannot create %s: %s", tmp, strerror(errno)); goto out; }
    GptPart gp = {MIB / SECTOR, (MIB + part) / SECTOR - 1, label};
    if (write_gpt(fd, total / SECTOR, &gp, 1)) { seterr(err, errlen, "Cannot write the partition table"); goto out; }
    g_parts[0].fd = fd;
    g_parts[0].first_lba = gp.first;
    g_parts[0].sectors = gp.last - gp.first + 1;
    work = malloc(4 * MIB);
    buf = malloc(4 * MIB);
    fs = calloc(1, sizeof *fs);
    if (!work || !buf || !fs) { seterr(err, errlen, "Out of memory"); goto out; }
    MKFS_PARM fat32 = {FM_FAT32 | FM_SFD, 0, 0, 0, 0};
    FRESULT fr = f_mkfs("0:", &fat32, work, (UINT)(4 * MIB));
    if (fr != FR_OK) { seterr(err, errlen, "Cannot format FAT32 (%s)", fr_str(fr)); goto out; }
    if ((fr = f_mount(fs, "0:", 1)) != FR_OK) { seterr(err, errlen, "Cannot mount (%s)", fr_str(fr)); goto out; }
    char lbl[40];
    snprintf(lbl, sizeof lbl, "0:%.11s", label);
    f_setlabel(lbl);
    CopyCtx cc = {&prog, 0, content, buf, 4 * MIB, err, errlen};
    if (copy_tree_in(&cc, src_dir, "0:")) goto out;
    f_unmount("0:");
    if (fsync(fd) != 0) { seterr(err, errlen, "Cannot flush %s", tmp); goto out; }
    close(fd);
    fd = -1;
    if (rename(tmp, out_img) != 0) { seterr(err, errlen, "Cannot rename %s: %s", tmp, strerror(errno)); goto out; }
    rc = 0;
out:
    g_parts[0].fd = -1;
    if (fd >= 0) close(fd);
    if (rc) unlink(tmp);
    free(work);
    free(buf);
    free(fs);
    return rc;
}

#define P1_BYTES (1536ull * MIB) /* FAT32: WinPE (~600 MB boot.wim) + boot files + payload */

int hv_wininst_build(const HvWinInstOpts *o, HvWinInstProgress progress, void *opaque, char *err, size_t errlen) {
    Prog prog = {progress, opaque, 0, 0, ""};
    char pe_dir[2048], boot_wim[2048];
    int fd = -1, rc = -1;
    uint8_t *work = NULL, *buf = NULL;
    FATFS *fs0 = NULL, *fs1 = NULL;
    for (int i = 0; i < FF_VOLUMES; i++) g_parts[i].fd = -1;

    prog_stage(&prog, 0.0, 0.02, "Reading the Windows image");
    HvWinInstEsdInfo info;
    if (hv_wininst_inspect(o->esd_path, &info, err, errlen)) return -1;
    struct stat est;
    if (stat(o->esd_path, &est) != 0) { seterr(err, errlen, "ESD missing"); return -1; }

    rm_rf(o->work_dir);
    snprintf(pe_dir, sizeof pe_dir, "%s/pe", o->work_dir);
    snprintf(boot_wim, sizeof boot_wim, "%s/boot.wim", o->work_dir);
    if (mkdir_p(pe_dir)) { seterr(err, errlen, "Cannot create %s", pe_dir); return -1; }

    prog_stage(&prog, 0.02, 0.28, "Preparing Windows PE");
    if (stage_winpe(o, &info, pe_dir, boot_wim, &prog, err, errlen)) goto out;

    /* Disk layout: 1 MiB | P1 FAT32 | P2 exFAT (ESD + 256 MiB) | 1 MiB (backup GPT) */
    prog_stage(&prog, 0.30, 0.02, "Formatting the installer disk");
    uint64_t p2_bytes = (((uint64_t)est.st_size + 256 * MIB) + MIB - 1) / MIB * MIB;
    uint64_t total = MIB + P1_BYTES + p2_bytes + MIB;
    fd = open(o->out_img, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || ftruncate(fd, (off_t)total) != 0) {
        seterr(err, errlen, "Cannot create the installer disk: %s", strerror(errno));
        goto out;
    }
    uint64_t total_sectors = total / SECTOR;
    GptPart parts[2] = {
        {MIB / SECTOR, (MIB + P1_BYTES) / SECTOR - 1, "WINPE"},
        {(MIB + P1_BYTES) / SECTOR, (MIB + P1_BYTES + p2_bytes) / SECTOR - 1, "WINESD"},
    };
    if (write_gpt(fd, total_sectors, parts, 2)) { seterr(err, errlen, "Cannot write the partition table"); goto out; }
    for (int i = 0; i < 2; i++) {
        g_parts[i].fd = fd;
        g_parts[i].first_lba = parts[i].first;
        g_parts[i].sectors = parts[i].last - parts[i].first + 1;
    }

    const size_t worksz = 4 * MIB;
    work = malloc(worksz);
    fs0 = calloc(1, sizeof *fs0);
    fs1 = calloc(1, sizeof *fs1);
    if (!work || !fs0 || !fs1) { seterr(err, errlen, "Out of memory"); goto out; }
    MKFS_PARM fat32 = {FM_FAT32 | FM_SFD, 0, 0, 0, 0};
    MKFS_PARM exfat = {FM_EXFAT | FM_SFD, 0, 0, 0, 0};
    FRESULT fr = f_mkfs("0:", &fat32, work, (UINT)worksz);
    if (fr != FR_OK) { seterr(err, errlen, "Cannot format FAT32 (%s)", fr_str(fr)); goto out; }
    fr = f_mkfs("1:", &exfat, work, (UINT)worksz);
    if (fr != FR_OK) { seterr(err, errlen, "Cannot format exFAT (%s)", fr_str(fr)); goto out; }
    if ((fr = f_mount(fs0, "0:", 1)) != FR_OK || (fr = f_mount(fs1, "1:", 1)) != FR_OK) {
        seterr(err, errlen, "Cannot mount the new volumes (%s)", fr_str(fr));
        goto out;
    }
    f_setlabel("0:WINPE");
    f_setlabel("1:WINESD");

    const size_t bufsz = 8 * MIB;
    buf = malloc(bufsz);
    if (!buf) { seterr(err, errlen, "Out of memory"); goto out; }
    CopyCtx cc = {&prog, 0, 0, buf, bufsz, err, errlen};

    prog_stage(&prog, 0.32, 0.03, "Copying Windows PE");
    struct stat bst;
    stat(boot_wim, &bst);
    cc.done = 0;
    cc.total = tree_bytes(pe_dir) + (uint64_t)bst.st_size + (o->payload_dir ? tree_bytes(o->payload_dir) : 0);
    if (copy_tree_in(&cc, pe_dir, "0:")) goto out;
    if ((fr = f_mkdirs("0:/sources")) != FR_OK) { seterr(err, errlen, "mkdir sources (%s)", fr_str(fr)); goto out; }
    if (copy_file_in(&cc, boot_wim, "0:/sources/boot.wim", 1)) goto out;
    if (o->payload_dir && copy_tree_in(&cc, o->payload_dir, "0:/winios")) goto out;

    prog_stage(&prog, 0.35, 0.65, "Copying Windows");
    if ((fr = f_mkdirs("1:/sources")) != FR_OK) { seterr(err, errlen, "mkdir sources (%s)", fr_str(fr)); goto out; }
    cc.done = 0;
    cc.total = (uint64_t)est.st_size;
    if (copy_file_in(&cc, o->esd_path, "1:/sources/install.esd", 1)) goto out;
    /* Tells startnet.cmd which drive is ours and which image index is Pro. */
    {
        FIL f;
        char tag[64];
        int n = snprintf(tag, sizeof tag, "%d\r\n", info.pro_index);
        UINT w;
        if (f_open(&f, "1:/winios.tag", FA_CREATE_ALWAYS | FA_WRITE) == FR_OK) {
            f_write(&f, tag, (UINT)n, &w);
            f_close(&f);
        }
    }
    f_unmount("0:");
    f_unmount("1:");
    if (fsync(fd) != 0) { seterr(err, errlen, "Cannot flush the installer disk"); goto out; }
    prog_at(&prog, 1.0);
    rc = 0;
    if (o->delete_esd) unlink(o->esd_path);
out:
    for (int i = 0; i < FF_VOLUMES; i++) g_parts[i].fd = -1;
    if (fd >= 0) close(fd);
    if (rc != 0 && o->out_img) unlink(o->out_img);
    free(work);
    free(buf);
    free(fs0);
    free(fs1);
    rm_rf(o->work_dir);
    return rc;
}
