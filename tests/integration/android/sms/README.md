# Android text-message probe

`AndariumSmsProbe` is an application that `tests/integration/android/run_android_sms.py` installs on a guest
under test. It holds `RECEIVE_SMS` and records the `SMS_RECEIVED` broadcasts it is handed, and it makes the
calls that an application's domain must not be able to make (a vsock socket, a virtual machine) when the
runner asks. `tool/VsockProbe.java` is the shell's counterpart, run with `app_process` from a DEX file.

Build both without Soong from the SDK tools in an Android tree's prebuilts with `build-apk.sh ANDROID_ROOT
OUTPUT_DIR`, which writes `AndariumSmsProbe.apk` (signed with the AOSP test key) and `vsockprobe.dex` below the
output directory only. The APK is also an explicit Soong module (`Android.bp`). It is not a product package and
is never installed in a release image: the target-files verifier rejects a release that holds it.
