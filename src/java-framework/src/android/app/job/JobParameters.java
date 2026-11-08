package android.app.job;
/** What a running job is told: its id and extras, its network, and the work queued for it with JobScheduler.enqueue. */
public class JobParameters implements android.os.Parcelable {
    public static final int INTERNAL_STOP_REASON_ANR = 12;
    public static final int INTERNAL_STOP_REASON_CANCELED = 0;
    public static final int INTERNAL_STOP_REASON_CONSTRAINTS_NOT_SATISFIED = 1;
    public static final int INTERNAL_STOP_REASON_DATA_CLEARED = 8;
    public static final int INTERNAL_STOP_REASON_DEVICE_IDLE = 4;
    public static final int INTERNAL_STOP_REASON_DEVICE_THERMAL = 5;
    public static final int INTERNAL_STOP_REASON_PREEMPT = 2;
    public static final int INTERNAL_STOP_REASON_RESTRICTED_BUCKET = 6;
    public static final int INTERNAL_STOP_REASON_RTC_UPDATED = 9;
    public static final int INTERNAL_STOP_REASON_SUCCESSFUL_FINISH = 10;
    public static final int INTERNAL_STOP_REASON_TIMEOUT = 3;
    public static final int INTERNAL_STOP_REASON_TIMEOUT_ABANDONED = 13;
    public static final int INTERNAL_STOP_REASON_UNINSTALL = 7;
    public static final int INTERNAL_STOP_REASON_UNKNOWN = -1;
    public static final int INTERNAL_STOP_REASON_USER_UI_STOP = 11;
    public static final long OVERRIDE_HANDLE_ABANDONED_JOBS = 372529068L;
    public static final int STOP_REASON_APP_STANDBY = 12;
    public static final int STOP_REASON_BACKGROUND_RESTRICTION = 11;
    public static final int STOP_REASON_CANCELLED_BY_APP = 1;
    public static final int STOP_REASON_CONSTRAINT_BATTERY_NOT_LOW = 5;
    public static final int STOP_REASON_CONSTRAINT_CHARGING = 6;
    public static final int STOP_REASON_CONSTRAINT_CONNECTIVITY = 7;
    public static final int STOP_REASON_CONSTRAINT_DEVICE_IDLE = 8;
    public static final int STOP_REASON_CONSTRAINT_STORAGE_NOT_LOW = 9;
    public static final int STOP_REASON_DEVICE_STATE = 4;
    public static final int STOP_REASON_ESTIMATED_APP_LAUNCH_TIME_CHANGED = 15;
    public static final int STOP_REASON_PREEMPT = 2;
    public static final int STOP_REASON_QUOTA = 10;
    public static final int STOP_REASON_SYSTEM_PROCESSING = 14;
    public static final int STOP_REASON_TIMEOUT = 3;
    public static final int STOP_REASON_TIMEOUT_ABANDONED = 16;
    public static final int STOP_REASON_UNDEFINED = 0;
    public static final int STOP_REASON_USER = 13;
    public int huskJobId; public android.os.PersistableBundle huskExtras;
    /** The job this run is of (null for one made by hand), and the work waiting for it; the scheduler fills both. */
    public JobInfo huskJob;
    final java.util.ArrayDeque<JobWorkItem> huskWork = new java.util.ArrayDeque<>();
    final java.util.ArrayList<JobWorkItem> huskDelivered = new java.util.ArrayList<>();
    volatile boolean huskStopped; int huskStopReason;
    public int getJobId() { return huskJob != null ? huskJob.getId() : huskJobId; }
    public android.os.PersistableBundle getExtras() { if (huskJob != null) return huskJob.getExtras(); return huskExtras != null ? huskExtras : new android.os.PersistableBundle(); }
    public android.os.Bundle getTransientExtras() { return huskJob != null ? huskJob.getTransientExtras() : new android.os.Bundle(); }
    public android.net.Network getNetwork() { return new android.net.Network(); }
    /** The next piece of enqueued work, or null when there is none left (the job then finishes, as on Android). */
    public JobWorkItem dequeueWork() {
        synchronized (huskWork) {
            if (huskStopped) return null;
            JobWorkItem w = huskWork.poll();
            if (w != null) { w.bumpDeliveryCount(); huskDelivered.add(w); }
            return w;
        }
    }
    public void completeWork(JobWorkItem w) {
        boolean finished;
        synchronized (huskWork) { huskDelivered.remove(w); finished = huskDelivered.isEmpty() && huskWork.isEmpty(); }
        if (finished) JobScheduler.Impl.workDrained(this);
    }
    public boolean isOverrideDeadlineExpired() { return false; }
    public int getStopReason() { return huskStopReason; }
    public int describeContents() { return 0; }
    public JobParameters() {}
    public static android.os.Parcelable.Creator CREATOR = husk.StubCreator.of(JobParameters.class);
    public static int[] JOB_STOP_REASON_CODES = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    public JobParameters(android.os.IBinder p0, java.lang.String p1, int p2, android.os.PersistableBundle p3, android.os.Bundle p4, android.content.ClipData p5, int p6, boolean p7, boolean p8, boolean p9, android.net.Uri[] p10, java.lang.String[] p11, android.net.Network p12) { this(); huskJobId = p2; huskExtras = p3; }
    public static java.lang.String getInternalReasonCodeDescription(int p0) { return "reason " + p0; }
    public static int[] getJobStopReasonCodes() { return JOB_STOP_REASON_CODES.clone(); }
    public android.app.job.IJobCallback getCallback() { return null; }
    public android.content.ClipData getClipData() { return huskJob != null ? huskJob.getClipData() : null; }
    public int getClipGrantFlags() { return huskJob != null ? huskJob.getClipGrantFlags() : 0; }
    public java.lang.String getDebugStopReason() { return huskStopped ? "stopped" : null; }
    public int getInternalStopReasonCode() { return huskStopReason; }
    public android.app.job.JobParameters.JobCleanupCallback getJobCleanupCallback() { return null; }
    public java.lang.String getJobNamespace() { return null; }
    public java.lang.String[] getTriggeredContentAuthorities() { return null; }
    public android.net.Uri[] getTriggeredContentUris() { return null; }
    public void initCleaner(android.app.job.JobParameters.JobCleanupCallback p0) {}
    public boolean isExpeditedJob() { return huskJob != null && huskJob.isExpedited(); }
    public boolean isUserInitiatedJob() { return huskJob != null && huskJob.isUserInitiated(); }
    public void setNetwork(android.net.Network p0) {}
    public void setStopReason(int p0, int p1, java.lang.String p2) { huskStopReason = p0; }
    // ---- generated by tools/compat/genstubs.py: the platform's nested classes this class does not write
    public static class JobCleanupCallback implements java.lang.Runnable {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        public JobCleanupCallback(android.app.job.IJobCallback p0, int p1) {}
        public void disableCleaner() {}
        public void enableCleaner() {}
        public boolean isCleanerEnabled() { return (huskProps.get("CleanerEnabled") instanceof Boolean ? (Boolean) huskProps.get("CleanerEnabled") : false); }
        public void run() {}
        JobCleanupCallback() { this((android.app.job.IJobCallback) null, (int) 0); }
    }
    // ---- end of generated nested classes
}
