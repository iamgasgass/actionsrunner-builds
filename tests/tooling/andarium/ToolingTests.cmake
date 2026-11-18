# SPDX-License-Identifier: GPL-2.0-or-later

# The staging script stages the accepted release, and with --unsigned-proof a
# developer build's proof image, whose staged manifest (a golden file that
# AndariumCore's SystemInfo reads too) says it is a proof.
uml_add_tooling_test(
    NAME andarium-stage-system-image
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_stage_system_image.py
    LABELS andarium
    TIMEOUT 120)

uml_add_tooling_test(
    NAME andarium-device-support
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_andarium_support.py
    LABELS andarium;android
    TIMEOUT 30)

# Every device run starts with free diagnostic-report slots: the counting, the
# move off the device, the refusals and, by source structure, that each device
# runner makes the check before it installs or launches anything.
uml_add_tooling_test(
    NAME ios-device-report-slots
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_device_report_slots.py
    LABELS andarium;kernarium
    TIMEOUT 60)

uml_add_tooling_test(
    NAME andarium-android-runner
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_android_runner.py
    LABELS andarium;android
    TIMEOUT 90)

# The stand-in debugger that serves the JIT's request for executable memory on
# an iOS device: its decisions on a fake memory, and the host side's parts that
# need no device.
uml_add_tooling_test(
    NAME andarium-ios-jit-debugger
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_ios_jit_debugger.py
    LABELS andarium;android
    TIMEOUT 30)

# The AppStore and TestFlight configurations build an application that passes
# this check as its last build phase; the fixtures show it finds each problem the
# script's header lists, and leaves the guest kernel image alone. They also show
# Send feedback present only where the build names a receiver, Buy me tokens only
# where it names its four product identifiers, Review on the App Store only where
# it names the application's identifier, Follow developer on X only where it names
# a handle, the ICP filing number only where it names the number, and the tip
# header's developer only where the product has Buy me tokens and the build names
# the value, in either direction; and that a TestFlight product carries none of
# Buy me tokens, Review on the App Store and the ICP filing number, whatever the
# local values are, and that an AppStore bundle holds the App Store track of the
# What's New notes and not the beta track, a TestFlight bundle the reverse, and
# that each has its configuration's app icon and an AppStore bundle holds
# nothing of the TestFlight one. A supplied value is searched in every file in
# UTF-8 and both UTF-16 byte orders, a feature's resources in nested bundles,
# property lists and asset catalogs too, and no line of the report spells a
# value, even in a path.
uml_add_tooling_test(
    NAME andarium-app-store-bundle
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_check_app_store_bundle.py
        --checker ${PROJECT_SOURCE_DIR}/Andarium/scripts/check-app-store-bundle.py
    LABELS andarium;package
    TIMEOUT 600)

# The application's own touch feedback (the side keys, the rulers) plays through
# one modifier that a launch silencing haptics reaches: no view calls SwiftUI's
# or UIKit's feedback directly.
uml_add_tooling_test(
    NAME andarium-interface-feedback
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_interface_feedback.py
        --root ${PROJECT_SOURCE_DIR}
    LABELS andarium
    TIMEOUT 60)

# Buy me tokens' words are held to App Store Review Guideline 3.1.1: no donation,
# plan, subscription, unlock, upgrade, premium, credit, balance or token amount
# in any language of the table, and the English source says a tip is a voluntary
# one-time purchase and every feature is free either way. The fixtures show the
# check finds each, and the application's own table passes.
uml_add_tooling_test(
    NAME andarium-tip-words
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_check_tip_words.py
        --checker ${PROJECT_SOURCE_DIR}/Andarium/scripts/check-tip-words.py
        --table ${PROJECT_SOURCE_DIR}/Andarium/Localization/TipJar.xcstrings
    LABELS andarium
    TIMEOUT 120)

# The document pickers open files in place in the App Store configuration and
# present the copy-mode picker in every other: the sources are read as the
# compiler reads them with and without APP_STORE, and the changes a later edit
# could make to the condition must fail, as must a bundle-check name for the
# presenter that no source defines and an in-place importer in any other
# production source that the test does not name as an exception.
uml_add_tooling_test(
    NAME andarium-document-pickers
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_document_pickers.py
        --root ${PROJECT_SOURCE_DIR}
    LABELS andarium
    TIMEOUT 60)

# Each configuration reads its own track of What's New notes: the target's resolved
# build settings give the compilation conditions, the loader's own source is compiled
# with them and run against a bundle that holds a different list in each track's file,
# and a track value that names neither track stops the compile. The same settings
# give each configuration's app icon, the exclusion of the other icon's document and
# no other app icon asset.
uml_add_tooling_test(
    NAME andarium-whats-new-track
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_whats_new_track.py
        --root ${PROJECT_SOURCE_DIR}
    LABELS andarium
    TIMEOUT 180)

# The release build refuses an embedded artifact that is behind the commit it
# archives; the fixtures build a repository, a staged system and an application
# with a kernel carrying a banner and a configuration, and change one thing each.
# An unsigned proof image, in the staged or the packaged system, stops the
# AppStore and TestFlight build phase and no other configuration's.
uml_add_tooling_test(
    NAME andarium-embedded-artifacts
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_check_embedded_artifacts.py
    LABELS andarium;android;package
    TIMEOUT 180)

# The Acknowledgements resource names a project and its license text for each
# framework the application embeds and each library of its iOS device prefixes.
uml_add_tooling_test(
    NAME andarium-acknowledgements
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_acknowledgements.py
    LABELS andarium
    TIMEOUT 60)

# The screenshot script takes one run at a time into a directory, refuses a
# second run at once and releases the directory however a run ends.
uml_add_tooling_test(
    NAME andarium-capture-screens
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_capture_screens.py
    LABELS andarium
    TIMEOUT 60)

# The String Catalogs of the application: every string translated into each
# language in the state the editor writes, specifiers and plural categories
# that fit, no Google name but the notice's own, the permission texts and
# What's New notes of both tracks present, and the catalog sync that follows the
# compiler's extraction.
uml_add_tooling_test(
    NAME andarium-localization
    COMMAND ${Python3_EXECUTABLE} -B
        ${PROJECT_SOURCE_DIR}/tests/tooling/andarium/test_localization.py
    LABELS andarium
    TIMEOUT 180)
