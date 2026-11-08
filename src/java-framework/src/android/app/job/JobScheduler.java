package android.app.job;
public abstract class JobScheduler {
    public static final int RESULT_FAILURE = 0, RESULT_SUCCESS = 1;
    public abstract int schedule(JobInfo job); public abstract int enqueue(JobInfo job, JobWorkItem w); public abstract void cancel(int id); public abstract void cancelAll();
    public abstract java.util.List<JobInfo> getAllPendingJobs(); public abstract JobInfo getPendingJob(int id);
    /** The app's jobs, run in this process while it is open: each waits out its minimum latency (or, periodic, its period),
     *  runs in its JobService on the main thread, and is finished by jobFinished -- rescheduled with its back-off when asked,
     *  run again at its next period, or forgotten. Work given with enqueue is handed out through JobParameters.dequeueWork,
     *  and a job whose work has all been completed finishes by itself, as on Android. Constraints (network, charging, idle)
     *  are taken as met: the app is in the foreground on a phone that is on. */
    public static final class Impl extends JobScheduler {
        private static final class Job {
            JobInfo info; JobParameters running; Runnable timer; int failures; android.app.Service service;
            final java.util.ArrayDeque<JobWorkItem> work = new java.util.ArrayDeque<>();
        }
        private static final java.util.LinkedHashMap<Integer, Job> sJobs = new java.util.LinkedHashMap<>();
        private static android.os.Handler sMain;
        private static int sNextWorkId = 1;
        private static android.os.Handler main() { synchronized (sJobs) { if (sMain == null) sMain = new android.os.Handler(android.os.Looper.getMainLooper()); return sMain; } }

        public int schedule(JobInfo j) {
            if (j == null || j.getService() == null) return RESULT_FAILURE;
            synchronized (sJobs) {
                Job old = sJobs.get(j.getId());
                Job job = new Job();
                job.info = j;
                if (old != null) { disarm(old); stop(old, JobParameters.STOP_REASON_CANCELLED_BY_APP); }
                sJobs.put(j.getId(), job);
                arm(job, firstDelay(j));
            }
            return RESULT_SUCCESS;
        }
        public int enqueue(JobInfo j, JobWorkItem w) {
            if (j == null || j.getService() == null) return RESULT_FAILURE;
            synchronized (sJobs) {
                if (w != null) w.setWorkId(sNextWorkId++);
                Job job = sJobs.get(j.getId());
                if (job != null) {
                    job.info = j;
                    if (w != null) {
                        if (job.running != null) { synchronized (job.running.huskWork) { job.running.huskWork.add(w); } }
                        else job.work.add(w);
                    }
                    if (job.running == null && job.timer == null) arm(job, firstDelay(j));
                    return RESULT_SUCCESS;
                }
                job = new Job();
                job.info = j;
                if (w != null) job.work.add(w);
                sJobs.put(j.getId(), job);
                arm(job, firstDelay(j));
            }
            return RESULT_SUCCESS;
        }
        public void cancel(int id) {
            synchronized (sJobs) {
                Job job = sJobs.remove(id);
                if (job == null) return;
                disarm(job);
                stop(job, JobParameters.STOP_REASON_CANCELLED_BY_APP);
            }
        }
        public void cancelAll() {
            synchronized (sJobs) {
                for (Job job : new java.util.ArrayList<>(sJobs.values())) { disarm(job); stop(job, JobParameters.STOP_REASON_CANCELLED_BY_APP); }
                sJobs.clear();
            }
        }
        public java.util.List<JobInfo> getAllPendingJobs() {
            synchronized (sJobs) { java.util.ArrayList<JobInfo> l = new java.util.ArrayList<>(); for (Job job : sJobs.values()) l.add(job.info); return l; }
        }
        public JobInfo getPendingJob(int id) { synchronized (sJobs) { Job job = sJobs.get(id); return job == null ? null : job.info; } }
        @Override public java.util.List getStartedJobs() {
            synchronized (sJobs) { java.util.ArrayList<JobInfo> l = new java.util.ArrayList<>(); for (Job job : sJobs.values()) if (job.running != null) l.add(job.info); return l; }
        }
        @Override public int getPendingJobReason(int id) {
            synchronized (sJobs) { Job job = sJobs.get(id); if (job == null) return PENDING_JOB_REASON_INVALID_JOB_ID; return job.running != null ? PENDING_JOB_REASON_EXECUTING : PENDING_JOB_REASON_CONSTRAINT_MINIMUM_LATENCY; }
        }
        @Override public int[] getPendingJobReasons(int id) { return new int[] { getPendingJobReason(id) }; }
        @Override public void cancelInAllNamespaces() { cancelAll(); }

