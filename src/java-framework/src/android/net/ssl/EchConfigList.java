package android.net.ssl;

/** An Encrypted Client Hello configuration list (API 36). Husk's TLS has no ECH; this only carries the bytes. */
public final class EchConfigList {
    private final byte[] mBytes;
    private EchConfigList(byte[] b) { mBytes = b; }
    public static EchConfigList fromBytes(byte[] echConfigList) {
        if (echConfigList == null || echConfigList.length == 0) throw new IllegalArgumentException("Empty ECH config list");
        return new EchConfigList(echConfigList.clone());
    }
    public byte[] toBytes() { return mBytes.clone(); }
}
