package android.app.job;
/** One piece of work handed to a job with JobScheduler.enqueue: its Intent and extras, given back to the job by
 *  JobParameters.dequeueWork (this is how JobIntentService and WorkManager's enqueued work reach the app). */
public final class JobWorkItem implements android.os.Parcelable {
    private final android.content.Intent mIntent; private android.os.PersistableBundle mExtras;
    private long mDownloadBytes = JobInfo.NETWORK_BYTES_UNKNOWN, mUploadBytes = JobInfo.NETWORK_BYTES_UNKNOWN, mChunkBytes = JobInfo.NETWORK_BYTES_UNKNOWN;
    private int mDeliveryCount, mWorkId; private Object mGrants;
    public JobWorkItem(android.content.Intent i) { mIntent = i; }
    public JobWorkItem(android.content.Intent i, long download, long upload) { this(i); mDownloadBytes = download; mUploadBytes = upload; }
    public JobWorkItem(android.content.Intent i, long download, long upload, long chunk) { this(i, download, upload); mChunkBytes = chunk; }
    public android.content.Intent getIntent() { return mIntent; }
    public int describeContents() { return 0; }
    public static android.os.Parcelable.Creator CREATOR = husk.StubCreator.of(JobWorkItem.class);
    public void bumpDeliveryCount() { mDeliveryCount++; }
    public void enforceValidity(boolean p0) {}
    public int getDeliveryCount() { return mDeliveryCount; }
    public long getEstimatedNetworkDownloadBytes() { return mDownloadBytes; }
    public long getEstimatedNetworkUploadBytes() { return mUploadBytes; }
    public android.os.PersistableBundle getExtras() { return mExtras != null ? mExtras : android.os.PersistableBundle.EMPTY; }
    public java.lang.Object getGrants() { return mGrants; }
    public long getMinimumNetworkChunkBytes() { return mChunkBytes; }
    public int getWorkId() { return mWorkId; }
    public void setGrants(java.lang.Object p0) { mGrants = p0; }
    public void setWorkId(int p0) { mWorkId = p0; }
    @Override public String toString() { return "JobWorkItem{id=" + mWorkId + " intent=" + mIntent + "}"; }
    public static final class Builder {
        private android.content.Intent intent; private android.os.PersistableBundle extras; private int deliveryCount;
        private long download = JobInfo.NETWORK_BYTES_UNKNOWN, upload = JobInfo.NETWORK_BYTES_UNKNOWN, chunk = JobInfo.NETWORK_BYTES_UNKNOWN;
        public Builder() {}
        public android.app.job.JobWorkItem build() { JobWorkItem w = new JobWorkItem(intent, download, upload, chunk); w.mExtras = extras; w.mDeliveryCount = deliveryCount; return w; }
        public android.app.job.JobWorkItem build(boolean p0) { return build(); }
        public android.app.job.JobWorkItem.Builder setDeliveryCount(int p0) { deliveryCount = p0; return this; }
        public android.app.job.JobWorkItem.Builder setEstimatedNetworkBytes(long p0, long p1) { download = p0; upload = p1; return this; }
        public android.app.job.JobWorkItem.Builder setExtras(android.os.PersistableBundle p0) { extras = p0; return this; }
        public android.app.job.JobWorkItem.Builder setIntent(android.content.Intent p0) { intent = p0; return this; }
        public android.app.job.JobWorkItem.Builder setMinimumNetworkChunkBytes(long p0) { chunk = p0; return this; }
    }
}
