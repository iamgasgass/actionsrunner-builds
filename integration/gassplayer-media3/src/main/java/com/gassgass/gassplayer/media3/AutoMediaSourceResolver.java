package com.gassgass.gassplayer.media3;

import android.content.Context;
import android.net.Uri;

import androidx.annotation.Nullable;
import androidx.media3.common.MediaItem;
import androidx.media3.common.MimeTypes;
import androidx.media3.datasource.DefaultDataSource;
import androidx.media3.datasource.DefaultHttpDataSource;
import androidx.media3.exoplayer.rtsp.RtspMediaSource;
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory;
import androidx.media3.exoplayer.source.MediaSource;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Preflights an IPTV/media URI so Media3 selects the correct MediaSource even when
 * the provider uses an extensionless endpoint (for example /live/user/pass/1234).
 *
 * IMPORTANT: This class belongs in the GassPlayer application, not in Husk's
 * Android framework. It must run on a worker thread because resolve() performs
 * an HTTP range GET. See the adjacent README for Gradle dependencies and wiring.
 */
public final class AutoMediaSourceResolver {
    private static final int PROBE_LIMIT = 64 * 1024;
    private static final int CONNECT_TIMEOUT_MS = 8000;
    private static final int READ_TIMEOUT_MS = 8000;

    private AutoMediaSourceResolver() {}

    public enum Kind {
        HLS,
        DASH,
        SMOOTH_STREAMING,
        RTSP,
        PROGRESSIVE,
        IPTV_M3U_PLAYLIST
    }

    public static final class ResolvedSource {
        public final Uri uri;
        public final Kind kind;
        public final String responseMimeType;
        public final int httpStatus;

        private ResolvedSource(Uri uri, Kind kind, String mime, int status) {
            this.uri = uri;
            this.kind = kind;
            this.responseMimeType = mime == null ? "" : mime;
            this.httpStatus = status;
        }

        public MediaItem toMediaItem() {
            MediaItem.Builder builder = new MediaItem.Builder().setUri(uri);
            switch (kind) {
                case HLS:
                    builder.setMimeType(MimeTypes.APPLICATION_M3U8);
                    break;
                case DASH:
                    builder.setMimeType(MimeTypes.APPLICATION_MPD);
                    break;
                case SMOOTH_STREAMING:
                    builder.setMimeType(MimeTypes.APPLICATION_SS);
                    break;
                default:
                    // Do not force a MIME type for TS/MP4/Matroska/etc. The default
                    // progressive extractors should sniff the actual container.
                    break;
            }
            return builder.build();
        }
    }

