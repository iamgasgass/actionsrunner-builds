package android.app.job;
/** A job as the app described it: everything the Builder was given is kept and given back, and Husk's scheduler
 *  (JobScheduler.Impl) honours the timing parts of it (minimum latency, deadline, period, back-off). */
public class JobInfo implements android.os.Parcelable {
    public static final int NETWORK_TYPE_NONE = 0, NETWORK_TYPE_ANY = 1, NETWORK_TYPE_UNMETERED = 2, NETWORK_TYPE_NOT_ROAMING = 3, NETWORK_TYPE_CELLULAR = 4, BACKOFF_POLICY_LINEAR = 0, BACKOFF_POLICY_EXPONENTIAL = 1, PRIORITY_DEFAULT = 300;
    public static final long DEFAULT_INITIAL_BACKOFF_MILLIS = 30000, MAX_BACKOFF_DELAY_MILLIS = 18000000;
    private final int mId; private final android.os.PersistableBundle mExtras; private final android.content.ComponentName mService;
    private final android.os.Bundle mTransientExtras; private final int mNetworkType; private final android.net.NetworkRequest mNetworkRequest;
    private final int mConstraintFlags; private final java.util.ArrayList<TriggerContentUri> mTriggerUris;
    private final long mTriggerUpdateDelay, mTriggerMaxDelay, mInterval, mFlex, mMinLatency, mDeadline, mInitialBackoff, mDownloadBytes, mUploadBytes, mChunkBytes;
    private final int mBackoffPolicy, mPriority, mFlags, mBias, mClipGrantFlags;
    private final boolean mPeriodic, mPersisted, mHasEarly, mHasLate;
    private final android.content.ClipData mClipData; private final java.util.HashSet<String> mDebugTags; private final String mTraceTag;
    JobInfo(Builder b) {
        mId = b.id; mService = b.service; mExtras = b.extras != null ? b.extras : new android.os.PersistableBundle();
        mTransientExtras = b.transientExtras != null ? b.transientExtras : new android.os.Bundle();
        mNetworkType = b.networkRequest != null && b.networkType == NETWORK_TYPE_NONE ? NETWORK_TYPE_ANY : b.networkType; mNetworkRequest = b.networkRequest;
        mConstraintFlags = b.constraintFlags; mTriggerUris = new java.util.ArrayList<>(b.triggerUris);
        mTriggerUpdateDelay = b.triggerUpdateDelay; mTriggerMaxDelay = b.triggerMaxDelay;
        mPeriodic = b.periodic; mInterval = b.interval; mFlex = b.flex;
        mMinLatency = b.minLatency; mDeadline = b.deadline; mHasEarly = b.hasEarly; mHasLate = b.hasLate;
        mInitialBackoff = b.initialBackoff; mBackoffPolicy = b.backoffPolicy; mPriority = b.priority; mFlags = b.flags; mBias = b.bias;
        mPersisted = b.persisted; mDownloadBytes = b.downloadBytes; mUploadBytes = b.uploadBytes; mChunkBytes = b.chunkBytes;
        mClipData = b.clipData; mClipGrantFlags = b.clipGrantFlags; mDebugTags = new java.util.HashSet<>(b.debugTags); mTraceTag = b.traceTag;
    }
    public int getId() { return mId; } public android.os.PersistableBundle getExtras() { return mExtras; } public android.content.ComponentName getService() { return mService; }
    public static long getMinPeriodMillis() { return 900000; } public static long getMinFlexMillis() { return 300000; }
    public int describeContents() { return 0; }
    public static final class Builder {
        private final int id; private final android.content.ComponentName service;
        private android.os.PersistableBundle extras = new android.os.PersistableBundle(); private android.os.Bundle transientExtras;
        private int networkType = NETWORK_TYPE_NONE; private android.net.NetworkRequest networkRequest; private int constraintFlags;
        private final java.util.ArrayList<TriggerContentUri> triggerUris = new java.util.ArrayList<>();
        private long triggerUpdateDelay = -1, triggerMaxDelay = -1, interval, flex, minLatency, deadline, initialBackoff = DEFAULT_INITIAL_BACKOFF_MILLIS;
        private long downloadBytes = NETWORK_BYTES_UNKNOWN, uploadBytes = NETWORK_BYTES_UNKNOWN, chunkBytes = NETWORK_BYTES_UNKNOWN;
        private int backoffPolicy = DEFAULT_BACKOFF_POLICY, priority = PRIORITY_DEFAULT, flags, bias, clipGrantFlags;
        private boolean periodic, persisted, hasEarly, hasLate;
        private android.content.ClipData clipData; private final java.util.HashSet<String> debugTags = new java.util.HashSet<>(); private String traceTag;
        public Builder(int id, android.content.ComponentName service) { this.id = id; this.service = service; }
        public Builder setExtras(android.os.PersistableBundle e) { extras = e; return this; }
        public Builder setTransientExtras(android.os.Bundle e) { transientExtras = e; return this; }
        public Builder setRequiredNetworkType(int t) { networkType = t; return this; }
        public Builder setRequiredNetwork(android.net.NetworkRequest r) { networkRequest = r; return this; }
        public Builder setRequiresCharging(boolean b) { return flag(CONSTRAINT_FLAG_CHARGING, b); }
        public Builder setRequiresDeviceIdle(boolean b) { return flag(CONSTRAINT_FLAG_DEVICE_IDLE, b); }
        public Builder setRequiresBatteryNotLow(boolean b) { return flag(CONSTRAINT_FLAG_BATTERY_NOT_LOW, b); }
        public Builder setRequiresStorageNotLow(boolean b) { return flag(CONSTRAINT_FLAG_STORAGE_NOT_LOW, b); }
        private Builder flag(int f, boolean on) { constraintFlags = on ? constraintFlags | f : constraintFlags & ~f; return this; }
        public Builder addTriggerContentUri(TriggerContentUri u) { if (u != null) triggerUris.add(u); return this; }
        public Builder setTriggerContentUpdateDelay(long d) { triggerUpdateDelay = d; return this; }
        public Builder setTriggerContentMaxDelay(long d) { triggerMaxDelay = d; return this; }
        public Builder setPeriodic(long i) { return setPeriodic(i, i); }
        public Builder setPeriodic(long i, long f) {
            long minP = getMinPeriodMillis(), minF = getMinFlexMillis();
            if (i < minP) i = minP;
            if (f < minF) f = minF;
            if (f > i) f = i;
            periodic = true; interval = i; flex = f; hasEarly = hasLate = true; return this;
        }
        public Builder setMinimumLatency(long l) { minLatency = Math.max(0, l); hasEarly = true; return this; }
        public Builder setOverrideDeadline(long d) { deadline = Math.max(0, d); hasLate = true; return this; }
        public Builder setBackoffCriteria(long b, int p) { initialBackoff = Math.max(MIN_BACKOFF_MILLIS, b); backoffPolicy = p; return this; }
        public Builder setImportantWhileForeground(boolean b) { flags = b ? flags | FLAG_IMPORTANT_WHILE_FOREGROUND : flags & ~FLAG_IMPORTANT_WHILE_FOREGROUND; return this; }
        public Builder setPrefetch(boolean b) { flags = b ? flags | FLAG_PREFETCH : flags & ~FLAG_PREFETCH; return this; }
        public Builder setPersisted(boolean b) { persisted = b; return this; }
        public Builder setExpedited(boolean b) { flags = b ? flags | FLAG_EXPEDITED : flags & ~FLAG_EXPEDITED; return this; }
        public Builder setEstimatedNetworkBytes(long d, long u) { downloadBytes = d; uploadBytes = u; return this; }
        public Builder setUserInitiated(boolean b) { flags = b ? flags | FLAG_USER_INITIATED : flags & ~FLAG_USER_INITIATED; return this; }
        public Builder setPriority(int p) { priority = p; return this; }
        public JobInfo build() { return new JobInfo(this); }
        public android.app.job.JobInfo.Builder addDebugTag(java.lang.String p0) { if (p0 != null) debugTags.add(p0); return this; }
        public android.app.job.JobInfo.Builder addDebugTags(java.util.Set p0) { if (p0 != null) debugTags.addAll(p0); return this; }
        public android.app.job.JobInfo build(boolean p0, boolean p1, boolean p2, boolean p3) { return build(); }
        public android.app.job.JobInfo.Builder removeDebugTag(java.lang.String p0) { debugTags.remove(p0); return this; }
        public android.app.job.JobInfo.Builder setBias(int p0) { bias = p0; return this; }
        public android.app.job.JobInfo.Builder setClipData(android.content.ClipData p0, int p1) { clipData = p0; clipGrantFlags = p1; return this; }
        public android.app.job.JobInfo.Builder setFlags(int p0) { flags = p0; return this; }
        public android.app.job.JobInfo.Builder setMinimumNetworkChunkBytes(long p0) { chunkBytes = p0; return this; }
        public android.app.job.JobInfo.Builder setTraceTag(java.lang.String p0) { traceTag = p0; return this; }
        public java.lang.String summarize() { return "JobInfo.Builder{id=" + id + ", service=" + service + "}"; }
    }
    // ---- platform API stubs (tools/compat/genstubs.py)
    public static final class TriggerContentUri implements android.os.Parcelable {
        public static final int FLAG_NOTIFY_FOR_DESCENDANTS = 1;
        private final android.net.Uri mUri; private final int mFlags;
        public TriggerContentUri(android.net.Uri uri, int flags) { mUri = uri; mFlags = flags; }
        public android.net.Uri getUri() { return mUri; }
        public int getFlags() { return mFlags; }
        public int describeContents() { return 0; }
        public void writeToParcel(android.os.Parcel p, int f) { p.writeParcelable(mUri, f); p.writeInt(mFlags); }
        public static final Creator<TriggerContentUri> CREATOR = new Creator<TriggerContentUri>() { public TriggerContentUri createFromParcel(android.os.Parcel p) { return new TriggerContentUri(p.readParcelable(null), p.readInt()); } public TriggerContentUri[] newArray(int n) { return new TriggerContentUri[n]; } };
    }
    public static final int BIAS_ADJ_ALWAYS_RUNNING = -80;
    public static final int BIAS_ADJ_OFTEN_RUNNING = -40;
    public static final int BIAS_BOUND_FOREGROUND_SERVICE = 30;
    public static final int BIAS_DEFAULT = 0;
    public static final int BIAS_FOREGROUND_SERVICE = 35;
    public static final int BIAS_SYNC_EXPEDITED = 10;
    public static final int BIAS_SYNC_INITIALIZATION = 20;
    public static final int BIAS_TOP_APP = 40;
    public static final int CONSTRAINT_FLAG_BATTERY_NOT_LOW = 2;
    public static final int CONSTRAINT_FLAG_CHARGING = 1;
    public static final int CONSTRAINT_FLAG_DEVICE_IDLE = 4;
    public static final int CONSTRAINT_FLAG_STORAGE_NOT_LOW = 8;
    public static final int DEFAULT_BACKOFF_POLICY = 1;
    public static final long DISALLOW_DEADLINES_FOR_PREFETCH_JOBS = 194532703L;
    public static final long ENFORCE_MINIMUM_TIME_WINDOWS = 311402873L;
    public static final int FLAG_EXEMPT_FROM_APP_STANDBY = 8;
    public static final int FLAG_EXPEDITED = 16;
    public static final int FLAG_IMPORTANT_WHILE_FOREGROUND = 2;
    public static final int FLAG_PREFETCH = 4;
    public static final int FLAG_USER_INITIATED = 32;
    public static final int FLAG_WILL_BE_FOREGROUND = 1;
    public static final int MAX_DEBUG_TAG_LENGTH = 127;
    public static final int MAX_NUM_DEBUG_TAGS = 32;
    public static final int MAX_TRACE_TAG_LENGTH = 127;
    public static final long MIN_BACKOFF_MILLIS = 10000L;
    public static final int NETWORK_BYTES_UNKNOWN = -1;
    public static final int NETWORK_TYPE_METERED = 4;
    public static final int PRIORITY_FOREGROUND_APP = 30;
    public static final int PRIORITY_FOREGROUND_SERVICE = 35;
    public static final int PRIORITY_HIGH = 400;
    public static final int PRIORITY_LOW = 200;
    public static final int PRIORITY_MAX = 500;
    public static final int PRIORITY_MIN = 100;
    public static final long REJECT_NEGATIVE_DELAYS_AND_DEADLINES = 323349338L;
    public static final long REJECT_NEGATIVE_NETWORK_ESTIMATES = 253665015L;
    public static final long THROW_ON_INVALID_PRIORITY_VALUE = 140852299L;
    public static java.lang.String getBiasString(int p0) { return String.valueOf(p0); }
    public static long getMinBackoffMillis() { return MIN_BACKOFF_MILLIS; }
    public static java.lang.String getPriorityString(int p0) { return String.valueOf(p0); }
    public static java.lang.String validateDebugTag(java.lang.String p0) { return p0 == null ? null : p0.trim(); }
    public static java.lang.String validateTraceTag(java.lang.String p0) { return p0 == null ? null : p0.trim(); }
    public void enforceValidity(boolean p0, boolean p1, boolean p2, boolean p3) {}
    public int getBackoffPolicy() { return mBackoffPolicy; }
    public int getBias() { return mBias; }
    public android.content.ClipData getClipData() { return mClipData; }
    public int getClipGrantFlags() { return mClipGrantFlags; }
    public int getConstraintFlags() { return mConstraintFlags; }
    public java.util.Set getDebugTags() { return new java.util.HashSet<>(mDebugTags); }
    public android.util.ArraySet getDebugTagsArraySet() { android.util.ArraySet s = new android.util.ArraySet(); s.addAll(mDebugTags); return s; }
    public long getEstimatedNetworkDownloadBytes() { return mDownloadBytes; }
    public long getEstimatedNetworkUploadBytes() { return mUploadBytes; }
    public long getFlexMillis() { return mFlex; }
    public int getFlags() { return mFlags; }
    public long getInitialBackoffMillis() { return mInitialBackoff; }
    public long getIntervalMillis() { return mInterval; }
    public long getMaxExecutionDelayMillis() { return mDeadline; }
    public long getMinLatencyMillis() { return mMinLatency; }
    public long getMinimumNetworkChunkBytes() { return mChunkBytes; }
    public int getNetworkType() { return mNetworkType; }
    public int getPriority() { return mPriority; }
    public android.net.NetworkRequest getRequiredNetwork() { return mNetworkRequest; }
    public java.lang.String getTraceTag() { return mTraceTag; }
    public android.os.Bundle getTransientExtras() { return mTransientExtras; }
    public long getTriggerContentMaxDelay() { return mTriggerMaxDelay; }
    public long getTriggerContentUpdateDelay() { return mTriggerUpdateDelay; }
    public android.app.job.JobInfo.TriggerContentUri[] getTriggerContentUris() { return mTriggerUris.isEmpty() ? null : mTriggerUris.toArray(new TriggerContentUri[0]); }
    public boolean hasEarlyConstraint() { return mHasEarly; }
    public boolean hasLateConstraint() { return mHasLate; }
    public boolean isExemptedFromAppStandby() { return (mFlags & FLAG_EXEMPT_FROM_APP_STANDBY) != 0; }
    public boolean isExpedited() { return (mFlags & FLAG_EXPEDITED) != 0; }
    public boolean isImportantWhileForeground() { return (mFlags & FLAG_IMPORTANT_WHILE_FOREGROUND) != 0; }
    public boolean isPeriodic() { return mPeriodic; }
    public boolean isPersisted() { return mPersisted; }
    public boolean isPrefetch() { return (mFlags & FLAG_PREFETCH) != 0; }
    public boolean isRequireBatteryNotLow() { return (mConstraintFlags & CONSTRAINT_FLAG_BATTERY_NOT_LOW) != 0; }
    public boolean isRequireCharging() { return (mConstraintFlags & CONSTRAINT_FLAG_CHARGING) != 0; }
    public boolean isRequireDeviceIdle() { return (mConstraintFlags & CONSTRAINT_FLAG_DEVICE_IDLE) != 0; }
    public boolean isRequireStorageNotLow() { return (mConstraintFlags & CONSTRAINT_FLAG_STORAGE_NOT_LOW) != 0; }
    public boolean isUserInitiated() { return (mFlags & FLAG_USER_INITIATED) != 0; }
    @Override public String toString() { return "JobInfo{" + mId + " " + mService + (mPeriodic ? " periodic " + mInterval : "") + "}"; }
}
