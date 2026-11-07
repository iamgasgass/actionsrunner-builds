package android.media;

import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.Handler;
import android.os.Looper;
import android.view.Surface;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.ArrayDeque;

/**
 * A decoder (husk.MediaCodecNative). Input is decoded as it is queued, on the queuing thread; outputs wait in order for
 * dequeueOutputBuffer, or go to the Callback on its handler (the async mode ExoPlayer uses). A video frame released with render
 * is drawn into the output Surface (a SurfaceView's software buffer), scaled to it. No encoders, no DRM.
 */
@SuppressWarnings({"unchecked", "rawtypes", "deprecation"})
public final class MediaCodec {
    public static final int BUFFER_FLAG_CODEC_CONFIG = 2;
    public static final int BUFFER_FLAG_DECODE_ONLY = 32;
    public static final int BUFFER_FLAG_END_OF_STREAM = 4;
    public static final int BUFFER_FLAG_KEY_FRAME = 1;
    public static final int BUFFER_FLAG_MUXER_DATA = 16;
    public static final int BUFFER_FLAG_PARTIAL_FRAME = 8;
    public static final int BUFFER_FLAG_SYNC_FRAME = 1;
    public static final int CONFIGURE_FLAG_DETACHED_SURFACE = 8;
    public static final int CONFIGURE_FLAG_ENCODE = 1;
    public static final int CONFIGURE_FLAG_USE_BLOCK_MODEL = 2;
    public static final int CONFIGURE_FLAG_USE_CRYPTO_ASYNC = 4;
    public static final int CRYPTO_MODE_AES_CBC = 2;
    public static final int CRYPTO_MODE_AES_CTR = 1;
    public static final int CRYPTO_MODE_UNENCRYPTED = 0;
    public static final int INFO_OUTPUT_BUFFERS_CHANGED = -3;
    public static final int INFO_OUTPUT_FORMAT_CHANGED = -2;
    public static final int INFO_TRY_AGAIN_LATER = -1;
    public static final java.lang.String PARAMETER_KEY_HDR10_PLUS_INFO = "hdr10-plus-info";
    public static final java.lang.String PARAMETER_KEY_LOW_LATENCY = "low-latency";
    public static final java.lang.String PARAMETER_KEY_OFFSET_TIME = "time-offset-us";
    public static final java.lang.String PARAMETER_KEY_QP_OFFSET_MAP = "qp-offset-map";
    public static final java.lang.String PARAMETER_KEY_QP_OFFSET_RECTS = "qp-offset-rects";
    public static final java.lang.String PARAMETER_KEY_REQUEST_SYNC_FRAME = "request-sync";
    public static final java.lang.String PARAMETER_KEY_SUSPEND = "drop-input-frames";
    public static final java.lang.String PARAMETER_KEY_SUSPEND_TIME = "drop-start-time-us";
    public static final java.lang.String PARAMETER_KEY_TUNNEL_PEEK = "tunnel-peek";
    public static final java.lang.String PARAMETER_KEY_VIDEO_BITRATE = "video-bitrate";
    public static final int VIDEO_SCALING_MODE_SCALE_TO_FIT = 1;
    public static final int VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING = 2;
    private static final int INPUTS = 8, MAX_QUEUED_OUTPUTS = 8, VIDEO_WAIT_MS = 24;
    private static final int ST_UNINITIALIZED = 0, ST_CONFIGURED = 1, ST_RUNNING = 2, ST_RELEASED = 3;
    /* Reuse native/direct buffers across channel changes. The translation-layer VM does not currently collect Java objects,
       so allocating a new direct buffer for every packet or every decoder instance turns normal IPTV playback into unbounded growth. */
    private static final Object sBufferPoolLock = new Object();
    private static final ArrayDeque<ByteBuffer> sInputBufferPool = new ArrayDeque<>();
    private static final ArrayDeque<ByteBuffer> sOutputBufferPool = new ArrayDeque<>();
    private static final ArrayDeque<byte[]> sDecodeScratchPool = new ArrayDeque<>();
    private static final ArrayDeque<Out> sOutPool = new ArrayDeque<>();
    private static int sInputBufferPoolBytes, sOutputBufferPoolBytes, sDecodeScratchPoolBytes;
    private static final int MAX_INPUT_POOL_BYTES = 64 << 20;
    private static final int MAX_OUTPUT_POOL_BYTES = 16 << 20;
    private static final int MAX_SCRATCH_POOL_BYTES = 32 << 20;
    /* Media3's input-buffer path calls ByteBuffer.limit(sampleSize). On this runtime
       allocateDirect() can surface a DirectByteBuffer whose reported capacity is only one
       4 KiB page even when the requested allocation is multi-megabyte. Husk copies queued
       input into a byte[] before native decode, so codec input buffers do not need to be
       direct. Use heap ByteBuffers here and verify their capacity before exposing them. */
    private static ByteBuffer takeInputBuffer(int capacity) {
        synchronized (sBufferPoolLock) {
            ByteBuffer best = null;
            for (java.util.Iterator<ByteBuffer> it = sInputBufferPool.iterator(); it.hasNext();) {
                ByteBuffer candidate = it.next();
                if (!candidate.isDirect() && candidate.capacity() >= capacity && (best == null || candidate.capacity() < best.capacity())) best = candidate;
            }
            if (best != null) { sInputBufferPool.remove(best); sInputBufferPoolBytes -= best.capacity(); best.clear(); }
            return best;
        }
    }
    private static void putInputBuffer(ByteBuffer buffer) {
        if (buffer == null || buffer.isDirect()) return;
        buffer.clear();
        int bytes = buffer.capacity();
        synchronized (sBufferPoolLock) {
            if (bytes <= (16 << 20) && sInputBufferPool.size() < 32 && sInputBufferPoolBytes + bytes <= MAX_INPUT_POOL_BYTES) {
                sInputBufferPool.addLast(buffer); sInputBufferPoolBytes += bytes;
            }
        }
    }
    private static ByteBuffer newInputBuffer(int capacity) {
        ByteBuffer buffer = ByteBuffer.allocate(capacity).order(ByteOrder.nativeOrder());
        if (buffer.isDirect() || buffer.capacity() < capacity) {
            throw new IllegalStateException("Husk codec input allocation failed: requested " + capacity
                + ", actual " + buffer.capacity() + ", direct=" + buffer.isDirect());
        }
        return buffer;
    }
    private static ByteBuffer takeBuffer(ArrayDeque<ByteBuffer> pool, int capacity) {
        synchronized (sBufferPoolLock) {
            ByteBuffer best = null;
            for (java.util.Iterator<ByteBuffer> it = pool.iterator(); it.hasNext();) {
                ByteBuffer candidate = it.next();
                if (candidate.capacity() >= capacity && (best == null || candidate.capacity() < best.capacity())) best = candidate;
            }
            if (best != null) {
                pool.remove(best);
                if (pool == sOutputBufferPool) sOutputBufferPoolBytes -= best.capacity();
                best.clear();
            }
            return best;
        }
    }
    private static void putBuffer(ArrayDeque<ByteBuffer> pool, ByteBuffer buffer) {
        if (buffer == null) return;
        buffer.clear();
        synchronized (sBufferPoolLock) {
            if (pool == sOutputBufferPool && buffer.capacity() <= (1 << 20)
                    && pool.size() < 64 && sOutputBufferPoolBytes + buffer.capacity() <= MAX_OUTPUT_POOL_BYTES) {
                pool.addLast(buffer); sOutputBufferPoolBytes += buffer.capacity();
            }
        }
    }
    private static byte[] takeScratch(int capacity) {
        synchronized (sBufferPoolLock) {
            byte[] best = null;
            for (java.util.Iterator<byte[]> it = sDecodeScratchPool.iterator(); it.hasNext();) {
                byte[] candidate = it.next();
                if (candidate.length >= capacity && (best == null || candidate.length < best.length)) best = candidate;
            }
            if (best != null) { sDecodeScratchPool.remove(best); sDecodeScratchPoolBytes -= best.length; }
            return best;
        }
    }
    private static void putScratch(byte[] scratch) {
        if (scratch == null) return;
        synchronized (sBufferPoolLock) {
            if (scratch.length <= (8 << 20) && sDecodeScratchPool.size() < 16
                    && sDecodeScratchPoolBytes + scratch.length <= MAX_SCRATCH_POOL_BYTES) {
                sDecodeScratchPool.addLast(scratch); sDecodeScratchPoolBytes += scratch.length;
            }
        }
    }
    private static final class Out { int index = -1; long pts; int flags, size; long frame; ByteBuffer data; }
    private static final int CB_INPUT = 1, CB_FORMAT = 2, CB_OUTPUT = 3, CB_RENDERED = 4;
    private static final ArrayDeque<CodecCallbackTask> sCallbackTasks = new ArrayDeque<>();
    private static final class CodecCallbackTask implements Runnable {
        MediaCodec codec; int generation, type, index, size, flags; long pts, renderTime; MediaFormat format;
        final BufferInfo info = new BufferInfo();
        public void run() {
            MediaCodec c = codec;
            try {
                if (c == null) return;
                Callback callback;
                OnFrameRenderedListener rendered;
                synchronized (c.mLock) {
                    if (generation != c.mGeneration || c.mState != ST_RUNNING) return;
                    callback = c.mCallback; rendered = c.mRendered;
                }
                if (type == CB_INPUT) { if (callback != null) callback.onInputBufferAvailable(c, index); }
                else if (type == CB_FORMAT) { if (callback != null) callback.onOutputFormatChanged(c, format); }
                else if (type == CB_OUTPUT) {
                    if (callback != null) { info.set(0, size, pts, flags); callback.onOutputBufferAvailable(c, index, info); }
                } else if (type == CB_RENDERED && rendered != null) rendered.onFrameRendered(c, pts, renderTime);
            } finally { recycle(); }
        }
        void recycle() {
            codec = null; format = null; generation = type = index = size = flags = 0; pts = renderTime = 0;
            synchronized (sCallbackTasks) { if (sCallbackTasks.size() < 96) sCallbackTasks.addLast(this); }
        }
    }
    private static CodecCallbackTask takeCallbackTask() {
        synchronized (sCallbackTasks) { CodecCallbackTask task = sCallbackTasks.pollFirst(); return task != null ? task : new CodecCallbackTask(); }
    }
    private final String mName, mMime;
    private final boolean mVideo;
    private long mNative;
    private int mState = ST_UNINITIALIZED, mGeneration, mScaling = VIDEO_SCALING_MODE_SCALE_TO_FIT;
    private final Object mLock = new Object();
    private final Object mDecodeLock = new Object();
    private final ArrayDeque<Integer> mPendingInputCallbacks = new ArrayDeque<>();
    private int mOutstandingOutputs;
    private byte[] mDecodeInputScratch;
    private Surface mSurface;
    private MediaFormat mInputFormat, mOutputFormat;
    private ByteBuffer[] mInputs;
    private final ArrayDeque<Integer> mFreeInputs = new ArrayDeque<>();
    private final ArrayDeque<Out> mQueue = new ArrayDeque<>();
    private Out[] mSlots = new Out[16];
    private boolean mFormatPending, mStartPending;
    private int mOutW, mOutH, mRate, mChannels, mInputCapacity;
    private boolean mLoggedInputBuffer;
    private Callback mCallback; private Handler mCallbackHandler;
    private OnFrameRenderedListener mRendered; private Handler mRenderedHandler;
    private Bitmap mFrame;
    /* A decoded frame is opaque and covers the whole surface (stretched to it, or cropped to fill it): drawn as a copy (SRC, CoreGraphics'
       copy mode) rather than blended over what was there, and with no clearing first -- per frame, that was a fill and a blend of every
       pixel of the surface that changed nothing on screen. */
    private final Paint mPaint = newFramePaint();
    private final Rect mDst = new Rect();
    private static Paint newFramePaint() {
        Paint p = new Paint(Paint.FILTER_BITMAP_FLAG);
        p.setXfermode(new android.graphics.PorterDuffXfermode(android.graphics.PorterDuff.Mode.SRC));
        return p;
    }
    private final long[] mInfo = new long[3];