    /**
     * Detects the source using URI scheme/extension, HTTP Content-Type and up to
     * 64 KiB of the response body. The original URI is retained for actual playback
     * so signed URLs and provider routing are not silently rewritten.
     *
     * Call on Dispatchers.IO / an Executor, never on the Android main thread.
     */
    public static ResolvedSource resolve(Uri uri, @Nullable Map<String, String> requestHeaders)
            throws IOException {
        if (uri == null) throw new NullPointerException("uri");
        String scheme = lower(uri.getScheme());
        if ("rtsp".equals(scheme)) {
            return new ResolvedSource(uri, Kind.RTSP, "application/rtsp", 0);
        }
        if (!"http".equals(scheme) && !"https".equals(scheme)) {
            // file/content/asset/rawresource/udp and other non-HTTP sources remain
            // under DefaultMediaSourceFactory's normal source/extractor selection.
            return new ResolvedSource(uri, Kind.PROGRESSIVE, "", 0);
        }

        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(uri.toString()).openConnection();
            connection.setInstanceFollowRedirects(true);
            connection.setConnectTimeout(CONNECT_TIMEOUT_MS);
            connection.setReadTimeout(READ_TIMEOUT_MS);
            connection.setUseCaches(false);
            connection.setRequestMethod("GET");
            connection.setRequestProperty("Range", "bytes=0-" + (PROBE_LIMIT - 1));
            connection.setRequestProperty("Accept", "*/*");
            connection.setRequestProperty("Accept-Encoding", "identity");

            if (requestHeaders != null) {
                for (Map.Entry<String, String> entry : requestHeaders.entrySet()) {
                    String name = entry.getKey();
                    String value = entry.getValue();
                    if (name == null || value == null || name.trim().isEmpty()) continue;
                    // These headers are controlled by the probe and must not be
                    // overridden by caller-supplied values.
                    String n = name.trim().toLowerCase(Locale.ROOT);
                    if ("range".equals(n) || "host".equals(n) || "content-length".equals(n)
                            || "accept-encoding".equals(n) || "connection".equals(n)) continue;
                    connection.setRequestProperty(name.trim(), value);
                }
            }

            int status = connection.getResponseCode();
            String mime = normalizeMime(connection.getContentType());
            if (status < 200 || status >= 300) {
                throw new IOException("Media preflight failed: HTTP " + status
                        + ", Content-Type=" + safeMime(mime));
            }

            byte[] prefix;
            try (InputStream in = connection.getInputStream()) {
                prefix = readAtMost(in, PROBE_LIMIT);
            }
            Kind kind = sniff(uri, mime, prefix);
            if (kind == null) {
                throw new IOException("Media endpoint returned HTML/JSON or an unrecognized response"
                        + " (HTTP " + status + ", Content-Type=" + safeMime(mime) + ")."
                        + " Check provider URL, login, headers, redirect and token expiry.");
            }
            if (kind == Kind.IPTV_M3U_PLAYLIST) {
                throw new IOException("The endpoint is an M3U channel playlist, not a playable media stream."
                        + " Parse the playlist, let the user select a channel, then resolve that channel URL.");
            }
            return new ResolvedSource(uri, kind, mime, status);
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    /** Creates the Media3 source after resolve() has classified the URI. */
    public static MediaSource createMediaSource(Context context,
                                                 ResolvedSource resolved,
                                                 @Nullable Map<String, String> requestHeaders) {
        if (context == null || resolved == null) throw new NullPointerException();
        MediaItem item = resolved.toMediaItem();
        if (resolved.kind == Kind.RTSP) {
            // RTSP authentication is carried in the URI user-info as documented by Media3.
            return new RtspMediaSource.Factory().createMediaSource(item);
        }

        Map<String, String> headers = requestHeaders == null
                ? Collections.<String, String>emptyMap()
                : Collections.unmodifiableMap(new HashMap<>(requestHeaders));
        DefaultHttpDataSource.Factory httpFactory = new DefaultHttpDataSource.Factory()
                .setConnectTimeoutMs(CONNECT_TIMEOUT_MS)
                .setReadTimeoutMs(READ_TIMEOUT_MS)
                .setDefaultRequestProperties(headers);
        DefaultDataSource.Factory dataSourceFactory = new DefaultDataSource.Factory(context, httpFactory);
        DefaultMediaSourceFactory mediaSourceFactory = new DefaultMediaSourceFactory(dataSourceFactory);
        return mediaSourceFactory.createMediaSource(item);
    }

    @Nullable
    private static Kind sniff(Uri uri, String mime, byte[] bytes) {
        String path = lower(uri.getPath());
        String text = textPrefix(bytes);
        String lowerText = text.toLowerCase(Locale.ROOT);

        // An auth portal, WAF, CDN error or provider API response is not media,
        // even when the URL happens to end in .m3u8/.ts. A clear playlist/container
        // signature below takes precedence over a generic/mislabelled Content-Type.
        if (looksLikeHtmlOrJsonBody(lowerText)) return null;

        boolean hlsMime = isHlsMime(mime);
        boolean dashMime = "application/dash+xml".equals(mime);
        boolean smoothMime = isSmoothMime(mime);

        if (isM3u(text)) {
            if (lowerText.contains("#ext-x-") || (hlsMime && !lowerText.contains("#extinf:"))) {
                return Kind.HLS;
            }
            // A normal IPTV M3U contains channels (#EXTINF and media URLs); some
            // providers even give it a .m3u8 suffix. It is not an HLS segment
            // playlist and must be parsed by the IPTV layer.
            if (lowerText.contains("#extinf:")) return Kind.IPTV_M3U_PLAYLIST;
            if (hlsMime || path.endsWith(".m3u8")) return Kind.HLS;
            return Kind.IPTV_M3U_PLAYLIST;
        }

        if (lowerText.contains("<mpd")) return Kind.DASH;
        if (lowerText.contains("<smoothstreamingmedia")) return Kind.SMOOTH_STREAMING;

        // Known progressive containers. The default Media3 extractor factory is
        // responsible for the actual demuxer and stream parsing.
        if (hasAscii(bytes, 4, "ftyp")                 // ISO BMFF / MP4 family
                || hasBytes(bytes, 0, 0x1A, 0x45, 0xDF, 0xA3) // Matroska/WebM
                || hasAscii(bytes, 0, "OggS")          // Ogg
                || hasAscii(bytes, 0, "FLV")            // Flash Video
                || hasAscii(bytes, 0, "ID3")            // MP3 with ID3
                || looksLikeAdts(bytes)
                || looksLikeTransportStream(bytes)
                || hasBytes(bytes, 0, 0x00, 0x00, 0x01, 0xBA) // MPEG program stream
                || hasAscii(bytes, 0, "RIFF")           // AVI/WAVE; extractor validates subtype
                || hasAscii(bytes, 0, "FORM")) {         // AIFF
            return Kind.PROGRESSIVE;
        }

        // A text response that is not one of the recognized manifests is generally
        // an auth/WAF/provider message, not media. Do this before trusting an
        // extension or Content-Type, since IPTV endpoints often return HTML/text
        // errors with HTTP 200 and a media-looking URL.
        if (looksLikeText(text) || looksLikeHtmlOrJsonMime(mime)) return null;

        // Adaptive formats require their actual manifest signature. A suffix or
        // MIME header alone must not turn a binary segment/error page into HLS/DASH.
        // The signature checks above already handled valid manifests; if they did
        // not, the content is not a manifest we can safely classify.
        if (isHlsMime(mime) || path.endsWith(".m3u8") || dashMime || path.endsWith(".mpd")
                || smoothMime || path.endsWith(".ism") || path.endsWith("/manifest")) return null;

        // Content-Type and well-known suffixes may identify a progressive source
        // even when the server starts with padding or a non-standard first packet.
        if (isProgressiveMime(mime) || hasProgressiveSuffix(path)) return Kind.PROGRESSIVE;

        // A valid non-empty binary response with no adaptive manifest signature is
        // left to Media3's DefaultExtractorsFactory. It will either find an extractor
        // or return a useful UnrecognizedInputFormatException.
        if (bytes != null && bytes.length > 0 && !looksLikeText(text)) return Kind.PROGRESSIVE;
        return null;
    }

    private static byte[] readAtMost(InputStream input, int max) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(Math.min(max, 8192));
        byte[] buffer = new byte[8192];
        int total = 0;
        while (total < max) {
            int n = input.read(buffer, 0, Math.min(buffer.length, max - total));
            if (n < 0) break;
            if (n == 0) continue;
            out.write(buffer, 0, n);
            total += n;
        }
        return out.toByteArray();
    }

