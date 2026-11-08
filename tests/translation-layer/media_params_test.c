/* SPDX-License-Identifier: GPL-2.0-or-later */
/* The H.264/HEVC parameter-set and join-point readers of husk-tl-dvm-media.c, on hand-made NAL units. run_media_params.sh
 * cuts them out of the decoder (which needs Apple's frameworks) so they run on any host. */
#include <stdio.h>
#include "media_params_helpers.c"
static int fails;
#define CHECK(c, what) do { if (c) printf("ok   %s\n", what); else { printf("FAIL %s\n", what); fails++; } } while (0)
int main(void)
{
    uint8_t sps0[] = { 0x67, 0x64, 0x00, 0x28, 0xAC, 0xD9, 0x40 }, sps3[] = { 0x67, 0x64, 0x00, 0x28, 0x20, 0x00 };
    CHECK(avc_sps_id(sps0, sizeof sps0) == 0 && avc_sps_id(sps3, sizeof sps3) == 3, "H.264 SPS ids");
    int sid = -9;
    uint8_t pps4[] = { 0x68, 0x2C };
    CHECK(avc_pps_id(pps4, sizeof pps4, &sid) == 4 && sid == 0, "H.264 PPS id 4 on SPS 0");
    uint8_t pps95[] = { 0x68, 0x03, 0x04 };
    CHECK(avc_pps_id(pps95, sizeof pps95, &sid) == 95 && sid == 0, "H.264 PPS id 95");
    uint8_t islice[] = { 0x01, 0x88, 0x00 }, pslice[] = { 0x01, 0xC0 };
    CHECK(avc_intra_slice(islice, sizeof islice) && !avc_intra_slice(pslice, sizeof pslice), "I slice told from P slice");
    uint8_t sei_rp[] = { 0x06, 0x05, 0x02, 0xAA, 0xBB, 0x06, 0x01, 0x80, 0x80 }, sei_other[] = { 0x06, 0x05, 0x02, 0xAA, 0xBB, 0x80 };
    CHECK(sei_recovery_point(sei_rp, sizeof sei_rp, 1) && !sei_recovery_point(sei_other, sizeof sei_other, 1), "recovery-point SEI");
    uint8_t hpps[] = { 0x44, 0x01, 0xC0 }, hvps[] = { 0x40, 0x01, 0x30 };
    CHECK(hevc_pps_id(hpps, sizeof hpps) == 0 && hevc_vps_id(hvps, sizeof hvps) == 3, "HEVC PPS/VPS ids");
    uint8_t hsps[] = { 0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x5d, 0xa0, 0x02, 0x80 };
    CHECK(hevc_sps_id(hsps, sizeof hsps) == 0, "HEVC SPS id past profile_tier_level and emulation prevention");
    return fails != 0;
}
