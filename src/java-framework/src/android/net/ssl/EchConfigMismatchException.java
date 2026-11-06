package android.net.ssl;

import javax.net.ssl.SSLException;

/** Thrown when a server rejects the ECH configuration (API 36). Never thrown by Husk, whose TLS has no ECH; here so the classes that
 *  catch it resolve. */
public final class EchConfigMismatchException extends SSLException {
    public EchConfigMismatchException(String message) { super(message); }
    public String getPublicHostname() { return null; }
    public EchConfigList getRetryConfigList() { return null; }
}
