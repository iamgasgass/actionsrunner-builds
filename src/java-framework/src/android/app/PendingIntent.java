package android.app;

import android.content.Context;
import android.content.Intent;

/** A pending intent, held in this process; sending it starts it as the app would. */
public final class PendingIntent implements android.os.Parcelable {
    public static final int FLAG_ONE_SHOT = 0x40000000, FLAG_NO_CREATE = 0x20000000, FLAG_CANCEL_CURRENT = 0x10000000, FLAG_UPDATE_CURRENT = 0x08000000,
        FLAG_IMMUTABLE = 0x04000000, FLAG_MUTABLE = 0x02000000, FLAG_ALLOW_UNSAFE_IMPLICIT_INTENT = 0x01000000;
    public static class CanceledException extends android.util.AndroidException { public CanceledException() {} public CanceledException(String s) { super(s); } public CanceledException(Exception e) { super(e); } }
    public interface OnFinished { void onSendFinished(PendingIntent p, Intent i, int resultCode, String resultData, android.os.Bundle resultExtras); }
    private final Context mContext; private Intent mIntent; private final int mKind, mRequest, mFlags;   /* kind: 0 activity, 1 broadcast, 2 service */
    private volatile boolean mCanceled;
    private PendingIntent(Context c, Intent i, int kind, int req, int flags) { mContext = c; mIntent = i; mKind = kind; mRequest = req; mFlags = flags; }

