package husk;

import android.content.*;
import android.os.Handler;
import android.os.Looper;
import java.util.ArrayList;

/** Broadcasts within the app: to receivers registered at run time and those in the manifest; the system's own few (battery) answered. */
public final class Broadcasts {
    private static final ArrayList<Object[]> sReceivers = new ArrayList<>();
    private Broadcasts() {}
    public static Intent register(BroadcastReceiver r, IntentFilter f) {
        synchronized (sReceivers) { sReceivers.add(new Object[] { r, f }); }
        if (f != null && f.hasAction(Intent.ACTION_BATTERY_CHANGED)) return android.os.BatteryManager.huskStickyIntent();
        if (f != null && f.hasAction(android.net.ConnectivityManager.CONNECTIVITY_ACTION)) {
            Intent i = new Intent(android.net.ConnectivityManager.CONNECTIVITY_ACTION);
            i.putExtra(android.net.ConnectivityManager.EXTRA_NETWORK_INFO, new android.net.NetworkInfo());
            i.putExtra(android.net.ConnectivityManager.EXTRA_NO_CONNECTIVITY, false);
            return i;
        }
        return null;
    }
    public static void unregister(BroadcastReceiver r) { synchronized (sReceivers) { for (int i = sReceivers.size() - 1; i >= 0; i--) if (sReceivers.get(i)[0] == r) sReceivers.remove(i); } }
    public static void send(Context from, Intent i) { send(from, i, false); }
    /** system: a broadcast Husk makes up as the system would (boot completed at every start, where a phone sends it once after
     *  boot, in the background): a receiver throwing on it is logged rather than ending the app the user opened (Gmail's
     *  TimeZoneDataBaseUpgradeReceiver) */
    /** What an ordered broadcast carries between its receivers and hands to the result receiver at the end. */
    public static final class Result { public int code; public String data; public android.os.Bundle extras; public boolean abort, ordered; }

    /** The receivers an intent reaches: those registered at run time whose filters take it, then the manifest's. */
    private static ArrayList<BroadcastReceiver> targets(Intent i) {
        ArrayList<BroadcastReceiver> targets = new ArrayList<>();
        synchronized (sReceivers) { for (Object[] e : sReceivers) if (e[1] != null && i.getAction() != null && ((IntentFilter) e[1]).hasAction(i.getAction())) targets.add((BroadcastReceiver) e[0]); }
        for (Manifest.Component c : Manifest.receivers) {
            if (!c.enabled) continue;
            boolean match = i.getComponent() != null && c.name.equals(i.getComponent().getClassName());
            if (i.getComponent() == null && i.getAction() != null) for (Manifest.Filter f : c.filters) if (f.actions.contains(i.getAction())) match = true;
            if (!match) continue;
            try { targets.add((BroadcastReceiver) Class.forName(c.name, true, AppRunner.classLoader()).newInstance()); } catch (Throwable t) { android.util.Log.w("Husk", "receiver " + c.name + ": " + t); }
        }
        return targets;
    }
    private static Context ctx(Context from) { return AppRunner.application() != null ? AppRunner.application() : from; }

    public static void send(Context from, Intent i, boolean system) {
        final Context ctx = ctx(from);
        Handler h = new Handler(Looper.getMainLooper());
        for (BroadcastReceiver r : targets(i)) h.post(() -> {
            BroadcastReceiver.PendingResult p = new BroadcastReceiver.PendingResult();
            r.huskBegin(p, false);
            try {
                if (!system) { r.onReceive(ctx, i); return; }
                try { r.onReceive(ctx, i); } catch (RuntimeException e) { android.util.Log.w("Husk", "receiver " + r.getClass().getName() + " threw on " + i.getAction(), e); }
            } finally { r.huskEnd(); }
        });
    }

    /** sendOrderedBroadcast: one receiver at a time on the main thread, each seeing the result the one before left (and able
     *  to abort the rest); a receiver that called goAsync holds the line until it finishes. The result receiver, if any, is
     *  always called last, on its handler, with the final result -- as on Android. */
    public static void sendOrdered(Context from, final Intent i, final BroadcastReceiver resultReceiver, Handler handler, int code, String data, android.os.Bundle extras) {
        final Context ctx = ctx(from);
        final ArrayList<BroadcastReceiver> list = targets(i);
        final Result res = new Result();
        res.code = code; res.data = data; res.extras = extras; res.ordered = true;
        final Handler main = new Handler(Looper.getMainLooper());
        final Handler last = handler != null ? handler : main;
        final int[] at = { 0 };
        final Runnable[] step = new Runnable[1];
        step[0] = () -> {
            if (res.abort || at[0] >= list.size()) {
                if (resultReceiver == null) return;
                last.post(() -> {
                    BroadcastReceiver.PendingResult p = new BroadcastReceiver.PendingResult();
                    p.huskResult = res;
                    resultReceiver.huskBegin(p, true);
                    try { resultReceiver.onReceive(ctx, i); } finally { resultReceiver.huskEnd(); }
                });
                return;
            }
            BroadcastReceiver r = list.get(at[0]++);
            BroadcastReceiver.PendingResult p = new BroadcastReceiver.PendingResult();
            p.huskResult = res;
            p.huskOnFinish = () -> main.post(step[0]);
            r.huskBegin(p, true);
            boolean async = false;
            try { r.onReceive(ctx, i); }
            catch (RuntimeException e) { android.util.Log.e("Husk", "receiver " + r.getClass().getName() + " threw on " + i.getAction(), e); }
            finally { async = r.huskEnd(); }
            if (!async) p.finish();
        };
        main.post(step[0]);
    }
}
