// SPDX-License-Identifier: GPL-2.0-or-later
//
// A stand-in for a class of android.system, only so that the service's vsock glue (VsockListener) compiles on a
// plain JVM; test_sms_service.py compiles it with the service, and the tests script the calls through Os.backend.
package android.system;

import java.net.SocketAddress;

public final class VmSocketAddress extends SocketAddress {
    private static final long serialVersionUID = 1L;
    private final int port;
    private final int cid;

    public VmSocketAddress(int port, int cid) {
        this.port = port;
        this.cid = cid;
    }

    public int getSvmPort() {
        return port;
    }

    public int getSvmCid() {
        return cid;
    }
}