    /* Android's token table: one PendingIntent per (kind, request code, intent as filterEquals sees it), so asking again gives
     * the same object -- which is what lets AlarmManager.cancel, NotificationManager and FLAG_NO_CREATE checks find it */
    private static final class Key {
        final int kind, req; final Intent intent;
        Key(int kind, int req, Intent i) { this.kind = kind; this.req = req; intent = i; }
        @Override public boolean equals(Object o) { if (!(o instanceof Key)) return false; Key k = (Key) o; return k.kind == kind && k.req == req && (intent == null ? k.intent == null : intent.filterEquals(k.intent)); }
        @Override public int hashCode() { return kind * 31 * 31 + req * 31 + (intent == null ? 0 : intent.filterHashCode()); }
    }
    private static final java.util.HashMap<Key, PendingIntent> sTokens = new java.util.HashMap<>();
    private static PendingIntent obtain(Context c, Intent i, int kind, int req, int flags) {
        if (i == null) throw new NullPointerException("intent");
        Key k = new Key(kind, req, i);
        synchronized (sTokens) {
            PendingIntent old = sTokens.get(k);
            if ((flags & FLAG_NO_CREATE) != 0) return old;
            if (old != null && (flags & FLAG_CANCEL_CURRENT) != 0) { old.mCanceled = true; sTokens.remove(k); old = null; }
            if (old != null) {
                if ((flags & FLAG_UPDATE_CURRENT) != 0) old.mIntent = new Intent(old.mIntent).replaceExtras(i);
                return old;
            }
            PendingIntent p = new PendingIntent(c, new Intent(i), kind, req, flags);
            sTokens.put(k, p);
            return p;
        }
    }
    public static PendingIntent getActivity(Context c, int req, Intent i, int flags) { return obtain(c, i, 0, req, flags); }
    public static PendingIntent getActivity(Context c, int req, Intent i, int flags, android.os.Bundle o) { return obtain(c, i, 0, req, flags); }
    public static PendingIntent getActivities(Context c, int req, Intent[] i, int flags) { return obtain(c, i[i.length - 1], 0, req, flags); }
    public static PendingIntent getBroadcast(Context c, int req, Intent i, int flags) { return obtain(c, i, 1, req, flags); }
    public static PendingIntent getService(Context c, int req, Intent i, int flags) { return obtain(c, i, 2, req, flags); }
    public static PendingIntent getForegroundService(Context c, int req, Intent i, int flags) { return obtain(c, i, 2, req, flags); }
    public void send() throws CanceledException { send(mContext, 0, null); }
    public void send(int code) throws CanceledException { send(mContext, code, null); }
    public void send(Context c, int code, Intent fill) throws CanceledException {
        if (mCanceled) throw new CanceledException("PendingIntent was canceled");
        Intent i = fill != null ? new Intent(mIntent).putExtras(fill) : new Intent(mIntent);
        Context ctx = mContext != null ? mContext : c != null ? c : husk.ContextImpl.app();
        if ((mFlags & FLAG_ONE_SHOT) != 0) cancel();
        if (mKind == 0) ctx.startActivity(i); else if (mKind == 1) ctx.sendBroadcast(i); else ctx.startService(i);
    }
    public void send(int code, OnFinished f, android.os.Handler h) throws CanceledException { send(mContext, code, null, f, h); }
    public void send(Context c, int code, Intent i, OnFinished f, android.os.Handler h) throws CanceledException {
        send(c, code, i);
        if (f != null) { final Intent sent = i != null ? new Intent(mIntent).putExtras(i) : mIntent; Runnable r = () -> f.onSendFinished(this, sent, code, null, null); if (h != null) h.post(r); else r.run(); }
    }
    public void cancel() {
        mCanceled = true;
        synchronized (sTokens) { Key k = new Key(mKind, mRequest, mIntent); if (sTokens.get(k) == this) sTokens.remove(k); }
        android.app.AlarmManager.huskCanceled(this);
    }
    boolean huskCanceled() { return mCanceled; }
    public String getCreatorPackage() { return husk.Native.packageName(); }
    public String getTargetPackage() { return getCreatorPackage(); }
    public int getCreatorUid() { return android.os.Process.myUid(); }
    public android.os.UserHandle getCreatorUserHandle() { return android.os.UserHandle.getUserHandleForUid(0); }
    public android.content.IntentSender getIntentSender() { return new android.content.IntentSender(); }
    public boolean isImmutable() { return (mFlags & FLAG_MUTABLE) == 0; } public boolean isActivity() { return mKind == 0; } public boolean isBroadcast() { return mKind == 1; } public boolean isService() { return mKind == 2; }
    public int describeContents() { return 0; }
    // ---- generated by tools/compat/fillmembers.py: the platform's members this class does not write (signatures only)
    public static final long BLOCK_MUTABLE_IMPLICIT_PENDING_INTENT = 236704164L;
    public static android.os.Parcelable.Creator CREATOR = husk.StubCreator.of(PendingIntent.class);
    public static final int FLAG_MUTABLE_UNAUDITED = 33554432;
    public static final long PENDING_INTENT_OPTIONS_CHECK = 320664730L;
    public static android.app.PendingIntent getActivities(android.content.Context p0, int p1, android.content.Intent[] p2, int p3, android.os.Bundle p4) { return null; }
    public static android.app.PendingIntent getActivitiesAsUser(android.content.Context p0, int p1, android.content.Intent[] p2, int p3, android.os.Bundle p4, android.os.UserHandle p5) { return null; }
    public static android.app.PendingIntent getActivityAsUser(android.content.Context p0, int p1, android.content.Intent p2, int p3, android.os.Bundle p4, android.os.UserHandle p5) { return null; }
    public static android.app.PendingIntent getBroadcastAsUser(android.content.Context p0, int p1, android.content.Intent p2, int p3, android.os.UserHandle p4) { return null; }
    public static boolean isNewMutableDisallowedImplicitPendingIntent(int p0, android.content.Intent p1, boolean p2) { return false; }
    public static android.app.PendingIntent readPendingIntentOrNullFromParcel(android.os.Parcel p0) { return null; }
    public static void setOnMarshaledListener(android.app.PendingIntent.OnMarshaledListener p0) {}
    public static void writePendingIntentOrNullToParcel(android.app.PendingIntent p0, android.os.Parcel p1) {}
    public boolean addCancelListener(java.util.concurrent.Executor p0, android.app.PendingIntent.CancelListener p1) { return false; }
    public void dumpDebug(android.util.proto.ProtoOutputStream p0, long p1) {}
    public android.content.Intent getIntent() { return new Intent(mIntent); }
    public java.lang.String getTag(java.lang.String p0) { return null; }
    public android.os.IBinder getWhitelistToken() { return null; }
    public boolean intentFilterEquals(android.app.PendingIntent p0) { return false; }
    public boolean isForegroundService() { return false; }
    public boolean isTargetedToPackage() { return false; }
    public java.util.List queryIntentComponents(int p0) { return new java.util.ArrayList(); }
    public void registerCancelListener(android.app.PendingIntent.CancelListener p0) {}
    public void removeCancelListener(android.app.PendingIntent.CancelListener p0) {}
    public void send(android.content.Context p0, int p1, android.content.Intent p2, android.app.PendingIntent.OnFinished p3, android.os.Handler p4, java.lang.String p5) {}
    public void send(android.content.Context p0, int p1, android.content.Intent p2, android.app.PendingIntent.OnFinished p3, android.os.Handler p4, java.lang.String p5, android.os.Bundle p6) {}
    public void send(android.os.Bundle p0) {}
    public int sendAndReturnResult(android.content.Context p0, int p1, android.content.Intent p2, android.app.PendingIntent.OnFinished p3, android.os.Handler p4, java.lang.String p5, android.os.Bundle p6) { return 0; }
    public void unregisterCancelListener(android.app.PendingIntent.CancelListener p0) {}
    // ---- end of generated members
    // ---- generated by tools/compat/genstubs.py: the platform's nested classes this class does not write
    public interface CancelListener {
        void onCanceled(android.app.PendingIntent p0);
    }
    public interface OnMarshaledListener {
        void onMarshaled(android.app.PendingIntent p0, android.os.Parcel p1, int p2);
    }
    // ---- end of generated nested classes
}
