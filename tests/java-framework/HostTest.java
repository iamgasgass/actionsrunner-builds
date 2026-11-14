import android.app.Service;
import android.app.job.*;
import android.content.*;
import android.os.*;
import java.util.*;
import java.util.concurrent.atomic.*;

public class HostTest {
    static final List<String> log = Collections.synchronizedList(new ArrayList<>());
    static int fails = 0;
    static void check(boolean ok, String what) { System.out.println((ok ? "PASS " : "FAIL ") + what); if (!ok) fails++; }

    public static class WorkJob extends JobService {
        public void onCreate() { log.add("WorkJob.onCreate"); }
        public void onDestroy() { log.add("WorkJob.onDestroy"); }
        public boolean onStartJob(final JobParameters p) {
            log.add("start " + p.getJobId());
            new Thread(() -> {
                JobWorkItem w;
                while ((w = p.dequeueWork()) != null) { log.add("work " + w.getIntent().getStringExtra("n")); p.completeWork(w); }
            }).start();
            return true;
        }
        public boolean onStopJob(JobParameters p) { log.add("stop " + p.getJobId()); return false; }
    }
    public static class SimpleJob extends JobService {
        public boolean onStartJob(JobParameters p) { log.add("simple " + p.getJobId() + " " + p.getExtras().getString("k")); return false; }
        public boolean onStopJob(JobParameters p) { return false; }
    }
    public static class LongJob extends JobService {
        public boolean onStartJob(JobParameters p) { log.add("long start"); return true; }
        public boolean onStopJob(JobParameters p) { log.add("long stop reason=" + p.getStopReason()); return false; }
    }
    public static class BoundSvc extends Service {
        public void onCreate() { log.add("Bound.onCreate"); }
        public int onStartCommand(Intent i, int f, int id) { log.add("Bound.start " + id); return START_STICKY; }
        public IBinder onBind(Intent i) { log.add("Bound.onBind"); return new Binder(); }
        public boolean onUnbind(Intent i) { log.add("Bound.onUnbind"); return true; }
        public void onRebind(Intent i) { log.add("Bound.onRebind"); }
        public void onDestroy() { log.add("Bound.onDestroy"); }
    }

    static void sleep(long ms) { try { Thread.sleep(ms); } catch (InterruptedException e) {} }
    static void waitFor(java.util.function.BooleanSupplier c, long ms) { long end = System.currentTimeMillis() + ms; while (!c.getAsBoolean() && System.currentTimeMillis() < end) sleep(10); }

