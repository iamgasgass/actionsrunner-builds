// SPDX-License-Identifier: Apache-2.0
package android.kernarium.sms;

import android.app.Application;
import android.os.SELinux;
import android.util.Log;
import java.io.File;
import java.util.function.Consumer;

/**
 * The service's process: a persistent system application that listens on vsock port 5560 for the host's
 * requests and hands each message to Android once (DeliveryRecord). It declares no component, so nothing
 * but the host's connection reaches it. The record is in device-protected storage: it is usable at boot,
 * whether or not the application is direct-boot aware, and Erase removes it with the data partition.
 */
public final class HostChannel extends Application {
    private static final String TAG = "AndariumSms";
    private static final long RETRY_MILLIS = 1000;

    @Override
    public void onCreate() {
        super.onCreate();
        final Consumer<String> log = line -> Log.i(TAG, line);
        try {
            final File directory = createDeviceProtectedStorageContext().getFilesDir();
            log.accept("record in " + directory + ", labelled " + SELinux.getFileContext(directory.getPath()));
            final DeliveryRecord record = new DeliveryRecord(new RecordFiles.Nio(directory.toPath()),
                    RecordStore.CAPACITY, new Delivery(this), log);
            final Server server = new Server(new VsockListener(log, Thread::sleep), new DeliveryService(record), log,
                    System::nanoTime, RETRY_MILLIS);
            final Thread thread = new Thread(server, "andarium-sms-host");
            thread.start();
        } catch (RuntimeException e) {
            Log.e(TAG, "the host channel did not start", e);
        }
    }
}