    private static String normalizeMime(@Nullable String raw) {
        if (raw == null) return "";
        int semicolon = raw.indexOf(';');
        String value = semicolon >= 0 ? raw.substring(0, semicolon) : raw;
        return value.trim().toLowerCase(Locale.ROOT);
    }

    private static boolean isHlsMime(String mime) {
        return "application/vnd.apple.mpegurl".equals(mime)
                || "application/x-mpegurl".equals(mime)
                || "audio/mpegurl".equals(mime)
                || "audio/x-mpegurl".equals(mime)
                || "application/mpegurl".equals(mime);
    }

    private static boolean isSmoothMime(String mime) {
        return "application/vnd.ms-sstr+xml".equals(mime)
                || "application/vnd.ms-ss".equals(mime);
    }

    private static boolean isProgressiveMime(String mime) {
        return mime.startsWith("video/") || mime.startsWith("audio/")
                || mime.equals("application/octet-stream")
                || mime.equals("application/mp4")
                || mime.equals("video/mp2t");
    }

    private static boolean isM3u(String text) {
        return text != null && text.trim().startsWith("#EXTM3U");
    }

    private static boolean looksLikeHtmlOrJsonBody(String text) {
        if (text == null) return false;
        String s = text.trim().toLowerCase(Locale.ROOT);
        return s.startsWith("<!doctype html") || s.startsWith("<html")
                || s.startsWith("{\"") || s.startsWith("[{\"")
                || s.startsWith("[\n{") || s.startsWith("{\n\"");
    }