    public static void main(String[] a) throws Exception {
        Thread main = new Thread(() -> { Looper.prepareMainLooper(); Looper.loop(); }, "main");
        main.setDaemon(true); main.start();
        waitFor(() -> Looper.getMainLooper() != null, 2000);
        Handler h = new Handler(Looper.getMainLooper());

        for (String n : new String[] { "HostTest$WorkJob", "HostTest$SimpleJob", "HostTest$LongJob", "HostTest$BoundSvc" }) {
            husk.Manifest.Component c = new husk.Manifest.Component(); c.name = n; c.kind = "service"; husk.Manifest.services.add(c);
        }
        JobScheduler js = new JobScheduler.Impl();
        ComponentName workCn = new ComponentName("com.husk.test", "HostTest$WorkJob");

        // --- enqueue work: every item delivered, job finishes, service destroyed
        JobInfo wj = new JobInfo.Builder(7, workCn).setOverrideDeadline(0).build();
        for (int i = 0; i < 3; i++) js.enqueue(wj, new JobWorkItem(new Intent().putExtra("n", "w" + i)));
        waitFor(() -> log.contains("WorkJob.onDestroy"), 3000);
        System.out.println(log);
        check(log.contains("work w0") && log.contains("work w1") && log.contains("work w2"), "JobWorkItems all dequeued");
        check(js.getPendingJob(7) == null, "job with drained work is no longer pending");
        check(log.contains("WorkJob.onDestroy"), "JobService destroyed after its job");
        log.clear();

        // --- minimum latency honoured, extras kept
        PersistableBundle e = new PersistableBundle(); e.putString("k", "v");
        JobInfo sj = new JobInfo.Builder(8, new ComponentName("com.husk.test", "HostTest$SimpleJob")).setMinimumLatency(400).setExtras(e).build();
        check(sj.getMinLatencyMillis() == 400 && sj.hasEarlyConstraint(), "JobInfo keeps min latency");
        js.schedule(sj);
        sleep(150);
        check(!log.contains("simple 8 v"), "job did not run before its latency");
        check(js.getAllPendingJobs().size() == 1, "job pending while waiting");
        waitFor(() -> log.contains("simple 8 v"), 2000);
        check(log.contains("simple 8 v"), "job ran after latency with its extras");
        sleep(50);
        check(js.getPendingJob(8) == null, "one-shot job gone after onStartJob returned false");
        log.clear();

        // --- periodic rounding and cancel -> onStopJob
        JobInfo pj = new JobInfo.Builder(9, new ComponentName("com.husk.test", "HostTest$LongJob")).setPeriodic(1000).build();
        check(pj.isPeriodic() && pj.getIntervalMillis() == JobInfo.getMinPeriodMillis(), "periodic interval clamped to the minimum");
        JobInfo lj = new JobInfo.Builder(10, new ComponentName("com.husk.test", "HostTest$LongJob")).build();
        js.schedule(lj);
        waitFor(() -> log.contains("long start"), 2000);
        js.cancel(10);
        waitFor(() -> log.stream().anyMatch(s -> s.startsWith("long stop")), 2000);
        check(log.contains("long stop reason=1"), "cancel stops a running job with STOP_REASON_CANCELLED_BY_APP");
        log.clear();

        // --- service lifecycle
        Context ctx = new ContextWrapper(null);
        final AtomicReference<IBinder> b1 = new AtomicReference<>(), b2 = new AtomicReference<>();
        ServiceConnection c1 = new ServiceConnection() { public void onServiceConnected(ComponentName n, IBinder b) { b1.set(b); } public void onServiceDisconnected(ComponentName n) {} };
        ServiceConnection c2 = new ServiceConnection() { public void onServiceConnected(ComponentName n, IBinder b) { b2.set(b); } public void onServiceDisconnected(ComponentName n) {} };
        Intent bi = new Intent().setComponent(new ComponentName("com.husk.test", "HostTest$BoundSvc"));
        husk.Services.bind(ctx, bi, c1, Context.BIND_AUTO_CREATE);
        husk.Services.bind(ctx, bi, c2, Context.BIND_AUTO_CREATE);
        waitFor(() -> b1.get() != null && b2.get() != null, 2000);
        check(b1.get() != null && b1.get() == b2.get(), "two clients get the same binder");
        check(Collections.frequency(log, "Bound.onBind") == 1, "onBind called once");
        husk.Services.start(ctx, bi); husk.Services.start(ctx, bi);
        waitFor(() -> log.contains("Bound.start 2"), 2000);
        check(log.contains("Bound.start 1") && log.contains("Bound.start 2"), "start ids increase");
        h.post(() -> { husk.Services.unbind(c1); husk.Services.unbind(c2); });
        waitFor(() -> log.contains("Bound.onUnbind"), 2000);
        sleep(50);
        check(log.contains("Bound.onUnbind") && !log.contains("Bound.onDestroy"), "started service survives unbind");
        final AtomicReference<IBinder> b3 = new AtomicReference<>();
        ServiceConnection c3 = new ServiceConnection() { public void onServiceConnected(ComponentName n, IBinder b) { b3.set(b); } public void onServiceDisconnected(ComponentName n) {} };
        husk.Services.bind(ctx, bi, c3, Context.BIND_AUTO_CREATE);
        waitFor(() -> b3.get() != null, 2000);
        check(log.contains("Bound.onRebind"), "onRebind after onUnbind returned true");
        h.post(() -> husk.Services.unbind(c3));
        sleep(100);
        husk.Services.stop(bi);
        waitFor(() -> log.contains("Bound.onDestroy"), 2000);
        check(log.contains("Bound.onDestroy"), "destroyed once stopped and unbound");
        System.out.println(log);
        log.clear();

        // --- misc
        android.net.MacAddress m = android.net.MacAddress.fromString("02:00:5e:10:00:ff");
        check("02:00:5e:10:00:ff".equals(m.toString()) && m.isLocallyAssigned() && m.getAddressType() == 1, "MacAddress parse/print/type");
        android.text.util.Rfc822Token[] t = android.text.util.Rfc822Tokenizer.tokenize("\"Doe, John\" <john@x.org>, jane@y.org (Jane)");
        check(t.length == 2 && "john@x.org".equals(t[0].getAddress()) && "Doe, John".equals(t[0].getName()) && "jane@y.org".equals(t[1].getAddress()) && "Jane".equals(t[1].getComment()), "Rfc822Tokenizer");
        android.view.textclassifier.TextSelection sel = android.view.textclassifier.TextClassifier.NO_OP.suggestSelection("hello world", 2, 5, null);
        check(sel != null && sel.getSelectionStartIndex() == 2 && sel.getSelectionEndIndex() == 5, "TextClassifier.NO_OP answers");
        int[] r = new android.animation.IntArrayEvaluator().evaluate(0.5f, new int[] { 0, 10 }, new int[] { 10, 20 });
        check(r[0] == 5 && r[1] == 15, "IntArrayEvaluator");

        // --- PendingIntent tokens and AlarmManager
        Context app = new ContextWrapper(null) {
            @Override public void sendBroadcast(Intent i) { log.add("bcast " + i.getAction() + " " + i.getStringExtra("x")); }
            @Override public Context getApplicationContext() { return this; }
        };
        Intent ai = new Intent("ALARM");
        android.app.PendingIntent p1 = android.app.PendingIntent.getBroadcast(app, 1, new Intent(ai).putExtra("x", "a"), android.app.PendingIntent.FLAG_IMMUTABLE);
        android.app.PendingIntent p1b = android.app.PendingIntent.getBroadcast(app, 1, new Intent(ai).putExtra("x", "b"), android.app.PendingIntent.FLAG_UPDATE_CURRENT);
        check(p1 == p1b, "same request code + filterEquals intent gives the same PendingIntent");
        check(android.app.PendingIntent.getBroadcast(app, 2, ai, android.app.PendingIntent.FLAG_NO_CREATE) == null, "FLAG_NO_CREATE finds nothing for another request code");
        android.app.AlarmManager am = new android.app.AlarmManager();
        android.app.PendingIntent p2 = android.app.PendingIntent.getBroadcast(app, 2, new Intent("ALARM2"), 0);
        am.set(android.app.AlarmManager.ELAPSED_REALTIME, SystemClock.elapsedRealtime() + 150, p1);
        am.set(android.app.AlarmManager.ELAPSED_REALTIME, SystemClock.elapsedRealtime() + 150, p2);
        am.cancel(android.app.PendingIntent.getBroadcast(app, 2, new Intent("ALARM2"), android.app.PendingIntent.FLAG_NO_CREATE));
        sleep(400);
        check(log.contains("bcast ALARM b"), "alarm fired with the updated extras");
        check(!log.contains("bcast ALARM2 null"), "alarm cancelled through an equal PendingIntent did not fire");
        p1.cancel();
        check(android.app.PendingIntent.getBroadcast(app, 1, ai, android.app.PendingIntent.FLAG_NO_CREATE) == null, "cancelled PendingIntent is gone");
        boolean threw = false; try { p1.send(); } catch (android.app.PendingIntent.CanceledException ex) { threw = true; }
        check(threw, "sending a cancelled PendingIntent throws");
        log.clear();

        // --- ordered broadcasts: results flow, abort stops the rest, goAsync holds the line, result receiver last
        BroadcastReceiver o1 = new BroadcastReceiver() { public void onReceive(Context c, Intent i) { log.add("o1 " + getResultCode() + " " + isOrderedBroadcast()); setResultCode(getResultCode() + 1);
            final PendingResult pr = goAsync(); new Thread(() -> { sleep(100); pr.setResultData("from-o1"); pr.finish(); }).start(); } };
        BroadcastReceiver o2 = new BroadcastReceiver() { public void onReceive(Context c, Intent i) { log.add("o2 " + getResultCode() + " " + getResultData()); setResultCode(getResultCode() + 1); abortBroadcast(); } };
        BroadcastReceiver o3 = new BroadcastReceiver() { public void onReceive(Context c, Intent i) { log.add("o3"); } };
        for (BroadcastReceiver br : new BroadcastReceiver[] { o1, o2, o3 }) husk.Broadcasts.register(br, new IntentFilter("ORDERED"));
        husk.Broadcasts.sendOrdered(null, new Intent("ORDERED"), new BroadcastReceiver() { public void onReceive(Context c, Intent i) { log.add("final " + getResultCode() + " " + getResultData()); } }, null, 10, null, null);
        waitFor(() -> log.stream().anyMatch(s -> s.startsWith("final")), 2000);
        check(log.equals(java.util.Arrays.asList("o1 10 true", "o2 11 from-o1", "final 12 from-o1")), "ordered broadcast: " + log);
        for (BroadcastReceiver br : new BroadcastReceiver[] { o1, o2, o3 }) husk.Broadcasts.unregister(br);
        log.clear();

        // --- IdleHandler
        final AtomicInteger idle = new AtomicInteger();
        h.post(() -> Looper.myQueue().addIdleHandler(() -> { idle.incrementAndGet(); return false; }));
        sleep(200);
        check(idle.get() == 1, "IdleHandler runs once and is dropped (ran " + idle.get() + ")");
        {   // HandlerThread: Android's semantics (an unstarted one must not hang getLooper/quit)
            android.os.HandlerThread ht = new android.os.HandlerThread("t");
            check(ht.getLooper() == null && !ht.quit(), "unstarted HandlerThread: getLooper null, quit false, no hang");
            ht.start();
            check(ht.getLooper() != null && ht.getThreadHandler() != null && ht.getThreadHandler() == ht.getThreadHandler(), "started HandlerThread gives its looper and one handler");
            check(ht.quitSafely(), "HandlerThread quits");
            try { ht.join(2000); } catch (InterruptedException ie) {}
            check(!ht.isAlive(), "HandlerThread ended after quit");
        }
        {   // Message pool: copies, in-use tracking, no object handed out twice
            Message o = Message.obtain(h, 5, 6, 7, "x");
            o.getData().putString("k", "v");
            Message c = Message.obtain(o);
            check(c != null && c != o && c.what == 5 && c.arg1 == 6 && c.arg2 == 7 && "x".equals(c.obj) && c.getTarget() == h
                  && "v".equals(c.getData().getString("k")) && c.getData() != o.getData(), "Message.obtain(Message) copies");
            o.recycle(); o.recycle();
            Message a1 = Message.obtain(), a2 = Message.obtain();
            check(a1 != a2, "a message recycled twice is pooled once");
            final AtomicInteger got = new AtomicInteger();
            Handler hh = new Handler(h.getLooper()) { public void handleMessage(Message m) { got.incrementAndGet(); } };
            Message once = hh.obtainMessage(1);
            hh.sendMessageDelayed(once, 100);
            boolean inUse = false;
            try { hh.sendMessage(once); } catch (IllegalStateException ise) { inUse = true; }
            check(inUse, "sending a message that is already queued throws, as on Android");
            sleep(300);
            check(got.get() == 1, "the queued message is delivered once");
        }
        {   // quitSafely delivers what is already due, drops later messages
            android.os.HandlerThread ht = new android.os.HandlerThread("q");
            ht.start();
            final List<String> q = Collections.synchronizedList(new ArrayList<>());
            Handler qh = new Handler(ht.getLooper());
            final Object gate = new Object();
            qh.post(() -> { synchronized (gate) { try { gate.wait(200); } catch (InterruptedException ie2) {} } q.add("first"); });
            qh.post(() -> q.add("due"));
            qh.postDelayed(() -> q.add("late"), 5000);
            sleep(50);
            ht.quitSafely();
            synchronized (gate) { gate.notifyAll(); }
            try { ht.join(2000); } catch (InterruptedException ie) {}
            check(q.equals(java.util.Arrays.asList("first", "due")) && !ht.isAlive(), "quitSafely: due messages delivered, later ones dropped " + q);
        }

        // --- DownloadManager over a local HTTP server
        com.sun.net.httpserver.HttpServer srv = com.sun.net.httpserver.HttpServer.create(new java.net.InetSocketAddress("127.0.0.1", 0), 0);
        final byte[] payload = new byte[200_000]; new Random(1).nextBytes(payload);
        srv.createContext("/redir", x -> { x.getResponseHeaders().add("Location", "/file.bin"); x.sendResponseHeaders(302, -1); x.close(); });
        srv.createContext("/file.bin", x -> { x.sendResponseHeaders(200, payload.length); x.getResponseBody().write(payload); x.close(); });
        srv.createContext("/missing", x -> { x.sendResponseHeaders(404, -1); x.close(); });
        srv.start();
        int port = srv.getAddress().getPort();
        final List<Long> done = Collections.synchronizedList(new ArrayList<>());
        BroadcastReceiver rcv = new BroadcastReceiver() { public void onReceive(Context c, Intent i) { done.add(i.getLongExtra(android.app.DownloadManager.EXTRA_DOWNLOAD_ID, -1)); } };
        husk.Broadcasts.register(rcv, new IntentFilter(android.app.DownloadManager.ACTION_DOWNLOAD_COMPLETE));
        android.app.DownloadManager dm = new android.app.DownloadManager(null);
        java.io.File dest = new java.io.File(System.getProperty("java.io.tmpdir"), "husk-dl-test.bin"); dest.delete();
        long id = dm.enqueue(new android.app.DownloadManager.Request(android.net.Uri.parse("http://127.0.0.1:" + port + "/redir"))
            .setDestinationUri(android.net.Uri.fromFile(dest)).setTitle("t"));
        long bad = dm.enqueue(new android.app.DownloadManager.Request(android.net.Uri.parse("http://127.0.0.1:" + port + "/missing")).setDestinationUri(android.net.Uri.fromFile(new java.io.File(dest + ".2"))));
        waitFor(() -> done.contains(id) && done.contains(bad), 5000);
        android.database.Cursor cur = dm.query(new android.app.DownloadManager.Query().setFilterById(id));
        check(cur.moveToFirst() && cur.getInt(cur.getColumnIndex(android.app.DownloadManager.COLUMN_STATUS)) == android.app.DownloadManager.STATUS_SUCCESSFUL
              && cur.getLong(cur.getColumnIndex(android.app.DownloadManager.COLUMN_TOTAL_SIZE_BYTES)) == payload.length, "download succeeded through a redirect");
        check(java.util.Arrays.equals(java.nio.file.Files.readAllBytes(dest.toPath()), payload), "downloaded bytes intact");
        android.database.Cursor cb = dm.query(new android.app.DownloadManager.Query().setFilterByStatus(android.app.DownloadManager.STATUS_FAILED));
        check(cb.moveToFirst() && cb.getLong(0) == bad && cb.getInt(cb.getColumnIndex(android.app.DownloadManager.COLUMN_REASON)) == 404, "404 reported as failure with reason");
        check(done.contains(id) && done.contains(bad), "ACTION_DOWNLOAD_COMPLETE broadcast for both");
        srv.stop(0);

        matrixAgainstOld();
        System.out.println(fails == 0 ? "ALL PASSED" : fails + " FAILED");
        System.exit(fails == 0 ? 0 : 1);
    }