        private static long firstDelay(JobInfo j) {
            if (j.isPeriodic()) return Math.max(0, j.getIntervalMillis() - j.getFlexMillis());
            return j.hasEarlyConstraint() ? j.getMinLatencyMillis() : 0;
        }
        private static void disarm(Job job) { if (job.timer != null) { main().removeCallbacks(job.timer); job.timer = null; } }
        private static void arm(final Job job, long delay) {
            disarm(job);
            job.timer = new Runnable() { public void run() { synchronized (sJobs) { if (job.timer == this) job.timer = null; } start(job); } };
            main().postDelayed(job.timer, Math.max(0, delay));
        }
        private static void start(Job job) {
            JobParameters p;
            synchronized (sJobs) {
                if (sJobs.get(job.info.getId()) != job || job.running != null) return;
                p = new JobParameters();
                p.huskJob = job.info; p.huskJobId = job.info.getId(); p.huskExtras = job.info.getExtras();
                synchronized (p.huskWork) { p.huskWork.addAll(job.work); }
                job.work.clear();
                job.running = p;
            }
            try {
                job.service = husk.Services.jobService(job.info.getService());
                if (job.service instanceof JobService) {
                    boolean more = ((JobService) job.service).onStartJob(p);
                    if (!more) finished(p, false);
                } else {
                    job.service.onStartCommand(new android.content.Intent().setComponent(job.info.getService()), 0, 1);
                    finished(p, false);
                }
            } catch (Throwable t) {
                android.util.Log.e("Husk", "job " + job.info.getId() + " (" + job.info.getService().getClassName() + ") failed", t);
                finished(p, false);
            }
        }
        /** The job running with p, if any. */
        private static Job jobOf(JobParameters p) {
            for (Job job : sJobs.values()) if (job.running == p) return job;
            return null;
        }
        /** jobFinished(p, reschedule), or a job that returned false from onStartJob. */
        public static void finished(JobParameters p, boolean reschedule) {
            android.app.Service svc;
            synchronized (sJobs) {
                Job job = jobOf(p);
                if (job == null) return;
                svc = job.service;
                job.running = null; job.service = null;
                /* work handed out but never completed is given again next time, as Android redelivers it */
                synchronized (p.huskWork) { job.work.addAll(p.huskDelivered); job.work.addAll(p.huskWork); p.huskDelivered.clear(); p.huskWork.clear(); }
                JobInfo j = job.info;
                if (reschedule) {
                    job.failures++;
                    long base = j.getInitialBackoffMillis();
                    long d = j.getBackoffPolicy() == JobInfo.BACKOFF_POLICY_LINEAR ? base * job.failures : base << Math.min(job.failures - 1, 20);
                    arm(job, Math.min(d, JobInfo.MAX_BACKOFF_DELAY_MILLIS));
                } else if (j.isPeriodic()) {
                    job.failures = 0;
                    arm(job, j.getIntervalMillis());
                } else if (!job.work.isEmpty()) {
                    arm(job, 0);
                } else {
                    sJobs.remove(j.getId());
                }
            }
            if (svc != null) husk.Services.jobDone(svc);
        }
        /** All of a job's enqueued work is complete and none is waiting: the job is done. */
        static void workDrained(JobParameters p) {
            synchronized (sJobs) { Job job = jobOf(p); if (job == null) return; }
            finished(p, false);
        }
        private static void stop(final Job job, int reason) {
            final JobParameters p = job.running;
            final android.app.Service svc = job.service;
            if (p == null) return;
            job.running = null; job.service = null;
            synchronized (p.huskWork) { p.huskStopped = true; p.huskStopReason = reason; }
            main().post(() -> {
                try { if (svc instanceof JobService) ((JobService) svc).onStopJob(p); }
                catch (Throwable t) { android.util.Log.e("Husk", "onStopJob failed", t); }
                if (svc != null) husk.Services.jobDone(svc);
            });
        }
    }
    /** One scheduler serves every namespace here. */
    public JobScheduler forNamespace(String namespace) { return this; }
    public String getNamespace() { return null; }
    // ---- generated by tools/compat/fillmembers.py: the platform's members this class does not write (signatures only)
    public static final int PENDING_JOB_REASON_APP = 1;
    public static final int PENDING_JOB_REASON_APP_STANDBY = 2;
    public static final int PENDING_JOB_REASON_BACKGROUND_RESTRICTION = 3;
    public static final int PENDING_JOB_REASON_CONSTRAINT_BATTERY_NOT_LOW = 4;
    public static final int PENDING_JOB_REASON_CONSTRAINT_CHARGING = 5;
    public static final int PENDING_JOB_REASON_CONSTRAINT_CONNECTIVITY = 6;
    public static final int PENDING_JOB_REASON_CONSTRAINT_CONTENT_TRIGGER = 7;
    public static final int PENDING_JOB_REASON_CONSTRAINT_DEADLINE = 16;
    public static final int PENDING_JOB_REASON_CONSTRAINT_DEVICE_IDLE = 8;
    public static final int PENDING_JOB_REASON_CONSTRAINT_MINIMUM_LATENCY = 9;
    public static final int PENDING_JOB_REASON_CONSTRAINT_PREFETCH = 10;
    public static final int PENDING_JOB_REASON_CONSTRAINT_STORAGE_NOT_LOW = 11;
    public static final int PENDING_JOB_REASON_DEVICE_STATE = 12;
    public static final int PENDING_JOB_REASON_EXECUTING = -1;
    public static final int PENDING_JOB_REASON_INVALID_JOB_ID = -2;
    public static final int PENDING_JOB_REASON_JOB_SCHEDULER_OPTIMIZATION = 13;
    public static final int PENDING_JOB_REASON_QUOTA = 14;
    public static final int PENDING_JOB_REASON_UNDEFINED = 0;
    public static final int PENDING_JOB_REASON_USER = 15;
    public static final long THROW_ON_INVALID_DATA_TRANSFER_IMPLEMENTATION = 255371817L;
    public static java.lang.String sanitizeNamespace(java.lang.String p0) { return null; }
    public boolean canRunUserInitiatedJobs() { return true; }
    public void cancelInAllNamespaces() {}
    public java.util.List getAllJobSnapshots() { return new java.util.ArrayList(); }
    public int getPendingJobReason(int p0) { return 0; }
    public int[] getPendingJobReasons(int p0) { return null; }
    public java.util.List getPendingJobReasonsHistory(int p0) { return new java.util.ArrayList(); }
    public java.util.Map getPendingJobsInAllNamespaces() { return new java.util.HashMap(); }
    public java.util.List getStartedJobs() { return new java.util.ArrayList(); }
    public boolean hasRunUserInitiatedJobsPermission(java.lang.String p0, int p1) { return false; }
    public void notePendingUserRequestedAppStop(java.lang.String p0, int p1, java.lang.String p2) {}
    public int scheduleAsPackage(android.app.job.JobInfo p0, java.lang.String p1, int p2, java.lang.String p3) { return schedule(p0); }
    // ---- end of generated members
}
