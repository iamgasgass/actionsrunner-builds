// SPDX-License-Identifier: GPL-2.0-or-later
package android.app;

import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import java.io.File;

/** Android's download service, run in the app's process: a request is fetched over HTTP(S) on a background thread (headers,
 *  redirects across http/https, resuming after a pause), written where the request says (or into the app's external cache
 *  when it says nothing), and reported through query() with the platform's columns and status codes. When a download ends,
 *  ACTION_DOWNLOAD_COMPLETE goes to the app as the system would send it. Downloads last as long as the app runs. */
@SuppressWarnings({"unchecked", "rawtypes", "deprecation"})
public class DownloadManager {
    public static final java.lang.String ACTION_DOWNLOAD_COMPLETE = "android.intent.action.DOWNLOAD_COMPLETE";
    public static final java.lang.String ACTION_DOWNLOAD_COMPLETED = "android.intent.action.DOWNLOAD_COMPLETED";
    public static final java.lang.String ACTION_NOTIFICATION_CLICKED = "android.intent.action.DOWNLOAD_NOTIFICATION_CLICKED";
    public static final java.lang.String ACTION_VIEW_DOWNLOADS = "android.intent.action.VIEW_DOWNLOADS";
    public static final java.lang.String COLUMN_ALLOW_WRITE = "allow_write";
    public static final java.lang.String COLUMN_BYTES_DOWNLOADED_SO_FAR = "bytes_so_far";
    public static final java.lang.String COLUMN_DESCRIPTION = "description";
    public static final java.lang.String COLUMN_DESTINATION = "destination";
    public static final java.lang.String COLUMN_FILE_NAME_HINT = "hint";
    public static final java.lang.String COLUMN_ID = "_id";
    public static final java.lang.String COLUMN_LAST_MODIFIED_TIMESTAMP = "last_modified_timestamp";
    public static final java.lang.String COLUMN_LOCAL_FILENAME = "local_filename";
    public static final java.lang.String COLUMN_LOCAL_URI = "local_uri";
    public static final java.lang.String COLUMN_MEDIAPROVIDER_URI = "mediaprovider_uri";
    public static final java.lang.String COLUMN_MEDIASTORE_URI = "mediastore_uri";
    public static final java.lang.String COLUMN_MEDIA_TYPE = "media_type";
    public static final java.lang.String COLUMN_REASON = "reason";
    public static final java.lang.String COLUMN_STATUS = "status";
    public static final java.lang.String COLUMN_TITLE = "title";
    public static final java.lang.String COLUMN_TOTAL_SIZE_BYTES = "total_size";
    public static final java.lang.String COLUMN_URI = "uri";
    public static final int ERROR_BLOCKED = 1010;
    public static final int ERROR_CANNOT_RESUME = 1008;
    public static final int ERROR_DEVICE_NOT_FOUND = 1007;
    public static final int ERROR_FILE_ALREADY_EXISTS = 1009;
    public static final int ERROR_FILE_ERROR = 1001;
    public static final int ERROR_HTTP_DATA_ERROR = 1004;
    public static final int ERROR_INSUFFICIENT_SPACE = 1006;
    public static final int ERROR_TOO_MANY_REDIRECTS = 1005;
    public static final int ERROR_UNHANDLED_HTTP_CODE = 1002;
    public static final int ERROR_UNKNOWN = 1000;
    public static final java.lang.String EXTRA_DOWNLOAD_ID = "extra_download_id";
    public static final java.lang.String EXTRA_NOTIFICATION_CLICK_DOWNLOAD_IDS = "extra_click_download_ids";
    public static final java.lang.String INTENT_EXTRAS_SORT_BY_SIZE = "android.app.DownloadManager.extra_sortBySize";
    public static final int PAUSED_MANUAL = 5;
    public static final int PAUSED_QUEUED_FOR_WIFI = 3;
    public static final int PAUSED_UNKNOWN = 4;
    public static final int PAUSED_WAITING_FOR_NETWORK = 2;
    public static final int PAUSED_WAITING_TO_RETRY = 1;
    public static final int STATUS_FAILED = 16;
    public static final int STATUS_PAUSED = 4;
    public static final int STATUS_PENDING = 1;
    public static final int STATUS_RUNNING = 2;
    public static final int STATUS_SUCCESSFUL = 8;
    public static java.lang.String[] UNDERLYING_COLUMNS = { COLUMN_ID, COLUMN_LOCAL_FILENAME, COLUMN_MEDIAPROVIDER_URI, COLUMN_DESTINATION, COLUMN_TITLE,
        COLUMN_DESCRIPTION, COLUMN_URI, COLUMN_STATUS, COLUMN_FILE_NAME_HINT, COLUMN_MEDIA_TYPE, COLUMN_TOTAL_SIZE_BYTES, COLUMN_LAST_MODIFIED_TIMESTAMP,
        COLUMN_BYTES_DOWNLOADED_SO_FAR, COLUMN_ALLOW_WRITE, COLUMN_LOCAL_URI, COLUMN_REASON };
    private static final String[] COLUMNS = { COLUMN_ID, COLUMN_MEDIAPROVIDER_URI, COLUMN_TITLE, COLUMN_DESCRIPTION, COLUMN_URI, COLUMN_MEDIA_TYPE,
        COLUMN_TOTAL_SIZE_BYTES, COLUMN_LOCAL_URI, COLUMN_STATUS, COLUMN_REASON, COLUMN_BYTES_DOWNLOADED_SO_FAR, COLUMN_LAST_MODIFIED_TIMESTAMP,
        COLUMN_LOCAL_FILENAME, COLUMN_MEDIASTORE_URI, COLUMN_ALLOW_WRITE, COLUMN_DESTINATION, COLUMN_FILE_NAME_HINT };

