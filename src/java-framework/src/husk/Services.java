package husk;

import android.app.Service;
import android.content.*;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import java.util.ArrayList;
import java.util.HashMap;

/** The app's own services (started and bound in this process, as on Android) and the system services Husk answers for.
 *
 *  A service lives as Android's does: it is created on the first start, bind or job that needs it; each start gets the next
 *  start id; it is bound once (onBind) and every later client is given the same binder; when its last client unbinds it hears
 *  onUnbind (and onRebind on the next bind if it asked for that); and it is destroyed once it is neither started nor bound nor
 *  running a job. Every callback runs on the main thread. */
public final class Services {
    private static final class Record {
        final Manifest.Component comp; final Service service;
        boolean started, bound, rebind; int lastStartId, jobs; IBinder binder; Intent bindIntent;
        final ArrayList<ServiceConnection> conns = new ArrayList<>();
        Record(Manifest.Component c, Service s) { comp = c; service = s; }
        ComponentName name() { return new ComponentName(Native.packageName(), comp.name); }
    }
    private static final HashMap<String, Record> sRunning = new HashMap<>();
    private static final HashMap<ServiceConnection, Record> sBound = new HashMap<>();
    private static Handler sMain;
    private Services() {}

    private static Handler main() { if (sMain == null) sMain = new Handler(Looper.getMainLooper()); return sMain; }
    private static void onMain(Runnable r) { if (Looper.myLooper() == Looper.getMainLooper()) r.run(); else main().post(r); }

    private static Manifest.Component find(Intent i) {
        if (i == null) return null;
        ComponentName cn = i.getComponent();
        if (cn != null && cn.getClassName() != null && cn.getClassName().startsWith(".")) {
            /* a class named relative to the package, as manifests write them */
            i = new Intent(i).setComponent(new ComponentName(cn.getPackageName(), Native.packageName() + cn.getClassName()));
        }
        /* another app's service (its package named) is not in this process: Manifest.match answers nothing for it */
        java.util.List<Manifest.Component> m = Manifest.match(Manifest.services, i);
        return m.isEmpty() ? null : m.get(0);
    }
    private static Record record(Manifest.Component c) throws Exception {
        synchronized (sRunning) {
            Record r = sRunning.get(c.name);
            if (r != null) return r;
            Service s = (Service) Class.forName(c.name, true, AppRunner.classLoader()).newInstance();
            s.huskAttach(AppRunner.application() != null ? AppRunner.application() : ContextImpl.app());
            r = new Record(c, s);
            sRunning.put(c.name, r);
            s.onCreate();
            return r;
        }
    }
    private static Record recordOf(Service s) {
        synchronized (sRunning) { for (Record r : sRunning.values()) if (r.service == s) return r; }
        return null;
    }
    /** Destroyed when nothing keeps it: not started, no clients, no job running in it. */
    private static void maybeDestroy(Record r) {
        if (r.started || !r.conns.isEmpty() || r.jobs > 0) return;
        synchronized (sRunning) { if (sRunning.get(r.comp.name) != r) return; sRunning.remove(r.comp.name); }
        try { r.service.onDestroy(); } catch (Throwable t) { android.util.Log.e("Husk", "service " + r.comp.name + " onDestroy failed", t); }
    }

    public static ComponentName start(Context from, Intent i) {
        final Manifest.Component c = find(i);
        if (c == null) return null;
        if (!c.enabled) return null;
        onMain(() -> {
            try {
                Record r = record(c);
                r.started = true;
                int id = ++r.lastStartId;
                r.service.onStartCommand(i, 0, id);
            } catch (Throwable t) { android.util.Log.e("Husk", "service " + c.name + " failed", t); }
        });
        return new ComponentName(Native.packageName(), c.name);
    }
    public static boolean stop(Intent i) {
        Manifest.Component c = find(i);
        if (c == null) return false;
        final Record r;
        synchronized (sRunning) { r = sRunning.get(c.name); }
        if (r == null || !r.started) return false;
        onMain(() -> { r.started = false; maybeDestroy(r); });
        return true;
    }
    /** stopSelf(): stops whatever start it was. */
    public static void stopSelf(Service s) { stopSelf(s, -1); }
    /** stopSelf(id) / stopSelfResult(id): only if id is the most recent start, so a start that came in meanwhile is not lost. */
    public static boolean stopSelf(Service s, int startId) {
        final Record r = recordOf(s);
        if (r == null) return false;
        if (startId >= 0 && startId != r.lastStartId) return false;
        onMain(() -> { r.started = false; maybeDestroy(r); });
        return true;
    }

    public static boolean bind(Context from, Intent i, ServiceConnection conn) { return bind(from, i, conn, Context.BIND_AUTO_CREATE); }
    public static boolean bind(Context from, Intent i, ServiceConnection conn, int flags) {
        if (conn == null) return false;
        final IBinder play = PlayStore.bind(i);
        if (play != null) {
            final ComponentName cn = new ComponentName(GooglePackages.VENDING, i.getAction());
            main().post(() -> conn.onServiceConnected(cn, play));
            return true;
        }
        final Manifest.Component c = find(i);
        if (c == null || !c.enabled) return false;
        boolean exists;
        synchronized (sRunning) { exists = sRunning.containsKey(c.name); }
        if (!exists && (flags & Context.BIND_AUTO_CREATE) == 0) return true;      /* bound once something else creates it, as on Android */
        main().post(() -> {
            try {
                Record r = record(c);
                Record was = sBound.get(conn);
                if (was == r) return;                                                 /* the same connection again: nothing new */
                if (!r.bound) { r.binder = r.service.onBind(i); r.bound = true; r.bindIntent = i; }
                else if (r.conns.isEmpty() && r.rebind) { r.rebind = false; r.service.onRebind(i); }
                r.conns.add(conn);
                sBound.put(conn, r);
                ComponentName cn = r.name();
                if (r.binder != null) conn.onServiceConnected(cn, r.binder); else conn.onNullBinding(cn);
            } catch (Throwable t) { android.util.Log.e("Husk", "binding " + c.name + " failed", t); }
        });
        return true;
    }
    public static void unbind(ServiceConnection conn) {
        if (conn == null) return;
        onMain(() -> {
            Record r = sBound.remove(conn);
            if (r == null) return;
            r.conns.remove(conn);
            if (!r.conns.isEmpty()) return;
            try { r.rebind = r.service.onUnbind(r.bindIntent != null ? r.bindIntent : new Intent().setComponent(r.name())); }
            catch (Throwable t) { android.util.Log.e("Husk", "service " + r.comp.name + " onUnbind failed", t); }
            if (!r.started) { r.bound = false; r.binder = null; }                     /* a service that goes away forgets its binder */
            maybeDestroy(r);
        });
    }

