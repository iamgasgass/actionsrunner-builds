#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""shadow_native.py <Native.java> <out.java>: husk.Native with Java bodies instead of natives, so framework classes run on a
desktop JVM (logging to stdout, a real monotonic clock, no APK)."""
import re, sys
src = open(sys.argv[1]).read()
SPECIAL = {'packageName': 'return "com.husk.test";', 'externalDir': 'return System.getProperty("java.io.tmpdir") + "/husk-ext";',
           'log': 'System.out.println("[" + tag + "] " + msg);', 'uptimeNanos': 'return System.nanoTime();'}
def body(m):
    ret, name, params = m.group(1), m.group(2), m.group(3)
    if name in SPECIAL: b = SPECIAL[name]
    elif ret == 'void': b = ''
    elif ret == 'boolean': b = 'return false;'
    elif ret == 'long': b = 'return -1L;' if name in ('assetFd', 'apkFileFd') else 'return 0L;'
    elif ret in ('int', 'short', 'byte', 'char', 'float', 'double'): b = 'return 0;'
    else: b = 'return null;'
    return 'public static %s %s(%s) { %s }' % (ret, name, params, b)
open(sys.argv[2], 'w').write(re.sub(r'public static native ([\w.\[\]<>]+) (\w+)\(([^)]*)\);', body, src))
