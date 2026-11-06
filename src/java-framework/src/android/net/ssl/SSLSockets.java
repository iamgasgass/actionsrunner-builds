package android.net.ssl;

import java.lang.reflect.Method;
import javax.net.ssl.SSLSocket;

/**
 * Android 10's TLS extensions for sockets (API 29), as AOSP has them: over the platform's Conscrypt
 * (com.android.org.conscrypt.Conscrypt, in the runtime's conscrypt.jar), reached by reflection.
 *
 * OkHttp 4 and 5 pick their Android10SocketAdapter whenever SDK_INT >= 29, which Husk's is, and ask isSupportedSocket of every
 * TLS socket they open: without this class every HTTPS request of such an app ended in NoClassDefFoundError. A socket that is not
 * Conscrypt's, or a runtime without Conscrypt, is "not supported", and OkHttp falls back to its other adapters.
 */
public class SSLSockets {
    private SSLSockets() {}

    private static volatile boolean sLooked;
    private static Method sIsConscrypt, sSetUseSessionTickets;

    private static void look() {
        if (sLooked) return;
        synchronized (SSLSockets.class) {
            if (sLooked) return;
            try {
                Class<?> c = Class.forName("com.android.org.conscrypt.Conscrypt");
                sIsConscrypt = c.getMethod("isConscrypt", SSLSocket.class);
                sSetUseSessionTickets = c.getMethod("setUseSessionTickets", SSLSocket.class, boolean.class);
            } catch (Throwable t) {
                sIsConscrypt = null; sSetUseSessionTickets = null;
            }
            sLooked = true;
        }
    }

    public static boolean isSupportedSocket(SSLSocket socket) {
        if (socket == null) return false;
        look();
        if (sIsConscrypt == null) return false;
        try { return (Boolean) sIsConscrypt.invoke(null, socket); } catch (Throwable t) { return false; }
    }

    public static void setUseSessionTickets(SSLSocket socket, boolean useSessionTickets) {
        if (!isSupportedSocket(socket)) throw new IllegalArgumentException("Socket is not a supported socket.");
        try { sSetUseSessionTickets.invoke(null, socket, useSessionTickets); } catch (Throwable t) { /* tickets are an optimisation */ }
    }

    /** Encrypted Client Hello (API 36): not offered; OkHttp asks for it only on 36 and later. */
    public static void setEchConfigList(SSLSocket socket, EchConfigList echConfigList) {
        if (!isSupportedSocket(socket)) throw new IllegalArgumentException("Socket is not a supported socket.");
    }
}