    /** The service a job runs in, made (or found) and held for the job: release with jobDone. */
    public static Service jobService(ComponentName cn) throws Exception {
        Manifest.Component c = null;
        for (Manifest.Component s : Manifest.services) if (s.name.equals(cn.getClassName())) { c = s; break; }
        if (c == null) { c = new Manifest.Component(); c.name = cn.getClassName(); c.kind = "service"; c.enabled = true; }
        Record r = record(c);
        r.jobs++;
        return r.service;
    }
    public static void jobDone(Service s) {
        final Record r = recordOf(s);
        if (r == null) return;
        onMain(() -> { if (r.jobs > 0) r.jobs--; maybeDestroy(r); });
    }
    /** Kept for callers of the old entry point: the job goes through the scheduler like any other. */
    public static void runJob(android.app.job.JobInfo j) { if (j != null) new android.app.job.JobScheduler.Impl().schedule(j); }

    /** ActivityManager.getRunningServices: this app's live services, the only ones an app sees on current Android anyway. */
    public static java.util.List<android.app.ActivityManager.RunningServiceInfo> running(int max) {
        java.util.ArrayList<android.app.ActivityManager.RunningServiceInfo> out = new java.util.ArrayList<>();
        synchronized (sRunning) {
            for (Record r : sRunning.values()) {
                if (out.size() >= max) break;
                android.app.ActivityManager.RunningServiceInfo i = new android.app.ActivityManager.RunningServiceInfo();
                i.service = r.name(); i.started = r.started; i.clientCount = r.conns.size();
                i.flags = r.started ? android.app.ActivityManager.RunningServiceInfo.FLAG_STARTED : 0;
                i.pid = android.os.Process.myPid(); i.uid = android.os.Process.myUid(); i.process = Native.packageName(); i.clientPackage = Native.packageName();
                out.add(i);
            }
        }
        return out;
    }

    /** A system service by name, or null for those Husk has nothing for. */
    public static Object system(String name, Context c) {
        switch (name) {
        case Context.AUDIO_SERVICE: return new android.media.AudioManager();
        case Context.MEDIA_SESSION_SERVICE: return new android.media.session.MediaSessionManager(c);
        case Context.VIBRATOR_SERVICE: return new android.os.Vibrator();
        case Context.VIBRATOR_MANAGER_SERVICE: return new android.os.VibratorManager();
        case Context.CLIPBOARD_SERVICE: return new ClipboardManager();
        case Context.INPUT_METHOD_SERVICE: return new android.view.inputmethod.InputMethodManager();
        case Context.SENSOR_SERVICE: return new android.hardware.SensorManager();
        case Context.POWER_SERVICE: return new android.os.PowerManager();
        case Context.ACTIVITY_SERVICE: return new android.app.ActivityManager();
        case Context.CONNECTIVITY_SERVICE: return new android.net.ConnectivityManager();
        case Context.NOTIFICATION_SERVICE: return new android.app.NotificationManager();
        case Context.ALARM_SERVICE: return new android.app.AlarmManager();
        case Context.ACCESSIBILITY_SERVICE: return new android.view.accessibility.AccessibilityManager();
        case Context.UI_MODE_SERVICE: return new android.app.UiModeManager();
        case Context.DISPLAY_SERVICE: return new android.hardware.display.DisplayManager();
        case Context.KEYGUARD_SERVICE: return new android.app.KeyguardManager();
        case Context.USER_SERVICE: return new android.os.UserManager();
        case Context.BATTERY_SERVICE: return new android.os.BatteryManager();
        case Context.STORAGE_SERVICE: return new android.os.storage.StorageManager();
        case Context.TELEPHONY_SERVICE: return new android.telephony.TelephonyManager();
        case Context.JOB_SCHEDULER_SERVICE: return new android.app.job.JobScheduler.Impl();
        case Context.APP_OPS_SERVICE: return new android.app.AppOpsManager();
        case Context.INPUT_SERVICE: return new android.hardware.input.InputManager();
        case Context.WIFI_SERVICE: return new android.net.wifi.WifiManager(c, null);
        case Context.LOCATION_SERVICE: return new android.location.LocationManager(c, null);
        case Context.DOWNLOAD_SERVICE: return new android.app.DownloadManager(c);
        case Context.CAPTIONING_SERVICE: return new android.view.accessibility.CaptioningManager(c);
        case Context.TEXT_CLASSIFICATION_SERVICE: return new android.view.textclassifier.TextClassificationManager(c);
        case Context.LOCALE_SERVICE: return new android.app.LocaleManager(c);
        default: return null;
        }
    }
}
