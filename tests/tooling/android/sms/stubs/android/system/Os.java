// SPDX-License-Identifier: GPL-2.0-or-later
//
// A stand-in for a class of android.system, only so that the service's vsock glue (VsockListener) compiles on a
// plain JVM; test_sms_service.py compiles it with the service, and the tests script the calls through Os.backend.
package android.system;

import java.io.FileDescriptor;
import java.io.IOException;
import java.net.SocketAddress;
import java.net.SocketException;

/** The calls the glue makes, each handed to the test's {@link Backend}. */
public final class Os {
    private Os() {}

    /** What a test scripts: the world the calls see. */
    public interface Backend {
        FileDescriptor socket(int domain, int type, int protocol) throws ErrnoException;

        void bind(FileDescriptor fd, SocketAddress address) throws ErrnoException, SocketException;

        void listen(FileDescriptor fd, int backlog) throws ErrnoException;

        FileDescriptor accept(FileDescriptor fd, SocketAddress peer) throws ErrnoException, SocketException;

        SocketAddress getpeername(FileDescriptor fd) throws ErrnoException;

        int poll(StructPollfd[] fds, int timeoutMillis) throws ErrnoException;

        int read(FileDescriptor fd, byte[] buffer, int offset, int length) throws ErrnoException, IOException;

        int write(FileDescriptor fd, byte[] buffer, int offset, int length) throws ErrnoException, IOException;

        void shutdown(FileDescriptor fd, int how) throws ErrnoException;

        void close(FileDescriptor fd) throws ErrnoException;

        int fcntlInt(FileDescriptor fd, int command, int argument) throws ErrnoException;
    }

    public static volatile Backend backend;

    public static FileDescriptor socket(int domain, int type, int protocol) throws ErrnoException {
        return backend.socket(domain, type, protocol);
    }

    public static void bind(FileDescriptor fd, SocketAddress address) throws ErrnoException, SocketException {
        backend.bind(fd, address);
    }

    public static void listen(FileDescriptor fd, int backlog) throws ErrnoException {
        backend.listen(fd, backlog);
    }

    public static FileDescriptor accept(FileDescriptor fd, SocketAddress peer) throws ErrnoException, SocketException {
        return backend.accept(fd, peer);
    }

    public static SocketAddress getpeername(FileDescriptor fd) throws ErrnoException {
        return backend.getpeername(fd);
    }

    public static int poll(StructPollfd[] fds, int timeoutMillis) throws ErrnoException {
        return backend.poll(fds, timeoutMillis);
    }

    public static int read(FileDescriptor fd, byte[] buffer, int offset, int length)
            throws ErrnoException, IOException {
        return backend.read(fd, buffer, offset, length);
    }

    public static int write(FileDescriptor fd, byte[] buffer, int offset, int length)
            throws ErrnoException, IOException {
        return backend.write(fd, buffer, offset, length);
    }

    public static void shutdown(FileDescriptor fd, int how) throws ErrnoException {
        backend.shutdown(fd, how);
    }

    public static void close(FileDescriptor fd) throws ErrnoException {
        backend.close(fd);
    }

    public static int fcntlInt(FileDescriptor fd, int command, int argument) throws ErrnoException {
        return backend.fcntlInt(fd, command, argument);
    }
}