    private MediaCodec(String name, String mime) throws IOException {
        mName = name; mMime = mime; mVideo = mime.startsWith("video/");
        mNative = husk.MediaCodecNative.create(mime);
        if (mNative == 0) throw new IOException("Failed to initialize " + name + ", error 0xfffffff4");
    }
    protected MediaCodec() { mName = ""; mMime = ""; mVideo = false; }
    public static MediaCodec createByCodecName(String name) throws IOException {
        MediaCodecInfo i = MediaCodecList.getInfoFor(name);
        if (i == null) throw new IllegalArgumentException("Failed to initialize " + name + ", error 0xfffffffe");
        if (i.isEncoder()) throw new IOException("Husk has no encoder " + name);
        return new MediaCodec(name, i.getSupportedTypes()[0]);
    }
    public static MediaCodec createByCodecNameForClient(String name, int pid, int uid) throws IOException { return createByCodecName(name); }
    public static MediaCodec createDecoderByType(String type) throws IOException {
        if (type == null) throw new NullPointerException();
        for (MediaCodecInfo i : MediaCodecList.infos()) for (String t : i.getSupportedTypes()) if (t.equalsIgnoreCase(type)) return new MediaCodec(i.getName(), t);
        throw new IOException("Failed to create a decoder for " + type + " (Husk decodes H.264, HEVC, AAC, MP3, AC-3, E-AC-3 and MPEG Layer I/II)");
    }
    public static MediaCodec createEncoderByType(String type) throws IOException { throw new IOException("Husk has no " + type + " encoder"); }
    public static Surface createPersistentInputSurface() { throw new IllegalArgumentException("Husk has no encoders"); }
    public static java.util.List getGloballyAvailableResources() { return new java.util.ArrayList(); }
    public static android.media.Image mapHardwareBuffer(android.hardware.HardwareBuffer b) { return null; }

