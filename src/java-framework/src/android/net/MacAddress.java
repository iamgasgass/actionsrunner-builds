// SPDX-License-Identifier: GPL-2.0-or-later
package android.net;

/** A 48-bit MAC address, parsed, printed and classified as Android's is. */
public final class MacAddress implements android.os.Parcelable {
    public static final int TYPE_BROADCAST = 3;
    public static final int TYPE_MULTICAST = 2;
    public static final int TYPE_UNICAST = 1;
    public static final int TYPE_UNKNOWN = 0;
    private static final int LEN = 6;
    private final long mAddr;   /* the six bytes, big-endian, in the low 48 bits */
    public static final android.net.MacAddress ALL_ZEROS_ADDRESS = new MacAddress(0L);
    public static final android.net.MacAddress BROADCAST_ADDRESS = new MacAddress(0xffffffffffffL);
    public static android.os.Parcelable.Creator CREATOR = new android.os.Parcelable.Creator<MacAddress>() {
        public MacAddress createFromParcel(android.os.Parcel p) { return new MacAddress(p.readLong()); }
        public MacAddress[] newArray(int n) { return new MacAddress[n]; }
    };
    private MacAddress(long a) { mAddr = a & 0xffffffffffffL; }
    protected MacAddress() { this(0L); }

    public static byte[] byteAddrFromStringAddr(java.lang.String s) {
        if (s == null) throw new NullPointerException("addr");
        String[] parts = s.split(":");
        if (parts.length != LEN) throw new IllegalArgumentException(s + " was not a valid MAC address");
        byte[] b = new byte[LEN];
        for (int i = 0; i < LEN; i++) {
            int x;
            try { x = Integer.parseInt(parts[i], 16); } catch (NumberFormatException e) { throw new IllegalArgumentException(s + " was not a valid MAC address"); }
            if (x < 0 || x > 255 || parts[i].length() > 2) throw new IllegalArgumentException(s + " was not a valid MAC address");
            b[i] = (byte) x;
        }
        return b;
    }
    public static java.lang.String stringAddrFromByteAddr(byte[] b) {
        if (!isMacAddress(b)) return null;
        StringBuilder sb = new StringBuilder(17);
        for (int i = 0; i < LEN; i++) { if (i > 0) sb.append(':'); sb.append(String.format("%02x", b[i] & 0xff)); }
        return sb.toString();
    }
    public static android.net.MacAddress createRandomUnicastAddressWithGoogleBase() {
        long r = new java.security.SecureRandom().nextLong() & 0xffffffL;
        return new MacAddress((0xda_a1_19L << 24 | r) & ~(1L << 40) | (1L << 41));
    }
    public static android.net.MacAddress fromBytes(byte[] b) {
        if (!isMacAddress(b)) throw new IllegalArgumentException("addr length must be " + LEN);
        long a = 0;
        for (byte x : b) a = a << 8 | (x & 0xff);
        return new MacAddress(a);
    }
    public static android.net.MacAddress fromString(java.lang.String s) { return fromBytes(byteAddrFromStringAddr(s)); }
    public static boolean isMacAddress(byte[] b) { return b != null && b.length == LEN; }
    public static int macAddressType(byte[] b) { return isMacAddress(b) ? fromBytes(b).getAddressType() : TYPE_UNKNOWN; }
    public int describeContents() { return 0; }
    public int getAddressType() {
        if (mAddr == 0xffffffffffffL) return TYPE_BROADCAST;
        return (mAddr >>> 40 & 1) != 0 ? TYPE_MULTICAST : TYPE_UNICAST;
    }
    public java.net.Inet6Address getLinkLocalIpv6FromEui48Mac() {
        byte[] m = toByteArray(), a = new byte[16];
        a[0] = (byte) 0xfe; a[1] = (byte) 0x80;
        a[8] = (byte) (m[0] ^ 0x02); a[9] = m[1]; a[10] = m[2]; a[11] = (byte) 0xff; a[12] = (byte) 0xfe; a[13] = m[3]; a[14] = m[4]; a[15] = m[5];
        try { return java.net.Inet6Address.getByAddress(null, a, 0); } catch (java.net.UnknownHostException e) { return null; }
    }
    public boolean isLocallyAssigned() { return (mAddr >>> 40 & 2) != 0; }
    public boolean matches(android.net.MacAddress base, android.net.MacAddress mask) {
        if (base == null || mask == null) throw new NullPointerException();
        return (mAddr & mask.mAddr) == (base.mAddr & mask.mAddr);
    }
    public byte[] toByteArray() {
        byte[] b = new byte[LEN];
        for (int i = 0; i < LEN; i++) b[i] = (byte) (mAddr >>> (8 * (LEN - 1 - i)));
        return b;
    }
    public java.lang.String toOuiString() { String s = toString(); return s.substring(0, 8); }
    public void writeToParcel(android.os.Parcel p, int f) { p.writeLong(mAddr); }
    @Override public String toString() { return stringAddrFromByteAddr(toByteArray()); }
    @Override public boolean equals(Object o) { return o instanceof MacAddress && ((MacAddress) o).mAddr == mAddr; }
    @Override public int hashCode() { return (int) (mAddr ^ (mAddr >>> 32)); }
}
