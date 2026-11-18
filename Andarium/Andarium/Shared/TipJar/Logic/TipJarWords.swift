// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import Foundation

/// Every word the Buy me tokens sheet and its menu item show, as resources of
/// the `TipJar` string table (`Localization/TipJar.xcstrings`), the table the
/// build leaves out of a product without the tip jar. The tier names (Lite,
/// Pro, Max, Ultra) and the prices are not here: names are the app's own in
/// every language and prices are the store's.
///
/// Wording is held to App Store Review Guideline 3.1.1: a tip is a voluntary
/// one-time purchase, and no word names a donation, a plan or a subscription or
/// quotes a token balance. `Andarium/scripts/check-tip-words.py` rejects those
/// words in the table, in every language it has.
nonisolated enum TipJarWords {
    private static let table = "TipJar"

    /// The menu item, the sheet's title and what VoiceOver reads for both.
    static let name = LocalizedStringResource(
        "Buy me tokens", table: "TipJar",
        comment: "The name of the tip sheet and of its menu item: a joke on 'buy me a coffee' for an app made by one developer. The tiers are Lite, Pro, Max and Ultra, which stay in English.")
    /// VoiceOver's hint for the menu item.
    static let menuHint = LocalizedStringResource(
        "A voluntary tip for Andarium\u{2019}s developer.", table: "TipJar",
        comment: "VoiceOver hint of the Buy me tokens menu item.")

    // The conversation.
    static let sender = LocalizedStringResource(
        "Andarium\u{2019}s developer", table: "TipJar",
        comment: "Who speaks in the chat: the person who makes the app. Shown above the first message and the reply.")
    static let coffee = LocalizedStringResource(
        "Developers used to run on\u{00A0}coffee.", table: "TipJar",
        comment: "First message of the chat: the joke begins. It runs on, and ends in the next message. Its last two words are tied with a no-break space (U+00A0) so that the last one does not wrap alone; a translation ties its last words the same way, and in Chinese and Japanese with U+2060 between the characters.")
    static let tokens = LocalizedStringResource(
        "These days it\u{2019}s tokens.", table: "TipJar",
        comment: "Second message of the chat: the end of the joke, tokens being what AI services bill in.")
    static let invitation = LocalizedStringResource(
        "If Andarium is useful to you, you can buy me\u{00A0}some.", table: "TipJar",
        comment: "Third message of the chat: the invitation to tip, in the developer's first-person voice. Its last two words are tied with a no-break space (U+00A0) so that the last one does not wrap alone; a translation ties its last words the same way, and in Chinese and Japanese with U+2060 between the characters.")
    static let statement = LocalizedStringResource(
        "A tip is a voluntary one-time purchase that supports Andarium\u{2019}s development. Every feature is free either\u{00A0}way.",
        table: "TipJar",
        comment: "The plain statement under the chat, as a centred note. It must say that a tip is voluntary, one-time and a purchase, and that every feature is free whether or not someone tips. Its last two words are tied with a no-break space (U+00A0) so that the last one does not wrap alone; a translation ties its last words the same way, and in Chinese and Japanese with U+2060 between the characters.")

    // What follows a tip.
    static let thanksTitle = LocalizedStringResource(
        "Thank you!", table: "TipJar",
        comment: "The developer's first message after a tip.")
    static let thanksText = LocalizedStringResource(
        "That\u{2019}s a real token of appreciation, and it keeps Andarium going.", table: "TipJar",
        comment: "The developer's second message after a tip. 'Token of appreciation' is a pun on the tokens of the joke; a translation may drop the pun and thank warmly. Chinese and Japanese tie its last characters with U+2060 so that no lone character or mark wraps alone.")
    static let pendingTitle = LocalizedStringResource(
        "Waiting for approval", table: "TipJar",
        comment: "Title of the note when a tip waits for a family organiser to approve it (Ask to Buy).")
    static let pendingText = LocalizedStringResource(
        "You can close this sheet meanwhile.", table: "TipJar",
        comment: "The note under the waiting title: the sheet may be closed while the approval is pending. Chinese and Japanese tie its last characters with U+2060 so that no lone character or mark wraps alone.")
    static let failedTitle = LocalizedStringResource(
        "The tip didn\u{2019}t go through", table: "TipJar",
        comment: "Title of the note when a purchase failed; the App Store's own message follows it.")

    // The store's side.
    static let unavailableTitle = LocalizedStringResource(
        "Tips aren\u{2019}t available right now", table: "TipJar",
        comment: "Title of the note when the App Store gave no prices.")
    static let unavailableText = LocalizedStringResource(
        "The App Store didn\u{2019}t answer. Check the connection, then try again.", table: "TipJar",
        comment: "The note under the unavailable title; the Try again button follows it. Chinese and Japanese tie its last characters with U+2060 so that no lone character or mark wraps alone.")
    static let retry = LocalizedStringResource(
        "Try again", table: "TipJar",
        comment: "Button under the unavailable note: asks the App Store for the prices again.")
    static func restrictedTitle(device: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "Purchases aren\u{2019}t allowed on this\u{00A0}\(device)", table: "TipJar",
            comment: "Title of the note when this device may not make purchases. The placeholder is iPhone or iPad. Its last two words are tied with a no-break space (U+00A0) so that the last one does not wrap alone; a translation ties its last words the same way, and in Chinese and Japanese with U+2060 between the characters.")
    }

    // Controls and VoiceOver.
    static let done = LocalizedStringResource(
        "Done", table: "TipJar",
        comment: "Button under the conversation that closes the sheet after a tip. The close symbol in the bar has no label of ours: the system names it.")
    static let chipHint = LocalizedStringResource(
        "One-time tip", table: "TipJar",
        comment: "VoiceOver hint of each tier button.")
    static let waiting = LocalizedStringResource(
        "Waiting for the App Store", table: "TipJar",
        comment: "VoiceOver label of the spinner beside the reply while the purchase is under way.")
    static let loadingPrice = LocalizedStringResource(
        "Loading prices", table: "TipJar",
        comment: "VoiceOver label of the spinner that stands where a price will be.")

    /// Every resource of the table, for the tests and the check: one for each
    /// key (the two with a device name are given one).
    static var all: [LocalizedStringResource] {
        [
            name, menuHint, sender, coffee, tokens, invitation, statement, thanksTitle, thanksText, pendingTitle,
            pendingText, failedTitle, unavailableTitle, unavailableText, retry, restrictedTitle(device: "iPhone"),
            done, chipHint, waiting, loadingPrice,
        ]
    }

    /// The table's name, which the build compiles in with the tip jar and not otherwise.
    static var tableName: String { table }
}

#endif