    private static byte[] bytes(ByteBuffer b) {
        if (b == null) return null;
        ByteBuffer d = b.duplicate(); d.position(0); d.limit(b.limit());
        byte[] r = new byte[d.remaining()]; d.get(r); return r;
    }
    public void configure(MediaFormat format, Surface surface, MediaCrypto crypto, int flags) {
        synchronized (mLock) {
            if (mState != ST_UNINITIALIZED) throw new IllegalStateException("configure in state " + mState);
            if ((flags & CONFIGURE_FLAG_ENCODE) != 0) throw new IllegalStateException("Husk has no encoders");
            MediaFormat f = format != null ? new MediaFormat(format) : new MediaFormat();
            mInputFormat = f; mSurface = surface;
            int w = f.getInteger(MediaFormat.KEY_WIDTH, 0), h = f.getInteger(MediaFormat.KEY_HEIGHT, 0);
            int rate = f.getInteger(MediaFormat.KEY_SAMPLE_RATE, 0), ch = f.getInteger(MediaFormat.KEY_CHANNEL_COUNT, 0);
            if (!husk.MediaCodecNative.configure(mNative, w, h, rate, ch, bytes(f.getByteBuffer("csd-0")), bytes(f.getByteBuffer("csd-1")), bytes(f.getByteBuffer("csd-2"))))
                throw new CodecException(0x80001000, "the codec refused the format " + format);
            /* KEY_MAX_INPUT_SIZE is only a hint and some IPTV formats advertise 4096 bytes even
               though a single H.264/HEVC access unit can be several MiB. Media3 writes into the
               codec input buffer directly, so an undersized direct buffer fails before decode
               with ByteBuffer.limit(newLimit > capacity). Size video buffers from the configured
               dimensions as well, using long arithmetic to avoid integer overflow. */
            long declaredMax = Math.max(0L, (long) f.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 0));
            long minimum = 1L << 16;
            if (mVideo) {
                long pixels = (long) Math.max(1, w) * (long) Math.max(1, h);
                minimum = Math.max(1L << 20, pixels + pixels / 2L);
                minimum = Math.min((32L << 20), minimum + (256L << 10));
            }
            long requested = Math.max(declaredMax, minimum);
            if (mVideo && declaredMax > 0 && declaredMax < minimum) {
                android.util.Log.w("MediaCodec", "Increasing undersized video KEY_MAX_INPUT_SIZE " + declaredMax
                    + " to " + minimum + " bytes for " + w + "x" + h);
            }
            if (requested > (32L << 20)) {
                android.util.Log.w("MediaCodec", "Capping decoder input buffer at 32 MiB (requested " + requested + " bytes)");
                requested = 32L << 20;
            }
            int max = (int) requested;
            mInputCapacity = max;
            if (mInputs == null) mInputs = new ByteBuffer[INPUTS];
            for (int i = 0; i < INPUTS; i++) {
                if (mInputs[i] == null || mInputs[i].isDirect() || mInputs[i].capacity() < max) {
                    putInputBuffer(mInputs[i]);
                    ByteBuffer b = takeInputBuffer(max);
                    mInputs[i] = b != null ? b : newInputBuffer(max);
                }
                if (mInputs[i].capacity() < max || mInputs[i].isDirect()) {
                    throw new IllegalStateException("Husk codec input buffer is undersized: requested " + max
                        + ", actual " + mInputs[i].capacity() + ", direct=" + mInputs[i].isDirect());
                }
                mInputs[i].clear();
            }
            android.util.Log.i("MediaCodec", "Husk input buffers ready: " + mName + ", requested=" + max
                + ", actual=" + mInputs[0].capacity() + ", direct=" + mInputs[0].isDirect());
            if (mVideo) {
                int s = husk.MediaCodecNative.size(mNative);
                mOutW = s > 0 ? s >>> 16 : w; mOutH = s > 0 ? s & 0xffff : h;
                mOutputFormat = videoFormat(mOutW, mOutH);
            } else {
                mRate = rate > 0 ? rate : 44100; mChannels = ch > 0 ? ch : 2;
                mOutputFormat = audioFormat(mRate, mChannels);
            }
            mState = ST_CONFIGURED;
        }
    }
    public void configure(MediaFormat format, Surface surface, int flags, MediaDescrambler d) { configure(format, surface, (MediaCrypto) null, flags); }
    private static MediaFormat videoFormat(int w, int h) {
        MediaFormat f = MediaFormat.createVideoFormat("video/raw", w, h);
        f.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface);
        f.setInteger("crop-left", 0); f.setInteger("crop-top", 0); f.setInteger("crop-right", w - 1); f.setInteger("crop-bottom", h - 1);
        f.setInteger("stride", w); f.setInteger("slice-height", h);
        return f;
    }
    private static MediaFormat audioFormat(int rate, int ch) {
        MediaFormat f = MediaFormat.createAudioFormat("audio/raw", rate, ch);
        f.setInteger("pcm-encoding", AudioFormat.ENCODING_PCM_16BIT);
        return f;
    }
    public void start() {
        Integer[] inputs;
        int gen;
        synchronized (mLock) {
            if (mState == ST_UNINITIALIZED || mState == ST_RELEASED) throw new IllegalStateException("start in state " + mState);
            boolean fresh = mState == ST_CONFIGURED;
            if (!fresh && !mStartPending) return;
            mState = ST_RUNNING;
            mStartPending = false;
            mPendingInputCallbacks.clear();
            if (mCallback == null) {
                mFreeInputs.clear(); for (int i = 0; i < INPUTS; i++) mFreeInputs.add(i);
                inputs = mFreeInputs.toArray(new Integer[0]);
            } else {
                inputs = new Integer[INPUTS]; for (int i = 0; i < INPUTS; i++) inputs[i] = i;
            }
            gen = mGeneration;
        }
        for (Integer i : inputs) postInput(gen, i);
    }
    private void requireRunning() { if (mState != ST_RUNNING) throw new IllegalStateException("not executing (state " + mState + ")"); }
    public int dequeueInputBuffer(long timeoutUs) {
        synchronized (mLock) {
            requireRunning();
            if (mCallback != null) throw new IllegalStateException("dequeueInputBuffer in async mode");
            long end = System.nanoTime() + timeoutUs * 1000;
            while (mFreeInputs.isEmpty()) {
                if (timeoutUs == 0) return INFO_TRY_AGAIN_LATER;
                long left = timeoutUs < 0 ? 100 : (end - System.nanoTime()) / 1000000;
                if (left <= 0) return INFO_TRY_AGAIN_LATER;
                try { mLock.wait(left); } catch (InterruptedException e) { return INFO_TRY_AGAIN_LATER; }
                requireRunning();
            }
            return mFreeInputs.poll();
        }
    }
    public ByteBuffer getInputBuffer(int i) {
        if (mInputs == null || i < 0 || i >= mInputs.length) return null;
        ByteBuffer b = mInputs[i];
        if (b == null || b.isDirect() || b.capacity() < mInputCapacity) {
            synchronized (mLock) {
                b = mInputs[i];
                if (b == null || b.isDirect() || b.capacity() < mInputCapacity) {
                    putInputBuffer(b);
                    b = newInputBuffer(mInputCapacity);
                    mInputs[i] = b;
                }
            }
        }
        b.clear();
        if (!mLoggedInputBuffer) {
            mLoggedInputBuffer = true;
            android.util.Log.i("MediaCodec", "Husk getInputBuffer[" + i + "]: capacity=" + b.capacity()
                + ", requested=" + mInputCapacity + ", direct=" + b.isDirect());
        }
        return b;
    }
    public ByteBuffer[] getInputBuffers() {
        if (mInputs != null) for (int i = 0; i < mInputs.length; i++) {
            ByteBuffer b = getInputBuffer(i);
            if (b != null) b.clear();
        }
        return mInputs;
    }
    public android.media.Image getInputImage(int i) { return null; }
    public void queueInputBuffer(int index, int offset, int size, long ptsUs, int flags) {
        if (index < 0 || index >= INPUTS) throw new IllegalArgumentException("bad input index " + index);
        synchronized (mLock) { requireRunning(); }
        if (offset < 0 || size < 0 || (long) offset + (long) size > mInputs[index].capacity()) {
            throw new IllegalArgumentException("Husk codec input range exceeds buffer: offset=" + offset
                + ", size=" + size + ", capacity=" + mInputs[index].capacity());
        }
        synchronized (mDecodeLock) {
            if (mDecodeInputScratch == null || mDecodeInputScratch.length < size) {
                putScratch(mDecodeInputScratch);
                byte[] recycled = takeScratch(size);
                mDecodeInputScratch = recycled != null ? recycled : new byte[Math.max(size, 64 * 1024)];
            }
            if (size > 0) { ByteBuffer d = mInputs[index]; d.clear(); d.position(offset); d.get(mDecodeInputScratch, 0, size); }
            decode(mDecodeInputScratch, size, ptsUs, flags);
        }
        int gen; boolean post = false;
        synchronized (mLock) {
            if (mCallback == null) { mFreeInputs.add(index); mLock.notifyAll(); }
            else if (mOutstandingOutputs < MAX_QUEUED_OUTPUTS) post = true;
            else mPendingInputCallbacks.add(index);
            gen = mGeneration;
        }
        if (post) postInput(gen, index);
    }
    public void queueSecureInputBuffer(int index, int offset, CryptoInfo info, long ptsUs, int flags) {
        if (info != null && info.mode != CRYPTO_MODE_UNENCRYPTED) throw new CryptoException(CryptoException.ERROR_UNSUPPORTED_OPERATION, "Husk cannot decrypt protected media");
        int size = 0;
        if (info != null && info.numBytesOfClearData != null) for (int i = 0; i < info.numSubSamples; i++) size += info.numBytesOfClearData[i] + (info.numBytesOfEncryptedData != null ? info.numBytesOfEncryptedData[i] : 0);
        queueInputBuffer(index, offset, size, ptsUs, flags);
    }
    public void queueInputBuffers(int index, ArrayDeque infos) {
        for (Object o : infos) { BufferInfo b = (BufferInfo) o; queueInputBuffer(index, b.offset, b.size, b.presentationTimeUs, b.flags); }
    }
    public void queueSecureInputBuffers(int index, ArrayDeque infos, ArrayDeque cryptos) { throw new CryptoException(CryptoException.ERROR_UNSUPPORTED_OPERATION, "Husk cannot decrypt protected media"); }
    private Out takeOut() {
        synchronized (sBufferPoolLock) {
            Out o = sOutPool.pollFirst();
            if (o == null) o = new Out();
            o.index = -1; o.pts = 0; o.flags = o.size = 0; o.frame = 0; o.data = null;
            return o;
        }
    }
    private void recycleOut(Out o) {
        if (o == null) return;
        o.index = -1; o.pts = 0; o.flags = o.size = 0; o.frame = 0; o.data = null;
        synchronized (sBufferPoolLock) { if (sOutPool.size() < 128) sOutPool.addLast(o); }
    }
    private void decode(byte[] data, int size, long pts, int flags) {
        husk.MediaCodecNative.decode(mNative, data, size, pts, flags);
        int collected = collect();
        /* VideoToolbox delivers frames asynchronously. Give it a short chance to finish before returning
           another input buffer to ExoPlayer; otherwise compressed packets can outrun frame callbacks. */
        if (mVideo && collected == 0) {
            husk.MediaCodecNative.waitForFrame(mNative, VIDEO_WAIT_MS);
            collect();
        }
        if ((flags & BUFFER_FLAG_END_OF_STREAM) != 0) { Out e = takeOut(); e.pts = pts; e.flags = BUFFER_FLAG_END_OF_STREAM; emit(e, false); }
    }
    private int collect() {
        int collected = 0;
        for (;;) {
            Out o = takeOut();
            boolean changed = false;
            if (mVideo) {
                long f = husk.MediaCodecNative.nextFrame(mNative, mInfo);
                if (f == 0) { recycleOut(o); return collected; }
                o.frame = f; o.pts = mInfo[0];
                int w = (int) mInfo[1], h = (int) mInfo[2];
                o.size = Math.max(1, w * h * 3 / 2);
                if (w != mOutW || h != mOutH || mFormatPendingFirst) { mOutW = w; mOutH = h; mOutputFormat = videoFormat(w, h); changed = true; }
            } else {
                byte[] p = husk.MediaCodecNative.nextPcm(mNative, mInfo);
                if (p == null) { recycleOut(o); return collected; }
                o.data = takeBuffer(sOutputBufferPool, p.length);
                if (o.data == null) o.data = ByteBuffer.allocateDirect(p.length).order(ByteOrder.nativeOrder());
                o.data.clear(); o.data.put(p, 0, p.length); o.data.flip();
                o.size = p.length; o.pts = mInfo[0];
                if ((int) mInfo[1] != mRate || (int) mInfo[2] != mChannels || mFormatPendingFirst) { mRate = (int) mInfo[1]; mChannels = (int) mInfo[2]; mOutputFormat = audioFormat(mRate, mChannels); changed = true; }
            }
            mFormatPendingFirst = false;
            emit(o, changed);
            collected++;
        }
    }
    /* Android reports the output format once before the first output */
    private boolean mFormatPendingFirst = true;
    private void emit(Out o, boolean formatChanged) {
        int gen; MediaFormat fmt;
        synchronized (mLock) {
            int i = 0; while (i < mSlots.length && mSlots[i] != null) i++;
            if (i == mSlots.length) mSlots = java.util.Arrays.copyOf(mSlots, mSlots.length * 2);
            o.index = i; mSlots[i] = o; mOutstandingOutputs++;
            if (formatChanged && mCallback == null) mFormatPending = true;
            if (mCallback == null) { mQueue.add(o); mLock.notifyAll(); return; }
            gen = mGeneration; fmt = mOutputFormat;
        }
        if (formatChanged) postCodecCallback(gen, CB_FORMAT, -1, 0, 0, 0, fmt, null);
        postCodecCallback(gen, CB_OUTPUT, o.index, o.size, o.flags, o.pts, null, null);
    }
    private void postInput(int gen, int index) { postCodecCallback(gen, CB_INPUT, index, 0, 0, 0, null, null); }
    private void postCodecCallback(int gen, int type, int index, int size, int flags, long pts, MediaFormat format, Handler handler) {
        Handler h = handler != null ? handler : mCallbackHandler;
        if (h == null) return;
        CodecCallbackTask task = takeCallbackTask();
        task.codec = this; task.generation = gen; task.type = type; task.index = index;
        task.size = size; task.flags = flags; task.pts = pts; task.format = format;
        if (!h.post(task)) task.recycle();
    }
    public int dequeueOutputBuffer(BufferInfo info, long timeoutUs) {
        synchronized (mLock) {
            requireRunning();
            if (mCallback != null) throw new IllegalStateException("dequeueOutputBuffer in async mode");
            long end = System.nanoTime() + timeoutUs * 1000;
            for (;;) {
                if (mFormatPending) { mFormatPending = false; return INFO_OUTPUT_FORMAT_CHANGED; }
                Out o = mQueue.poll();
                if (o != null) { info.set(0, o.size, o.pts, o.flags); return o.index; }
                if (timeoutUs == 0) return INFO_TRY_AGAIN_LATER;
                long left = timeoutUs < 0 ? 100 : (end - System.nanoTime()) / 1000000;
                if (left <= 0) return INFO_TRY_AGAIN_LATER;
                try { mLock.wait(left); } catch (InterruptedException e) { return INFO_TRY_AGAIN_LATER; }
                requireRunning();
            }
        }
    }
    private Out slot(int i) { synchronized (mLock) { return i >= 0 && i < mSlots.length ? mSlots[i] : null; } }
    public ByteBuffer getOutputBuffer(int i) {
        Out o = slot(i);
        if (o == null || o.data == null) return null;
        ByteBuffer b = o.data;
        b.position(0); b.limit(o.size);
        return b;
    }
    public ByteBuffer[] getOutputBuffers() {
        synchronized (mLock) { ByteBuffer[] r = new ByteBuffer[mSlots.length]; for (int i = 0; i < r.length; i++) r[i] = mSlots[i] != null && mSlots[i].data != null ? mSlots[i].data : ByteBuffer.allocateDirect(0); return r; }
    }
    public android.media.Image getOutputImage(int i) { return null; }
    public MediaFormat getOutputFormat() { synchronized (mLock) { if (mState == ST_UNINITIALIZED) throw new IllegalStateException(); return new MediaFormat(mOutputFormat); } }
    public MediaFormat getOutputFormat(int i) { return getOutputFormat(); }
    public MediaFormat getInputFormat() { synchronized (mLock) { if (mState == ST_UNINITIALIZED) throw new IllegalStateException(); return new MediaFormat(mInputFormat); } }
    public void releaseOutputBuffer(int index, boolean render) { release(index, render, 0); }
    public void releaseOutputBuffer(int index, long renderTimestampNs) { release(index, true, renderTimestampNs); }
    private void release(int index, boolean render, long whenNs) {
        Out o; Integer pendingInput = null; int gen;
        synchronized (mLock) {
            if (mState != ST_RUNNING) throw new IllegalStateException("releaseOutputBuffer when not executing");
            if (index < 0 || index >= mSlots.length || mSlots[index] == null) throw new IllegalStateException("output buffer " + index + " is not dequeued");
            o = mSlots[index]; mSlots[index] = null;
            if (mOutstandingOutputs > 0) mOutstandingOutputs--;
            if (mCallback != null && !mPendingInputCallbacks.isEmpty() && mOutstandingOutputs < MAX_QUEUED_OUTPUTS) pendingInput = mPendingInputCallbacks.poll();
            gen = mGeneration;
        }
        if (o.data != null) { putBuffer(sOutputBufferPool, o.data); o.data = null; }
        if (o.frame != 0) {
            if (TRACE && !render) mSkipped++;
            long t0 = TRACE ? System.nanoTime() : 0;
            try { if (render) draw(o); } finally { husk.MediaCodecNative.freeFrame(o.frame); o.frame = 0; }
            if (TRACE && render) mDrawNs += System.nanoTime() - t0;
        }
        recycleOut(o);
        if (pendingInput != null) postInput(gen, pendingInput);
    }
    private static final boolean TRACE = System.getenv("TL_MEDIA_TRACE") != null;
    private int mDrawn, mSkipped;
    private long mDrawNs;
    private void draw(Out o) {
        Surface s = mSurface;
        if (TRACE && mDrawn++ % 30 == 0) android.util.Log.d("MediaCodec", mName + ": frame " + mDrawn + " at " + o.pts + " (" + mSkipped + " skipped, " + (mDrawn > 1 ? mDrawNs / 1000000 / (mDrawn - 1) : 0) + " ms a draw) " + mOutW + "x" + mOutH + " to " + (s != null ? s.huskView : null));
        if (s == null || !s.isValid() || mOutW <= 0 || mOutH <= 0) return;
        if (mFrame != null && (mFrame.getWidth() != mOutW || mFrame.getHeight() != mOutH)) {
            try { mFrame.recycle(); } catch (RuntimeException ignored) {}
            mFrame = null;
        }
        if (mFrame == null) mFrame = Bitmap.createBitmap(mOutW, mOutH, Bitmap.Config.ARGB_8888);
        if (!husk.MediaCodecNative.renderFrame(o.frame, mFrame)) return;
        Canvas c;
        try { c = s.lockCanvas(null); } catch (RuntimeException e) { return; }
        if (c == null) return;
        try {
            int cw = c.getWidth(), ch = c.getHeight();
            Rect dst = mDst;
            dst.set(0, 0, cw, ch);
            if (mScaling == VIDEO_SCALING_MODE_SCALE_TO_FIT_WITH_CROPPING) {
                float sc = Math.max((float) cw / mOutW, (float) ch / mOutH);
                int w = Math.round(mOutW * sc), h = Math.round(mOutH * sc);
                // a pixel over on each side: rounding must never leave an edge of the last frame showing
                dst.set((cw - w) / 2 - 1, (ch - h) / 2 - 1, (cw + w) / 2 + 1, (ch + h) / 2 + 1);
            }
            c.drawBitmap(mFrame, null, dst, mPaint);
        } finally { s.unlockCanvasAndPost(c); }
        if (mRendered != null) {
            Handler h = mRenderedHandler;
            if (h == null) mRendered.onFrameRendered(this, o.pts, System.nanoTime());
            else {
                CodecCallbackTask task = takeCallbackTask();
                task.codec = this; task.generation = mGeneration; task.type = CB_RENDERED;
                task.pts = o.pts; task.renderTime = System.nanoTime();
                if (!h.post(task)) task.recycle();
            }
        }
    }
    private void dropOutputs() {
        java.util.ArrayList<Out> drop = new java.util.ArrayList<>();
        synchronized (mLock) {
            for (int i = 0; i < mSlots.length; i++) if (mSlots[i] != null) { drop.add(mSlots[i]); mSlots[i] = null; }
            mQueue.clear(); mOutstandingOutputs = 0; mPendingInputCallbacks.clear();
        }
        for (Out o : drop) {
            if (o.frame != 0) { husk.MediaCodecNative.freeFrame(o.frame); o.frame = 0; }
            if (o.data != null) { putBuffer(sOutputBufferPool, o.data); o.data = null; }
            recycleOut(o);
        }
    }
    public void flush() {
        synchronized (mLock) {
            if (mState != ST_RUNNING) throw new IllegalStateException("flush when not executing");
            mGeneration++; mPendingInputCallbacks.clear();
        }
        synchronized (mDecodeLock) { husk.MediaCodecNative.flush(mNative); }
        dropOutputs();
        synchronized (mLock) {
            mFreeInputs.clear(); if (mCallback == null) for (int i = 0; i < INPUTS; i++) mFreeInputs.add(i);
            if (mCallback != null) mStartPending = true;
            mLock.notifyAll();
        }
    }
    public void stop() {
        synchronized (mLock) { if (mState == ST_RELEASED) throw new IllegalStateException(); mGeneration++; mPendingInputCallbacks.clear(); }
        synchronized (mDecodeLock) { if (mNative != 0) husk.MediaCodecNative.flush(mNative); }
        dropOutputs();
        synchronized (mLock) {
            if (mState == ST_RUNNING) mState = ST_CONFIGURED;
            mStartPending = false;
            mFreeInputs.clear(); if (mCallback == null) for (int i = 0; i < INPUTS; i++) mFreeInputs.add(i);
            mLock.notifyAll();
        }
    }
    public void reset() {
        stop();
        synchronized (mLock) {
            if (mNative != 0) husk.MediaCodecNative.destroy(mNative);
            mNative = husk.MediaCodecNative.create(mMime);
            mState = ST_UNINITIALIZED; mCallback = null; mCallbackHandler = null; mFormatPending = false; mFormatPendingFirst = true;
        }
    }
    public void release() {
        synchronized (mLock) { if (mState == ST_RELEASED) return; mGeneration++; mState = ST_RELEASED; mPendingInputCallbacks.clear(); mLock.notifyAll(); }
        synchronized (mDecodeLock) {
            dropOutputs();
            long n; synchronized (mLock) { n = mNative; mNative = 0; }
            if (n != 0) husk.MediaCodecNative.destroy(n);
            putScratch(mDecodeInputScratch); mDecodeInputScratch = null;
        }
        ByteBuffer[] inputs = mInputs; mInputs = null; mInputCapacity = 0; mLoggedInputBuffer = false;
        if (inputs != null) for (ByteBuffer b : inputs) putInputBuffer(b);
        if (mFrame != null) { try { mFrame.recycle(); } catch (RuntimeException ignored) {} mFrame = null; }
        mSurface = null; mInputFormat = null; mOutputFormat = null;
        mCallback = null; mCallbackHandler = null; mRendered = null; mRenderedHandler = null;
        synchronized (mLock) { mFreeInputs.clear(); mQueue.clear(); }
    }
    protected void finalize() { release(); }
    public void setCallback(Callback cb, Handler h) {
        synchronized (mLock) {
            if (mState != ST_UNINITIALIZED && mState != ST_CONFIGURED) throw new IllegalStateException("setCallback after start");
            mCallback = cb;
            mCallbackHandler = cb == null ? null : h != null ? h : new Handler(Looper.myLooper() != null ? Looper.myLooper() : Looper.getMainLooper());
        }
    }
    public void setCallback(Callback cb) { setCallback(cb, null); }
    public void setOnFrameRenderedListener(OnFrameRenderedListener l, Handler h) { mRendered = l; mRenderedHandler = h; }
    public void setOnFirstTunnelFrameReadyListener(Handler h, OnFirstTunnelFrameReadyListener l) {}
    public void setOutputSurface(Surface s) { if (!mVideo) throw new IllegalStateException("not a video codec"); mSurface = s; }
    public void detachOutputSurface() { mSurface = null; }
    public void setVideoScalingMode(int mode) { mScaling = mode; }
    public void setParameters(android.os.Bundle b) {}
    public void setAudioPresentation(AudioPresentation p) {}
    public void setInputSurface(Surface s) { throw new IllegalStateException("Husk has no encoders"); }
    public Surface createInputSurface() { throw new IllegalStateException("Husk has no encoders"); }
    public void signalEndOfInputStream() { throw new IllegalStateException("Husk has no encoders"); }
    public String getName() { return mName; }
    public String getCanonicalName() { return mName; }
    public MediaCodecInfo getCodecInfo() { return MediaCodecList.getInfoFor(mName); }
    public android.os.PersistableBundle getMetrics() {
        android.os.PersistableBundle b = new android.os.PersistableBundle();
        b.putString(MetricsConstants.CODEC, mName); b.putString(MetricsConstants.MIME_TYPE, mMime); b.putString(MetricsConstants.MODE, mVideo ? MetricsConstants.MODE_VIDEO : MetricsConstants.MODE_AUDIO);
        b.putInt(MetricsConstants.ENCODER, 0); b.putInt(MetricsConstants.WIDTH, mOutW); b.putInt(MetricsConstants.HEIGHT, mOutH);
        return b;
    }
    public OutputFrame getOutputFrame(int i) { return null; }
    public ParameterDescriptor getParameterDescriptor(String n) { return null; }
    public QueueRequest getQueueRequest(int i) { throw new IllegalStateException("block model is not supported"); }
    public java.util.List getRequiredResources() { return new java.util.ArrayList(); }
    public java.util.List getSupportedVendorParameters() { return new java.util.ArrayList(); }
    public void subscribeToVendorParameters(java.util.List l) {}
    public void unsubscribeFromVendorParameters(java.util.List l) {}

    public static final class BufferInfo {
        public int offset, size, flags;
        public long presentationTimeUs;
        public BufferInfo() {}
        public void set(int newOffset, int newSize, long newTimeUs, int newFlags) { offset = newOffset; size = newSize; presentationTimeUs = newTimeUs; flags = newFlags; }
        public BufferInfo dup() { BufferInfo b = new BufferInfo(); b.set(offset, size, presentationTimeUs, flags); return b; }
    }
    public static abstract class Callback {
        public Callback() {}
        public abstract void onInputBufferAvailable(MediaCodec codec, int index);
        public abstract void onOutputBufferAvailable(MediaCodec codec, int index, BufferInfo info);
        public abstract void onError(MediaCodec codec, CodecException e);
        public abstract void onOutputFormatChanged(MediaCodec codec, MediaFormat format);
        public void onCryptoError(MediaCodec codec, CryptoException e) {}
        public void onMetricsFlushed(MediaCodec codec, android.os.PersistableBundle metrics) {}
        public void onOutputBuffersAvailable(MediaCodec codec, int index, ArrayDeque infos) {}
        public void onRequiredResourcesChanged(MediaCodec codec) {}
    }
    public static final class CodecException extends IllegalStateException {
        public static final int ERROR_INSUFFICIENT_RESOURCE = 1100, ERROR_RECLAIMED = 1101;
        private final int mCode;
        CodecException(int code, String msg) { super(msg); mCode = code; }
        protected CodecException() { this(0, null); }
        public boolean isTransient() { return false; }
        public boolean isRecoverable() { return false; }
        public int getErrorCode() { return mCode; }
        public String getDiagnosticInfo() { return "android.media.MediaCodec.error_" + (mCode < 0 ? "neg_" : "") + Math.abs(mCode); }
    }
    public static final class CryptoException extends RuntimeException implements MediaDrmThrowable {
        public static final int ERROR_NO_KEY = 1, ERROR_KEY_EXPIRED = 2, ERROR_RESOURCE_BUSY = 3, ERROR_INSUFFICIENT_OUTPUT_PROTECTION = 4, ERROR_SESSION_NOT_OPENED = 5,
            ERROR_UNSUPPORTED_OPERATION = 6, ERROR_INSUFFICIENT_SECURITY = 7, ERROR_FRAME_TOO_LARGE = 8, ERROR_LOST_STATE = 9;
        private final int mCode;
        private CryptoInfo mInfo;
        public CryptoException(int code, String msg) { super(msg); mCode = code; }
        public CryptoException(String msg, int code, int vendor, int oem, int context, CryptoInfo info) { super(msg); mCode = code; mInfo = info; }
        public int getErrorCode() { return mCode; }
        public CryptoInfo getCryptoInfo() { return mInfo; }
        public int getVendorError() { return 0; }
        public int getOemError() { return 0; }
        public int getErrorContext() { return 0; }
    }
    public static final class CryptoInfo {
        public int numSubSamples;
        public int[] numBytesOfClearData, numBytesOfEncryptedData;
        public byte[] key, iv;
        public int mode;
        private Pattern mPattern = new Pattern(0, 0);
        public CryptoInfo() {}
        public void set(int subSamples, int[] clear, int[] encrypted, byte[] key, byte[] iv, int mode) {
            numSubSamples = subSamples; numBytesOfClearData = clear; numBytesOfEncryptedData = encrypted; this.key = key; this.iv = iv; this.mode = mode;
        }
        public void setPattern(Pattern p) { mPattern = p != null ? p : new Pattern(0, 0); }
        public Pattern getPattern() { return mPattern; }
        @Override public String toString() { return numSubSamples + " subsamples, mode " + mode; }
        public static final class Pattern {
            private int mEncrypt, mSkip;
            public Pattern(int encryptBlocks, int skipBlocks) { set(encryptBlocks, skipBlocks); }
            public void set(int encryptBlocks, int skipBlocks) { mEncrypt = encryptBlocks; mSkip = skipBlocks; }
            public int getEncryptBlocks() { return mEncrypt; }
            public int getSkipBlocks() { return mSkip; }
        }
    }
    public static final class GlobalResourceInfo {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        public GlobalResourceInfo() {}
        public long getAvailable() { return (huskProps.get("Available") instanceof Long ? (Long) huskProps.get("Available") : 0L); }
        public long getCapacity() { return (huskProps.get("Capacity") instanceof Long ? (Long) huskProps.get("Capacity") : 0L); }
        public java.lang.String getName() { return (java.lang.String) huskProps.get("Name"); }
    }
    public static class IncompatibleWithBlockModelException extends java.lang.RuntimeException {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        protected IncompatibleWithBlockModelException() { super(); }
    }
    public static final class InstanceResourceInfo {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        public InstanceResourceInfo() {}
        public java.lang.String getName() { return (java.lang.String) huskProps.get("Name"); }
        public long getPerFrameCount() { return (huskProps.get("PerFrameCount") instanceof Long ? (Long) huskProps.get("PerFrameCount") : 0L); }
        public long getStaticCount() { return (huskProps.get("StaticCount") instanceof Long ? (Long) huskProps.get("StaticCount") : 0L); }
    }
    public static class InvalidBufferFlagsException extends java.lang.RuntimeException {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        protected InvalidBufferFlagsException() { super(); }
    }
    public static final class LinearBlock {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        public static boolean isCodecCopyFreeCompatible(java.lang.String[] p0) { return false; }
        public static android.media.MediaCodec.LinearBlock obtain(int p0, java.lang.String[] p1) { return new LinearBlock(); }
        protected void finalize() {}
        public boolean isMappable() { return (huskProps.get("Mappable") instanceof Boolean ? (Boolean) huskProps.get("Mappable") : false); }
        public java.nio.ByteBuffer map() { return null; }
        public void recycle() {}
        protected LinearBlock() {}
    }
    public static class MediaImage extends android.media.Image {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        public MediaImage(java.nio.ByteBuffer p0, java.nio.ByteBuffer p1, boolean p2, long p3, int p4, int p5, android.graphics.Rect p6) { super(); }
        public MediaImage(java.nio.ByteBuffer[] p0, int[] p1, int[] p2, int p3, int p4, int p5, boolean p6, long p7, int p8, int p9, android.graphics.Rect p10, long p11) { super(); }
        public void close() {}
        public int getFormat() { return (huskProps.get("Format") instanceof Integer ? (Integer) huskProps.get("Format") : 0); }
        public int getHeight() { return (huskProps.get("Height") instanceof Integer ? (Integer) huskProps.get("Height") : 0); }
        public android.media.Image.Plane[] getPlanes() { return (android.media.Image.Plane[]) huskProps.get("Planes"); }
        public int getScalingMode() { return (huskProps.get("ScalingMode") instanceof Integer ? (Integer) huskProps.get("ScalingMode") : 0); }
        public long getTimestamp() { return (huskProps.get("Timestamp") instanceof Long ? (Long) huskProps.get("Timestamp") : 0L); }
        public int getTransform() { return (huskProps.get("Transform") instanceof Integer ? (Integer) huskProps.get("Transform") : 0); }
        public int getWidth() { return (huskProps.get("Width") instanceof Integer ? (Integer) huskProps.get("Width") : 0); }
        public void setCropRect(android.graphics.Rect p0) { huskProps.put("CropRect", p0); }
        MediaImage() { this((java.nio.ByteBuffer) null, (java.nio.ByteBuffer) null, (boolean) false, (long) 0L, (int) 0, (int) 0, (android.graphics.Rect) null); }
    }
    public static final class MetricsConstants {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        public static final java.lang.String CODEC = "android.media.mediacodec.codec";
        public static final java.lang.String ENCODER = "android.media.mediacodec.encoder";
        public static final java.lang.String HEIGHT = "android.media.mediacodec.height";
        public static final java.lang.String MIME_TYPE = "android.media.mediacodec.mime";
        public static final java.lang.String MODE = "android.media.mediacodec.mode";
        public static final java.lang.String MODE_AUDIO = "audio";
        public static final java.lang.String MODE_VIDEO = "video";
        public static final java.lang.String ROTATION = "android.media.mediacodec.rotation";
        public static final java.lang.String SECURE = "android.media.mediacodec.secure";
        public static final java.lang.String WIDTH = "android.media.mediacodec.width";
        protected MetricsConstants() {}
    }
    public interface OnFirstTunnelFrameReadyListener {
        void onFirstTunnelFrameReady(android.media.MediaCodec p0);
    }
    public interface OnFrameRenderedListener {
        void onFrameRendered(android.media.MediaCodec p0, long p1, long p2);
    }
    public static final class OutputFrame {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        public java.util.ArrayDeque getBufferInfos() { return (java.util.ArrayDeque) huskProps.get("BufferInfos"); }
        public java.util.Set getChangedKeys() { return (huskProps.get("ChangedKeys") != null ? (java.util.Set) huskProps.get("ChangedKeys") : new java.util.HashSet()); }
        public int getFlags() { return (huskProps.get("Flags") instanceof Integer ? (Integer) huskProps.get("Flags") : 0); }
        public android.media.MediaFormat getFormat() { return (android.media.MediaFormat) huskProps.get("Format"); }
        public android.hardware.HardwareBuffer getHardwareBuffer() { return (android.hardware.HardwareBuffer) huskProps.get("HardwareBuffer"); }
        public android.media.MediaCodec.LinearBlock getLinearBlock() { return (android.media.MediaCodec.LinearBlock) huskProps.get("LinearBlock"); }
        public long getPresentationTimeUs() { return (huskProps.get("PresentationTimeUs") instanceof Long ? (Long) huskProps.get("PresentationTimeUs") : 0L); }
        protected OutputFrame() {}
    }
    public static class ParameterDescriptor {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        public java.lang.String getName() { return (java.lang.String) huskProps.get("Name"); }
        public int getType() { return (huskProps.get("Type") instanceof Integer ? (Integer) huskProps.get("Type") : 0); }
        protected ParameterDescriptor() {}
    }
    public static final class QueueRequest {
        private final java.util.HashMap<String, Object> huskProps = new java.util.HashMap<>();
        public void queue() {}
        public android.media.MediaCodec.QueueRequest setByteBufferParameter(java.lang.String p0, java.nio.ByteBuffer p1) { return this; }
        public android.media.MediaCodec.QueueRequest setEncryptedLinearBlock(android.media.MediaCodec.LinearBlock p0, int p1, int p2, android.media.MediaCodec.CryptoInfo p3) { return this; }
        public android.media.MediaCodec.QueueRequest setFlags(int p0) { huskProps.put("Flags", Integer.valueOf(p0)); return this; }
        public android.media.MediaCodec.QueueRequest setFloatParameter(java.lang.String p0, float p1) { return this; }
        public android.media.MediaCodec.QueueRequest setHardwareBuffer(android.hardware.HardwareBuffer p0) { huskProps.put("HardwareBuffer", p0); return this; }
        public android.media.MediaCodec.QueueRequest setIntegerParameter(java.lang.String p0, int p1) { return this; }
        public android.media.MediaCodec.QueueRequest setLinearBlock(android.media.MediaCodec.LinearBlock p0, int p1, int p2) { return this; }
        public android.media.MediaCodec.QueueRequest setLongParameter(java.lang.String p0, long p1) { return this; }
        public android.media.MediaCodec.QueueRequest setMultiFrameEncryptedLinearBlock(android.media.MediaCodec.LinearBlock p0, java.util.ArrayDeque p1, java.util.ArrayDeque p2) { return this; }
        public android.media.MediaCodec.QueueRequest setMultiFrameLinearBlock(android.media.MediaCodec.LinearBlock p0, java.util.ArrayDeque p1) { return this; }
        public android.media.MediaCodec.QueueRequest setPresentationTimeUs(long p0) { huskProps.put("PresentationTimeUs", Long.valueOf(p0)); return this; }
        public android.media.MediaCodec.QueueRequest setStringParameter(java.lang.String p0, java.lang.String p1) { return this; }
        protected QueueRequest() {}
    }
}