    /** One download: what was asked for, and how far it has got. */
    private static final class Item {
        long id; Uri uri; String title, description, mime, hint; java.util.ArrayList<String[]> headers = new java.util.ArrayList<>();
        File file; volatile int status = STATUS_PENDING, reason; volatile long total = -1, done; volatile long modified = System.currentTimeMillis();
        boolean visible = true, completedByApp; volatile boolean paused, removed; volatile int retries; Thread thread;
    }
    private static final java.util.LinkedHashMap<Long, Item> sItems = new java.util.LinkedHashMap<>();
    private static long sNextId = 1;
    private final android.content.Context mContext;

    public DownloadManager(android.content.Context p0) { mContext = p0; }
    DownloadManager() { this((android.content.Context) null); }

    private android.content.Context ctx() {
        android.content.Context c = mContext;
        if (c == null) c = husk.ContextImpl.app();
        return c;
    }
    public static long getActiveNetworkWarningBytes(android.content.Context p0) { return -1L; }
    public static java.lang.Long getMaxBytesOverMobile(android.content.Context p0) { return null; }
    public static java.lang.Long getRecommendedMaxBytesOverMobile(android.content.Context p0) { return null; }
    public static boolean isActiveNetworkExpensive(android.content.Context p0) { return false; }

    public long enqueue(android.app.DownloadManager.Request r) {
        if (r == null || r.uri == null) throw new IllegalArgumentException("a download needs a URI");
        String scheme = r.uri.getScheme();
        if (!"http".equalsIgnoreCase(scheme) && !"https".equalsIgnoreCase(scheme)) throw new IllegalArgumentException("Can only download HTTP/HTTPS URIs: " + r.uri);
        Item it = new Item();
        it.uri = r.uri; it.title = r.title != null ? r.title.toString() : null; it.description = r.description != null ? r.description.toString() : "";
        it.mime = r.mime; it.headers.addAll(r.headers); it.visible = r.visible;
        it.file = destination(r);
        it.hint = it.file != null ? Uri.fromFile(it.file).toString() : null;
        synchronized (sItems) { it.id = sNextId++; sItems.put(it.id, it); }
        start(it);
        return it.id;
    }
    /** Where the request asked for the file, or a name of its own in the external cache. */
    private File destination(Request r) {
        File f = null;
        if (r.dest != null && "file".equals(r.dest.getScheme()) && r.dest.getPath() != null) f = new File(r.dest.getPath());
        else if (r.publicDir != null) f = new File(android.os.Environment.getExternalStoragePublicDirectory(r.publicDir), r.subPath != null ? r.subPath : guessName(r));
        else if (r.filesDirSet) {
            File base = ctx() != null ? ctx().getExternalFilesDir(r.filesDirType) : null;
            if (base == null && ctx() != null) base = ctx().getFilesDir();
            f = new File(base, r.subPath != null ? r.subPath : guessName(r));
        }
        if (f == null) {
            File base = ctx() != null ? ctx().getExternalCacheDir() : null;
            if (base == null && ctx() != null) base = ctx().getCacheDir();
            if (base == null) base = new File(System.getProperty("java.io.tmpdir", "/tmp"));
            f = new File(new File(base, "Download"), guessName(r));
        }
        if (f.getParentFile() != null) f.getParentFile().mkdirs();
        /* a name already taken gets -1, -2 ... as Android's provider does */
        if (f.exists() && !r.overwrite) {
            String n = f.getName(), ext = ""; int dot = n.lastIndexOf('.');
            if (dot > 0) { ext = n.substring(dot); n = n.substring(0, dot); }
            for (int k = 1; f.exists() && k < 10000; k++) f = new File(f.getParentFile(), n + "-" + k + ext);
        }
        return f;
    }
    private static String guessName(Request r) {
        String n = r.uri.getLastPathSegment();
        if (n == null || n.isEmpty()) n = "downloadfile";
        n = n.replaceAll("[\\\\/:*?\"<>|]", "_");
        if (n.indexOf('.') < 0 && r.mime != null) {
            String ext = android.webkit.MimeTypeMap.getSingleton().getExtensionFromMimeType(r.mime);
            if (ext != null) n += "." + ext;
        }
        return n;
    }
    private void start(final Item it) {
        Thread t = new Thread(() -> run(it), "DownloadManager-" + it.id);
        t.setDaemon(true);
        it.thread = t;
        t.start();
    }
    private void run(Item it) {
        String url = it.uri.toString();
        it.status = STATUS_RUNNING; it.reason = 0; it.modified = System.currentTimeMillis();
        java.net.HttpURLConnection c = null;
        try {
            for (int hop = 0; ; hop++) {
                if (hop > 7) { fail(it, ERROR_TOO_MANY_REDIRECTS); return; }
                c = (java.net.HttpURLConnection) new java.net.URL(url).openConnection();
                c.setInstanceFollowRedirects(false);
                c.setConnectTimeout(20000); c.setReadTimeout(30000);
                for (String[] h : it.headers) c.addRequestProperty(h[0], h[1]);
                if (it.done > 0 && it.file.exists() && it.file.length() == it.done) c.setRequestProperty("Range", "bytes=" + it.done + "-");
                else it.done = 0;
                int code = c.getResponseCode();
                if (code >= 300 && code < 400 && code != 304) {
                    String loc = c.getHeaderField("Location");
                    c.disconnect();
                    if (loc == null) { fail(it, ERROR_UNHANDLED_HTTP_CODE); return; }
                    url = new java.net.URL(new java.net.URL(url), loc).toString();
                    continue;
                }
                if (code == 416 && it.done > 0) { finish(it); return; }      /* already have all of it */
                if (code != 200 && code != 206) { fail(it, code >= 400 && code < 600 ? code : ERROR_UNHANDLED_HTTP_CODE); return; }
                boolean append = code == 206 && it.done > 0;
                if (!append) it.done = 0;
                long len = c.getContentLengthLong();
                it.total = len < 0 ? -1 : len + (append ? it.done : 0);
                if (it.mime == null) { String ct = c.getContentType(); if (ct != null) it.mime = ct.split(";")[0].trim(); }
                try (java.io.InputStream in = new java.io.BufferedInputStream(c.getInputStream());
                     java.io.OutputStream out = new java.io.FileOutputStream(it.file, append)) {
                    byte[] buf = new byte[64 * 1024];
                    int n;
                    while ((n = in.read(buf)) > 0) {
                        if (it.removed) return;
                        if (it.paused) { it.status = STATUS_PAUSED; it.reason = PAUSED_MANUAL; return; }
                        out.write(buf, 0, n);
                        it.done += n;
                        it.modified = System.currentTimeMillis();
                    }
                }
                if (it.total < 0) it.total = it.done;
                finish(it);
                return;
            }
        } catch (java.io.FileNotFoundException e) {
            File dir = it.file != null ? it.file.getAbsoluteFile().getParentFile() : null;
            fail(it, dir != null && !dir.canWrite() ? ERROR_FILE_ERROR : ERROR_HTTP_DATA_ERROR);
        } catch (java.io.IOException e) {
            if (it.removed) return;
            android.util.Log.w("DownloadManager", "download " + it.id + " stopped: " + e);
            it.status = STATUS_PAUSED; it.reason = PAUSED_WAITING_TO_RETRY;
            retryLater(it);
        } catch (Throwable e) {
            android.util.Log.e("DownloadManager", "download " + it.id + " failed", e);
            fail(it, ERROR_UNKNOWN);
        } finally {
            if (c != null) c.disconnect();
        }
    }
    private void retryLater(final Item it) {
        new android.os.Handler(android.os.Looper.getMainLooper()).postDelayed(() -> {
            if (!it.removed && !it.paused && it.status == STATUS_PAUSED && it.reason == PAUSED_WAITING_TO_RETRY) {
                if (++it.retries > 5) fail(it, ERROR_CANNOT_RESUME); else start(it);
            }
        }, 5000L * Math.max(1, it.retries));
    }
    private void finish(Item it) { it.status = STATUS_SUCCESSFUL; it.reason = 0; it.modified = System.currentTimeMillis(); announce(it); }
    private void fail(Item it, int reason) { it.status = STATUS_FAILED; it.reason = reason; it.modified = System.currentTimeMillis(); announce(it); }
    private void announce(Item it) {
        if (it.removed) return;
        android.content.Context c = ctx();
        if (c == null) return;
        android.content.Intent i = new android.content.Intent(ACTION_DOWNLOAD_COMPLETE);
        i.setPackage(c.getPackageName());
        i.putExtra(EXTRA_DOWNLOAD_ID, it.id);
        husk.Broadcasts.send(c, i, true);
    }

