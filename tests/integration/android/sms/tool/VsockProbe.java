// SPDX-License-Identifier: Apache-2.0
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import java.io.FileDescriptor;

/**
 * Tries to create a vsock socket as whoever runs it, for the shell's row of the text-message checks:
 * {@code CLASSPATH=/data/local/tmp/vsockprobe.dex app_process /system/bin VsockProbe}. It prints
 * {@code socket: errno=13 EACCES} when the domain may not, and {@code socket: ok} when it may.
 */
public final class VsockProbe {
    /** Linux's AF_VSOCK; android.system.OsConstants has no public name for it. */
    private static final int AF_VSOCK = 40;

    private VsockProbe() {
    }

    public static void main(String[] arguments) {
        try {
            final FileDescriptor descriptor = Os.socket(AF_VSOCK, OsConstants.SOCK_STREAM, 0);
            Os.close(descriptor);
            System.out.println("socket: ok");
        } catch (ErrnoException e) {
            System.out.println("socket: errno=" + e.errno + " " + OsConstants.errnoName(e.errno));
        }
    }
}
