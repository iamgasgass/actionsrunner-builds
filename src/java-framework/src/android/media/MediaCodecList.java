package android.media;

import java.util.ArrayList;

/** The decoders Husk has (see MediaCodecInfo): H.264 and HEVC video; AAC, MP3, AC-3, E-AC-3 and MPEG Layer I/II audio. No encoders. */
public final class MediaCodecList {
    public static final int REGULAR_CODECS = 0, ALL_CODECS = 1;
    private static MediaCodecInfo[] sInfos;
    static synchronized MediaCodecInfo[] infos() {
        if (sInfos == null) {
            /* What VideoToolbox decodes, as Andarium's host lists it (darwin/platform/apple/video_decoder.mm): H.264 to level 5.2 (the
               hardware opens 4096x2304 at any level), High 10 where a probe session says the chip has it, and HEVC Main and Main 10
               to level 6.2 in both tiers. Media3 drops a video track whose profile or level no decoder lists and plays the sound
               alone: a film in HEVC with HDR10 (Main10HDR10), at level 5.2 or above, in the high tier, or in H.264 High 10 started
               with no picture. */
            int L52 = MediaCodecInfo.CodecProfileLevel.AVCLevel52;
            java.util.ArrayList<int[]> avcl = new java.util.ArrayList<>();
            for (int p : new int[] { MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedBaseline, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline,
                                     MediaCodecInfo.CodecProfileLevel.AVCProfileMain,
                                     MediaCodecInfo.CodecProfileLevel.AVCProfileConstrainedHigh, MediaCodecInfo.CodecProfileLevel.AVCProfileHigh })
                avcl.add(new int[] { p, L52 });
            if (husk.MediaCodecNative.supported("video/avc-high10"))
                avcl.add(new int[] { MediaCodecInfo.CodecProfileLevel.AVCProfileHigh10, MediaCodecInfo.CodecProfileLevel.AVCLevel51 });
            int[][] avc = avcl.toArray(new int[0][]);
            java.util.ArrayList<int[]> hevcl = new java.util.ArrayList<>();
            for (int p : new int[] { MediaCodecInfo.CodecProfileLevel.HEVCProfileMain, MediaCodecInfo.CodecProfileLevel.HEVCProfileMainStill,
                                     MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10, MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10,
                                     MediaCodecInfo.CodecProfileLevel.HEVCProfileMain10HDR10Plus }) {
                hevcl.add(new int[] { p, MediaCodecInfo.CodecProfileLevel.HEVCMainTierLevel62 });
                hevcl.add(new int[] { p, MediaCodecInfo.CodecProfileLevel.HEVCHighTierLevel62 });
            }
            int[][] hevc = hevcl.toArray(new int[0][]);
            ArrayList<MediaCodecInfo> l = new ArrayList<>();
            l.add(new MediaCodecInfo("c2.husk.avc.decoder", false, MediaCodecInfo.CodecCapabilities.video(MediaFormat.MIMETYPE_VIDEO_AVC, avc)));
            if (husk.MediaCodecNative.supported(MediaFormat.MIMETYPE_VIDEO_HEVC))
                l.add(new MediaCodecInfo("c2.husk.hevc.decoder", false, MediaCodecInfo.CodecCapabilities.video(MediaFormat.MIMETYPE_VIDEO_HEVC, hevc)));
            l.add(new MediaCodecInfo("c2.husk.aac.decoder", false, MediaCodecInfo.CodecCapabilities.audio(MediaFormat.MIMETYPE_AUDIO_AAC, 8,
                new int[] { MediaCodecInfo.CodecProfileLevel.AACObjectLC, MediaCodecInfo.CodecProfileLevel.AACObjectHE, MediaCodecInfo.CodecProfileLevel.AACObjectHE_PS })));
            l.add(new MediaCodecInfo("c2.husk.mp3.decoder", false, MediaCodecInfo.CodecCapabilities.audio(MediaFormat.MIMETYPE_AUDIO_MPEG, 2, new int[0])));
            // TV and IPTV sound (DVB, ATSC, broadcast HLS): Dolby Digital / Digital Plus and MPEG-1 Layer I/II, where this iOS has the
            // decoder (MediaCodecNative.supported asks). Multichannel streams come out mixed down to stereo.
            if (husk.MediaCodecNative.supported(MediaFormat.MIMETYPE_AUDIO_AC3))
                l.add(new MediaCodecInfo("c2.husk.ac3.decoder", false, MediaCodecInfo.CodecCapabilities.audio(MediaFormat.MIMETYPE_AUDIO_AC3, 6, new int[0])));
            if (husk.MediaCodecNative.supported(MediaFormat.MIMETYPE_AUDIO_EAC3))
                l.add(new MediaCodecInfo("c2.husk.eac3.decoder", false,
                    MediaCodecInfo.CodecCapabilities.audio(MediaFormat.MIMETYPE_AUDIO_EAC3, 16, new int[0]),
                    MediaCodecInfo.CodecCapabilities.audio(MediaFormat.MIMETYPE_AUDIO_EAC3_JOC, 16, new int[0])));
            if (husk.MediaCodecNative.supported("audio/mpeg-L2"))
                l.add(new MediaCodecInfo("c2.husk.mp2.decoder", false,
                    MediaCodecInfo.CodecCapabilities.audio("audio/mpeg-L2", 2, new int[0]),
                    MediaCodecInfo.CodecCapabilities.audio("audio/mpeg-L1", 2, new int[0])));
            sInfos = l.toArray(new MediaCodecInfo[0]);
        }
        return sInfos;
    }
    public MediaCodecList(int kind) {}
    public static int getCodecCount() { return infos().length; }
    public static MediaCodecInfo getCodecInfoAt(int i) { MediaCodecInfo[] a = infos(); if (i < 0 || i >= a.length) throw new IllegalArgumentException(); return a[i]; }
    public static MediaCodecInfo getInfoFor(String name) { for (MediaCodecInfo i : infos()) if (i.getName().equals(name)) return i; return null; }
    public MediaCodecInfo[] getCodecInfos() { return infos().clone(); }
    public String findDecoderForFormat(MediaFormat f) {
        String mime = f.getString(MediaFormat.KEY_MIME);
        if (mime == null) return null;
        for (MediaCodecInfo i : infos()) {
            for (String t : i.getSupportedTypes()) if (t.equalsIgnoreCase(mime) && i.getCapabilitiesForType(t).isFormatSupported(f)) return i.getName();
        }
        return null;
    }
    public String findEncoderForFormat(MediaFormat f) { return null; }
}