    // ---- android.graphics.Matrix, allocation-free now: the same numbers as the version it replaced (copied here as the reference)
    static final class OldM {
        final float[] m = { 1, 0, 0, 0, 1, 0, 0, 0, 1 };
        static void mul(float[] out, float[] a, float[] b) {
            float[] r = new float[9];
            for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) r[3 * i + j] = a[3 * i] * b[j] + a[3 * i + 1] * b[3 + j] + a[3 * i + 2] * b[6 + j];
            System.arraycopy(r, 0, out, 0, 9);
        }
        static float[] t(float dx, float dy) { return new float[] { 1, 0, dx, 0, 1, dy, 0, 0, 1 }; }
        static float[] s(float sx, float sy, float px, float py) { return new float[] { sx, 0, px - sx * px, 0, sy, py - sy * py, 0, 0, 1 }; }
        static float[] r(float deg, float px, float py) { double a = Math.toRadians(deg); float c = (float) Math.cos(a), sn = (float) Math.sin(a); return new float[] { c, -sn, px - c * px + sn * py, sn, c, py - sn * px - c * py, 0, 0, 1 }; }
        static float[] k(float kx, float ky, float px, float py) { return new float[] { 1, kx, -kx * py, ky, 1, -ky * px, 0, 0, 1 }; }
    }
    static void matrixAgainstOld() {
        java.util.Random rnd = new java.util.Random(7);
        double worst = 0; int mapBad = 0, invBad = 0;
        for (int trial = 0; trial < 3000; trial++) {
            android.graphics.Matrix n = new android.graphics.Matrix(); OldM o = new OldM();
            android.graphics.Matrix other = new android.graphics.Matrix(); other.setValues(new float[] { 1.1f, 0.2f, 3, -0.1f, 0.9f, -4, 0, 0, 1 });
            for (int step = 0; step < 6; step++) {
                float a = (rnd.nextFloat() - 0.5f) * 40, b = (rnd.nextFloat() - 0.5f) * 40, px = rnd.nextFloat() * 100, py = rnd.nextFloat() * 100;
                float sx = 0.2f + rnd.nextFloat() * 2, sy = 0.2f + rnd.nextFloat() * 2, deg = rnd.nextFloat() * 360, kx = (rnd.nextFloat() - 0.5f), ky = (rnd.nextFloat() - 0.5f);
                switch (rnd.nextInt(13)) {
                case 0: n.preTranslate(a, b); OldM.mul(o.m, o.m, OldM.t(a, b)); break;
                case 1: n.postTranslate(a, b); OldM.mul(o.m, OldM.t(a, b), o.m); break;
                case 2: n.preScale(sx, sy, px, py); OldM.mul(o.m, o.m, OldM.s(sx, sy, px, py)); break;
                case 3: n.postScale(sx, sy, px, py); OldM.mul(o.m, OldM.s(sx, sy, px, py), o.m); break;
                case 4: n.preRotate(deg, px, py); OldM.mul(o.m, o.m, OldM.r(deg, px, py)); break;
                case 5: n.postRotate(deg, px, py); OldM.mul(o.m, OldM.r(deg, px, py), o.m); break;
                case 6: n.preSkew(kx, ky, px, py); OldM.mul(o.m, o.m, OldM.k(kx, ky, px, py)); break;
                case 7: n.postSkew(kx, ky, px, py); OldM.mul(o.m, OldM.k(kx, ky, px, py), o.m); break;
                case 8: n.preConcat(other); OldM.mul(o.m, o.m, other.huskAffine().length == 6 ? vals(other) : null); break;
                case 9: n.postConcat(other); OldM.mul(o.m, vals(other), o.m); break;
                case 10: n.setRotate(deg, px, py); System.arraycopy(OldM.r(deg, px, py), 0, o.m, 0, 9); break;
                case 11: n.setScale(sx, sy, px, py); System.arraycopy(OldM.s(sx, sy, px, py), 0, o.m, 0, 9); break;
                default: n.setTranslate(a, b); System.arraycopy(OldM.t(a, b), 0, o.m, 0, 9); break;
                }
            }
            float[] v = vals(n);
            for (int i = 0; i < 9; i++) { double d = Math.abs(v[i] - o.m[i]) / Math.max(1, Math.abs(o.m[i])); if (d > worst) worst = d; }
            android.graphics.RectF r = new android.graphics.RectF(1, 2, 30, 40), rr = new android.graphics.RectF();
            n.mapRect(rr, r);
            float[] p = { 1, 2, 30, 2, 30, 40, 1, 40 }; n.mapPoints(p);
            float l = Math.min(Math.min(p[0], p[2]), Math.min(p[4], p[6])), rt = Math.max(Math.max(p[1], p[3]), Math.max(p[5], p[7]));
            if (rr.left != l || rr.bottom != rt) mapBad++;
            android.graphics.Matrix inv = new android.graphics.Matrix();
            if (n.invert(inv)) { android.graphics.Matrix id = new android.graphics.Matrix(); id.setConcat(n, inv); float[] q = vals(id);
                if (Math.abs(q[0] - 1) > 1e-3 || Math.abs(q[4] - 1) > 1e-3 || Math.abs(q[1]) > 1e-3 || Math.abs(q[2]) > 1e-2) invBad++; }
        }
        check(worst < 1e-5, "Matrix pre/post/set/concat match the old allocating version (worst relative difference " + worst + ")");
        check(mapBad == 0, "Matrix.mapRect without a temporary array gives what mapPoints gives");
        check(invBad == 0, "Matrix.invert: M x M^-1 = I");
    }
    static float[] vals(android.graphics.Matrix m) { float[] v = new float[9]; m.getValues(v); return v; }
}