    private static boolean looksLikeHtmlOrJsonMime(String mime) {
        return mime != null && (mime.equals("text/html") || mime.equals("application/json")
                || mime.endsWith("+json") || mime.equals("text/json"));
    }

    private static boolean looksLikeText(String text) {
        if (text == null || text.isEmpty()) return true;
        int sample = Math.min(text.length(), 512);
        int printable = 0;
        for (int i = 0; i < sample; i++) {
            char c = text.charAt(i);
            if (c == '\n' || c == '\r' || c == '\t' || (c >= 0x20 && c < 0x7f)) printable++;
        }
        return printable > sample * 0.90;
    }

    private static String textPrefix(byte[] bytes) {
        if (bytes == null || bytes.length == 0) return "";
        String value = new String(bytes, StandardCharsets.UTF_8);
        if (!value.isEmpty() && value.charAt(0) == '\uFEFF') value = value.substring(1);
        return value;
    }

    private static boolean hasAscii(byte[] data, int offset, String value) {
        if (data == null || offset < 0 || offset + value.length() > data.length) return false;
        for (int i = 0; i < value.length(); i++) if ((data[offset + i] & 0xff) != value.charAt(i)) return false;
        return true;
    }

    private static boolean hasBytes(byte[] data, int offset, int... values) {
        if (data == null || offset < 0 || offset + values.length > data.length) return false;
        for (int i = 0; i < values.length; i++) if ((data[offset + i] & 0xff) != values[i]) return false;
        return true;
    }

    private static boolean looksLikeAdts(byte[] b) {
        return b != null && b.length >= 2 && (b[0] & 0xff) == 0xff && (b[1] & 0xf6) == 0xf0;
    }

    private static boolean looksLikeTransportStream(byte[] b) {
        if (b == null || b.length < 3 * 188) return false;
        // MPEG-TS packets are normally 188 bytes; M2TS adds a four-byte prefix.
        for (int offset : new int[] { 0, 4 }) {
            if (b.length > offset + 2 * 188
                    && (b[offset] & 0xff) == 0x47
                    && (b[offset + 188] & 0xff) == 0x47
                    && (b[offset + 376] & 0xff) == 0x47) return true;
        }
        return false;
    }

    private static boolean hasProgressiveSuffix(String path) {
        return path.endsWith(".mp4") || path.endsWith(".m4v") || path.endsWith(".m4a")
                || path.endsWith(".mov") || path.endsWith(".mkv") || path.endsWith(".webm")
                || path.endsWith(".ts") || path.endsWith(".m2ts") || path.endsWith(".mpg")
                || path.endsWith(".mpeg") || path.endsWith(".mp3") || path.endsWith(".aac")
                || path.endsWith(".wav") || path.endsWith(".flac") || path.endsWith(".ogg")
                || path.endsWith(".avi") || path.endsWith(".flv");
    }

    private static String lower(@Nullable String value) {
        return value == null ? "" : value.toLowerCase(Locale.ROOT);
    }

    private static String safeMime(String mime) {
        return mime == null || mime.isEmpty() ? "unknown" : mime;
    }
}