    public long addCompletedDownload(java.lang.String title, java.lang.String description, boolean scannable, java.lang.String mime, java.lang.String path, long length, boolean notify) {
        return addCompletedDownload(title, description, scannable, mime, path, length, notify, false, null, null);
    }
    public long addCompletedDownload(java.lang.String p0, java.lang.String p1, boolean p2, java.lang.String p3, java.lang.String p4, long p5, boolean p6, android.net.Uri p7, android.net.Uri p8) {
        return addCompletedDownload(p0, p1, p2, p3, p4, p5, p6, false, p7, p8);
    }
    public long addCompletedDownload(java.lang.String p0, java.lang.String p1, boolean p2, java.lang.String p3, java.lang.String p4, long p5, boolean p6, boolean p7) {
        return addCompletedDownload(p0, p1, p2, p3, p4, p5, p6, p7, null, null);
    }
    public long addCompletedDownload(java.lang.String title, java.lang.String description, boolean scannable, java.lang.String mime, java.lang.String path, long length, boolean notify, boolean hidden, android.net.Uri uri, android.net.Uri referer) {
        if (path == null || title == null || title.isEmpty()) throw new IllegalArgumentException("a completed download needs a title and a path");
        Item it = new Item();
        it.title = title; it.description = description != null ? description : ""; it.mime = mime; it.file = new File(path);
        it.uri = uri; it.total = length; it.done = length; it.status = STATUS_SUCCESSFUL; it.completedByApp = true; it.visible = !hidden;
        it.hint = Uri.fromFile(it.file).toString();
        synchronized (sItems) { it.id = sNextId++; sItems.put(it.id, it); }
        return it.id;
    }
    public void forceDownload(long[] ids) { restartDownload(ids); }
    public android.net.Uri getDownloadUri(long id) { return Uri.parse("content://downloads/all_downloads/" + id); }
    public java.lang.String getMimeTypeForDownloadedFile(long id) {
        Item it = item(id);
        if (it == null) return null;
        if (it.mime != null) return it.mime;
        String ext = android.webkit.MimeTypeMap.getFileExtensionFromUrl(it.file.getName());
        return ext == null ? null : android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext);
    }
    public android.net.Uri getUriForDownloadedFile(long id) {
        Item it = item(id);
        return it == null || it.status != STATUS_SUCCESSFUL ? null : Uri.fromFile(it.file);
    }
    public int markRowDeleted(long[] ids) { return remove(ids); }
    public void onMediaStoreDownloadsDeleted(android.util.LongSparseArray p0) {}
    public android.os.ParcelFileDescriptor openDownloadedFile(long id) throws java.io.FileNotFoundException {
        Item it = item(id);
        if (it == null || it.status != STATUS_SUCCESSFUL) throw new java.io.FileNotFoundException("download " + id + " is not finished");
        return android.os.ParcelFileDescriptor.open(it.file, android.os.ParcelFileDescriptor.MODE_READ_ONLY);
    }
    public int pauseDownload(long id) {
        Item it = item(id);
        if (it == null || it.status != STATUS_RUNNING && it.status != STATUS_PENDING) return 0;
        it.paused = true;
        return 1;
    }
    public int resumeDownload(long id) {
        Item it = item(id);
        if (it == null || it.status != STATUS_PAUSED) return 0;
        it.paused = false; it.retries = 0;
        start(it);
        return 1;
    }
    public android.database.Cursor query(android.app.DownloadManager.Query q) { return query(q, null); }
    public android.database.Cursor query(android.app.DownloadManager.Query q, java.lang.String[] projection) {
        MatrixCursor m = new MatrixCursor(COLUMNS);
        java.util.ArrayList<Item> items;
        synchronized (sItems) { items = new java.util.ArrayList<>(sItems.values()); }
        if (q != null && q.descending) java.util.Collections.reverse(items);
        for (Item it : items) {
            if (it.removed) continue;
            if (q != null && q.ids != null) { boolean hit = false; for (long x : q.ids) if (x == it.id) hit = true; if (!hit) continue; }
            if (q != null && q.statusMask != 0 && (q.statusMask & it.status) == 0) continue;
            if (q != null && q.onlyVisible && !it.visible) continue;
            if (q != null && q.text != null) {
                String hay = ((it.title != null ? it.title : "") + " " + (it.description != null ? it.description : "")).toLowerCase(java.util.Locale.ROOT);
                if (!hay.contains(q.text.toLowerCase(java.util.Locale.ROOT))) continue;
            }
            String local = it.file != null ? Uri.fromFile(it.file).toString() : null;
            m.addRow(new Object[] { it.id, null, it.title != null ? it.title : (it.uri != null ? it.uri.getLastPathSegment() : ""), it.description,
                it.uri != null ? it.uri.toString() : null, it.mime, it.total, it.status == STATUS_SUCCESSFUL ? local : null, it.status, it.reason, it.done,
                it.modified, it.file != null ? it.file.getAbsolutePath() : null, null, 0, 4, it.hint });
        }
        return m;
    }
    public int remove(long[] ids) {
        int n = 0;
        if (ids == null) return 0;
        for (long id : ids) {
            Item it;
            synchronized (sItems) { it = sItems.remove(id); }
            if (it == null) continue;
            it.removed = true;
            if (it.file != null && !it.completedByApp) it.file.delete();
            n++;
        }
        return n;
    }
    public boolean rename(android.content.Context c, long id, java.lang.String name) {
        Item it = item(id);
        if (it == null || it.status != STATUS_SUCCESSFUL || name == null || name.contains("/")) return false;
        File to = new File(it.file.getParentFile(), name);
        if (!it.file.renameTo(to)) return false;
        it.file = to; it.title = name;
        return true;
    }
    public void restartDownload(long[] ids) {
        if (ids == null) return;
        for (long id : ids) {
            Item it = item(id);
            if (it == null || it.status == STATUS_RUNNING || it.completedByApp) continue;
            it.done = 0; it.total = -1; it.paused = false; it.retries = 0; it.status = STATUS_PENDING;
            start(it);
        }
    }
    public void setAccessAllDownloads(boolean p0) {}
    public void setAccessFilename(boolean p0) {}
    private static Item item(long id) { synchronized (sItems) { return sItems.get(id); } }

    public static class Query {
        public static final int ORDER_ASCENDING = 1;
        public static final int ORDER_DESCENDING = 2;
        long[] ids; int statusMask; String text; boolean onlyVisible, descending = true;
        public Query() {}
        public android.app.DownloadManager.Query orderBy(java.lang.String column, int direction) { descending = direction == ORDER_DESCENDING; return this; }
        public android.app.DownloadManager.Query setFilterById(long... p0) { ids = p0; return this; }
        public android.app.DownloadManager.Query setFilterByStatus(int p0) { statusMask = p0; return this; }
        public android.app.DownloadManager.Query setFilterByString(java.lang.String p0) { text = p0; return this; }
        public android.app.DownloadManager.Query setOnlyIncludeVisibleInDownloadsUi(boolean p0) { onlyVisible = p0; return this; }
    }
    public static class Request {
        public static final int NETWORK_BLUETOOTH = 4;
        public static final int NETWORK_MOBILE = 1;
        public static final int NETWORK_WIFI = 2;
        public static final int VISIBILITY_HIDDEN = 2;
        public static final int VISIBILITY_VISIBLE = 0;
        public static final int VISIBILITY_VISIBLE_NOTIFY_COMPLETED = 1;
        public static final int VISIBILITY_VISIBLE_NOTIFY_ONLY_COMPLETION = 3;
        final Uri uri; final java.util.ArrayList<String[]> headers = new java.util.ArrayList<>();
        CharSequence title, description; String mime, publicDir, filesDirType, subPath; Uri dest; boolean filesDirSet, visible = true, overwrite;
        public Request(android.net.Uri p0) {
            if (p0 == null) throw new NullPointerException("uri");
            uri = p0;
        }
        Request() { uri = null; }
        public android.app.DownloadManager.Request addRequestHeader(java.lang.String header, java.lang.String value) {
            if (header == null) throw new NullPointerException("header cannot be null");
            if (header.contains(":")) throw new IllegalArgumentException("header may not contain ':'");
            headers.add(new String[] { header, value == null ? "" : value });
            return this;
        }
        public void allowScanningByMediaScanner() {}
        public android.app.DownloadManager.Request setAllowedNetworkTypes(int p0) { return this; }
        public android.app.DownloadManager.Request setAllowedOverMetered(boolean p0) { return this; }
        public android.app.DownloadManager.Request setAllowedOverRoaming(boolean p0) { return this; }
        public android.app.DownloadManager.Request setDescription(java.lang.CharSequence p0) { description = p0; return this; }
        public android.app.DownloadManager.Request setDestinationInExternalFilesDir(android.content.Context c, java.lang.String type, java.lang.String sub) { filesDirSet = true; filesDirType = type; subPath = sub; publicDir = null; dest = null; return this; }
        public android.app.DownloadManager.Request setDestinationInExternalPublicDir(java.lang.String type, java.lang.String sub) { publicDir = type; subPath = sub; filesDirSet = false; dest = null; return this; }
        public android.app.DownloadManager.Request setDestinationUri(android.net.Uri p0) { dest = p0; publicDir = null; filesDirSet = false; overwrite = false; return this; }
        public android.app.DownloadManager.Request setMimeType(java.lang.String p0) { mime = p0; return this; }
        public android.app.DownloadManager.Request setNotificationVisibility(int p0) { return this; }
        public android.app.DownloadManager.Request setRequiresCharging(boolean p0) { return this; }
        public android.app.DownloadManager.Request setRequiresDeviceIdle(boolean p0) { return this; }
        public android.app.DownloadManager.Request setShowRunningNotification(boolean p0) { return this; }
        public android.app.DownloadManager.Request setTitle(java.lang.CharSequence p0) { title = p0; return this; }
        public android.app.DownloadManager.Request setVisibleInDownloadsUi(boolean p0) { visible = p0; return this; }
    }
}
