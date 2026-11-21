// SPDX-License-Identifier: GPL-2.0-or-later
//
// Henge X: the deck under the Mac's screen, upright, made like the lower half of a MacBook, after
// Huy Nguyen's video of macOS 27.2 on the half-folded iPhone Duo (Henge with "some keyboard on the
// extended screen"), in Henge X 1.0.0's colours on an iOS dark mode deck (near-black keys in a dark well,
// Henge's Desk colours for the tools): a deck with a grab bar, four small buttons at its top right
// (keyboard, laptop, info, power), a MacBook keyboard with its real function row (brightness, Mission
// Control, Spotlight, dictation, Do Not Disturb, media, mute and volume, Touch ID), and a large trackpad
// under it. The laptop button turns the deck into the trackpad alone, with the session's tools above
// it and Click / Right-click under it; the same button brings the keyboard back.
//
// It replaces WindowsiOS X's Surface deck (LaptopDeckView.swift on that branch). Keys go to the Mac as
// USB HID usages (henge_vm_key_hid); control, option, command and shift latch through StickyKeys, so one
// finger makes a shortcut and ⌘-click works. The trackpad is the session's own Trackpad, which macOS
// sees as a Magic Trackpad 2.
import SwiftUI
import UIKit

/// What the deck under the screen shows, upright: the MacBook (keyboard and trackpad) or the trackpad alone.
enum DeckLayout: String, CaseIterable {
    case laptop
    case trackpad

    static let key = "hengex.deck.layout"

    var toggled: DeckLayout { self == .laptop ? .trackpad : .laptop }
}

/// Settings › Aspect: how the session lays out upright. Henge classic is the layout before the new
/// proportions, exactly: the Mac's screen full width at the top, the deck right under it, the keyboard's
/// height capped by the width and the trackpad taking the rest. Henge X is WindowsiOS X's proportions:
/// a black panel down to half the device for the screen, the keyboard 62.5% of the deck.
enum LayoutAspect: String, CaseIterable, Identifiable {
    case classic
    case hengeX

    static let key = "hengex.layout.aspect"
    var id: String { rawValue }
    var title: String { self == .classic ? "Henge classic" : "Henge X" }
}

/// Settings › macOS Deck: how the deck under the Mac looks. Henge X is the current deck (iOS dark mode
/// background, near-black keys in a dark well, Henge's Desk colours for the tools). Henge ALT is the deck as
/// in Huy Nguyen's video of macOS 27.2 on the half-folded iPhone Duo (commit d6267c0): slate-violet aluminium,
/// keys straight on it, a violet trackpad, the session's tools bare on the deck.
enum DeckStyle: String, CaseIterable, Identifiable {
    case hengeX
    case alt

    static let key = "hengex.deck.style"
    var id: String { rawValue }
    var title: String { self == .hengeX ? "Henge X" : "Henge ALT" }
}

/// Henge ALT's colours, exactly those of the video's deck (commit d6267c0).
private enum AltColor {
    static let deck = Color(red: 0.235, green: 0.224, blue: 0.345)
    static let deckLow = Color(red: 0.200, green: 0.190, blue: 0.300)
    static let key = Color(red: 0.150, green: 0.150, blue: 0.180)
    static let keyDown = Color(red: 0.300, green: 0.300, blue: 0.360)
    static let keyLatched = Color(red: 0.250, green: 0.250, blue: 0.320)
    static let pad = Color(red: 0.310, green: 0.294, blue: 0.455)
    static let legend = Color.white.opacity(0.92)
    static let faint = Color.white.opacity(0.55)
    static let button = Color.white.opacity(0.10)
    static let power = Color(red: 1.0, green: 0.27, blue: 0.23)
}

/// Turns the scene: Studio is the Mac on its side, full screen; Laptop is upright, the Mac above the deck.
/// As WindowsiOS X's SceneOrientationController. A request, not a lock: turning the device turns it back.
@MainActor
enum SceneOrientation {
    static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    static func studio() { request(.landscapeRight) }
    static func laptop() { request(.portrait) }

    private static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = activeScene() else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            HengeLog.log("deck", "orientation request refused: \(error.localizedDescription)")
        }
    }
}

/// The deck's colours: exactly those of Henge X 1.0.0 (commit 2ef2084), on a deck in iOS dark mode's colours,
/// and Henge's own Desk colours for the session's tools and the trackpad panel.
private enum DeckColor {
    // The deck's background: iOS dark mode's own colours, secondarySystemBackground (#1C1C1E) at the top
    // down to systemBackground (#000000) at the bottom.
    static let top = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let middle = Color(red: 14 / 255, green: 14 / 255, blue: 15 / 255)
    static let bottom = Color.black
    static let well = Color.black.opacity(0.55)
    static let key = Color(white: 0.085)
    static let keyDown = Color(white: 0.30)
    static let keyLatched = Color(white: 0.20)
    static let arrow = Color(white: 0.09)
    static let arrowDown = Color(white: 0.32)
    static let padTop = Color(red: 0.17, green: 0.175, blue: 0.19)
    static let padBottom = Color(red: 0.14, green: 0.145, blue: 0.16)
    static let legend = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.55)
}

// MARK: - The keyboard's model

/// What the function row does. A Mac keyboard's media and brightness keys are consumer-page usages,
/// which the virtual USB keyboard doesn't carry, so those do the nearest thing (noted per key); mute and
/// volume are on the keyboard page and go to macOS as they are.
private enum FunctionAction: Equatable {
    case escape
    case brightnessDown, brightnessUp   // the screen's brightness on the device (the session's own setting)
    case missionControl                 // ⌃↑
    case spotlight                      // ⌘Space
    case dictation                      // F5
    case doNotDisturb                   // F6
    case rewind, playPause, fastForward // F7, F8, F9
    case mute, volumeDown, volumeUp     // HID 0x7f, 0x81, 0x80
    case touchID                        // ⌃⌘Q: lock the screen
}

private enum KeyRole: Equatable {
    case function(action: FunctionAction, fnHid: UInt8?, symbol: String?, text: String?)
    case regular(hid: UInt8, primary: String, shifted: String?, fnHid: UInt8?, fnLabel: String?)
    case modifier(code: UInt16, symbol: String, name: String)
    case capsLock
    case fnGlobe
    case upDownStack // the MacBook's half-height ↑ and ↓ between ← and →
}

private struct KeySpec: Identifiable {
    let id: String
    let widthWeight: CGFloat
    let role: KeyRole

    static func fn(_ id: String, _ action: FunctionAction, fnHid: UInt8? = nil,
                   symbol: String? = nil, text: String? = nil, w: CGFloat = 1.0) -> KeySpec {
        KeySpec(id: id, widthWeight: w, role: .function(action: action, fnHid: fnHid, symbol: symbol, text: text))
    }

    static func key(_ primary: String, shifted: String? = nil, hid: UInt8, w: CGFloat = 1.0,
                    fnHid: UInt8? = nil, fnLabel: String? = nil) -> KeySpec {
        KeySpec(id: "\(primary)_\(hid)", widthWeight: w,
                role: .regular(hid: hid, primary: primary, shifted: shifted, fnHid: fnHid, fnLabel: fnLabel))
    }

    static func mod(_ id: String, _ code: UInt16, _ symbol: String, _ name: String, w: CGFloat) -> KeySpec {
        KeySpec(id: id, widthWeight: w, role: .modifier(code: code, symbol: symbol, name: name))
    }
}

/// HID usages the keyboard sends (USB HID Usage Tables, keyboard page).
private enum HID {
    static let q: UInt8 = 0x14, returnKey: UInt8 = 0x28, escape: UInt8 = 0x29, delete: UInt8 = 0x2a
    static let tab: UInt8 = 0x2b, space: UInt8 = 0x2c, capsLock: UInt8 = 0x39
    static let f5: UInt8 = 0x3e, f6: UInt8 = 0x3f, f7: UInt8 = 0x40, f8: UInt8 = 0x41, f9: UInt8 = 0x42
    static let forwardDelete: UInt8 = 0x4c
    static let right: UInt8 = 0x4f, left: UInt8 = 0x50, down: UInt8 = 0x51, up: UInt8 = 0x52
    static let home: UInt8 = 0x4a, pageUp: UInt8 = 0x4b, end: UInt8 = 0x4d, pageDown: UInt8 = 0x4e
    static let mute: UInt8 = 0x7f, volumeUp: UInt8 = 0x80, volumeDown: UInt8 = 0x81
    static let control: UInt8 = 0xe0, command: UInt8 = 0xe3
}

private enum Rows {
    // The MacBook's function row, at two thirds of a key's height. With fn on, F1–F12.
    static let function: [KeySpec] = [
        .fn("esc", .escape, text: "esc", w: 1.5),
        .fn("f1", .brightnessDown, fnHid: 0x3a, symbol: "sun.min"),
        .fn("f2", .brightnessUp, fnHid: 0x3b, symbol: "sun.max"),
        .fn("f3", .missionControl, fnHid: 0x3c, symbol: "rectangle.3.group"),
        .fn("f4", .spotlight, fnHid: 0x3d, symbol: "magnifyingglass"),
        .fn("f5", .dictation, fnHid: 0x3e, symbol: "mic"),
        .fn("f6", .doNotDisturb, fnHid: 0x3f, symbol: "moon"),
        .fn("f7", .rewind, fnHid: 0x40, symbol: "backward"),
        .fn("f8", .playPause, fnHid: 0x41, symbol: "playpause"),
        .fn("f9", .fastForward, fnHid: 0x42, symbol: "forward"),
        .fn("f10", .mute, fnHid: 0x43, symbol: "speaker.slash"),
        .fn("f11", .volumeDown, fnHid: 0x44, symbol: "speaker.wave.1"),
        .fn("f12", .volumeUp, fnHid: 0x45, symbol: "speaker.wave.3"),
        .fn("touchid", .touchID, symbol: "touchid"),
    ]

    // The MacBook's ANSI (U.S.) layout. macOS reads keys by position, so another layout chosen in
    // macOS's settings types its own characters from the same keys.
    static let main: [[KeySpec]] = [
        [
            .key("`", shifted: "~", hid: 0x35),
            .key("1", shifted: "!", hid: 0x1e), .key("2", shifted: "@", hid: 0x1f), .key("3", shifted: "#", hid: 0x20),
            .key("4", shifted: "$", hid: 0x21), .key("5", shifted: "%", hid: 0x22), .key("6", shifted: "^", hid: 0x23),
            .key("7", shifted: "&", hid: 0x24), .key("8", shifted: "*", hid: 0x25), .key("9", shifted: "(", hid: 0x26),
            .key("0", shifted: ")", hid: 0x27), .key("-", shifted: "_", hid: 0x2d), .key("=", shifted: "+", hid: 0x2e),
            .key("delete", hid: HID.delete, w: 1.5, fnHid: HID.forwardDelete, fnLabel: "⌦"),
        ],
        [
            .key("tab", hid: HID.tab, w: 1.5),
            .key("q", hid: 0x14), .key("w", hid: 0x1a), .key("e", hid: 0x08), .key("r", hid: 0x15),
            .key("t", hid: 0x17), .key("y", hid: 0x1c), .key("u", hid: 0x18), .key("i", hid: 0x0c),
            .key("o", hid: 0x12), .key("p", hid: 0x13),
            .key("[", shifted: "{", hid: 0x2f), .key("]", shifted: "}", hid: 0x30), .key("\\", shifted: "|", hid: 0x31),
        ],
        [
            KeySpec(id: "caps", widthWeight: 1.8, role: .capsLock),
            .key("a", hid: 0x04), .key("s", hid: 0x16), .key("d", hid: 0x07), .key("f", hid: 0x09),
            .key("g", hid: 0x0a), .key("h", hid: 0x0b), .key("j", hid: 0x0d), .key("k", hid: 0x0e), .key("l", hid: 0x0f),
            .key(";", shifted: ":", hid: 0x33), .key("'", shifted: "\"", hid: 0x34),
            .key("return", hid: HID.returnKey, w: 1.8),
        ],
        [
            .mod("lshift", Keys.shift, "⇧", "shift", w: 2.35),
            .key("z", hid: 0x1d), .key("x", hid: 0x1b), .key("c", hid: 0x06), .key("v", hid: 0x19),
            .key("b", hid: 0x05), .key("n", hid: 0x11), .key("m", hid: 0x10),
            .key(",", shifted: "<", hid: 0x36), .key(".", shifted: ">", hid: 0x37), .key("/", shifted: "?", hid: 0x38),
            .mod("rshift", Keys.shift, "⇧", "shift", w: 2.35),
        ],
        [
            KeySpec(id: "fn", widthWeight: 1.0, role: .fnGlobe),
            .mod("lctrl", Keys.control, "⌃", "control", w: 1.0),
            .mod("lopt", Keys.option, "⌥", "option", w: 1.0),
            .mod("lcmd", Keys.command, "⌘", "command", w: 1.3),
            .key("space", hid: HID.space, w: 5.0),
            .mod("rcmd", Keys.command, "⌘", "command", w: 1.3),
            .mod("ropt", Keys.option, "⌥", "option", w: 1.0),
            .key("←", hid: HID.left, fnHid: HID.home, fnLabel: "home"),
            KeySpec(id: "updown", widthWeight: 1.0, role: .upDownStack),
            .key("→", hid: HID.right, fnHid: HID.end, fnLabel: "end"),
        ],
    ]
}

// MARK: - The deck

struct MacKeyboardDeck: View {
    @Binding var layout: DeckLayout
    /// Settings › Aspect: Henge classic keeps the deck's proportions from before Henge X's.
    @AppStorage(LayoutAspect.key) private var aspect = LayoutAspect.hengeX
    /// Settings › macOS Deck: Henge X or Henge ALT (the video's deck).
    @AppStorage(DeckStyle.key) private var style = DeckStyle.hengeX
    private var alt: Bool { style == .alt }
    let controlsHidden: Bool
    let bottomInset: CGFloat
    let typing: () -> Void
    let hide: () -> Void
    let zoom: () -> Void
    let details: () -> Void
    let shutDown: () -> Void

    @ObservedObject private var sticky = StickyKeys.shared
    @AppStorage("henge.display.brightness") private var brightness = 1.0
    @State private var capsLocked = false
    @State private var fnActive = false

    private let keyHaptic = UIImpactFeedbackGenerator(style: .rigid)

    init(layout: Binding<DeckLayout>, controlsHidden: Bool, bottomInset: CGFloat,
         typing: @escaping () -> Void, hide: @escaping () -> Void, zoom: @escaping () -> Void,
         details: @escaping () -> Void, shutDown: @escaping () -> Void) {
        _layout = layout
        self.controlsHidden = controlsHidden
        self.bottomInset = bottomInset
        self.typing = typing
        self.hide = hide
        self.zoom = zoom
        self.details = details
        self.shutDown = shutDown
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let bottom = max(bottomInset, 10)
            ZStack(alignment: .top) {
                deckSurface
                VStack(spacing: 0) {
                    header(width: w)
                    switch layout {
                    case .laptop:
                        let room = geo.size.height - 34 - bottom
                        if aspect == .classic {
                            // Henge classic: exactly as before the new proportions.
                            let keyboardH = min(max(room * 0.56, 150), (w - 16) * 0.56)
                            keyboard
                                .frame(height: keyboardH)
                                .padding(.horizontal, 6)
                            Spacer(minLength: 10)
                            trackpad(width: min(w * 0.62, w - 40))
                                .frame(height: max(room - keyboardH - 14, 56))
                        } else {
                            // Henge X, WindowsiOS X's proportions: the keyboard takes 62.5% of the deck's body and
                            // the trackpad the rest, max(246, 56% of the width) wide and never closer than 32 to an edge.
                            let keyboardH = max(142, room * 0.625)
                            keyboard
                                .frame(height: keyboardH)
                                .padding(.horizontal, 6)
                            Spacer(minLength: 8)
                            trackpad(width: min(max(246, w * 0.56), w - 64))
                                .frame(height: max(room - keyboardH - 12, 56))
                        }
                    case .trackpad:
                        if !controlsHidden { toolbar.padding(.horizontal, 10) }
                        trackpadPanel
                            .frame(width: w - 20)
                            .padding(.top, 6)
                    }
                }
                .padding(.bottom, bottom)
                .frame(width: w)
            }
            .frame(width: w, height: geo.size.height)
        }
        .animation(.snappy(duration: 0.22), value: layout)
    }

    // MARK: Surface

    @ViewBuilder private var deckSurface: some View {
        if alt {
            let shape = UnevenRoundedRectangle(topLeadingRadius: 24, bottomLeadingRadius: 0,
                                               bottomTrailingRadius: 0, topTrailingRadius: 24, style: .continuous)
            shape
                .fill(LinearGradient(colors: [AltColor.deck, AltColor.deckLow], startPoint: .top, endPoint: .bottom))
                .overlay(shape.stroke(LinearGradient(colors: [Color.white.opacity(0.18), .clear],
                                                     startPoint: .top, endPoint: .center), lineWidth: 0.7))
        } else {
            let shape = UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 0,
                                               bottomTrailingRadius: 0, topTrailingRadius: 22, style: .continuous)
            ZStack {
                LinearGradient(colors: [DeckColor.top, DeckColor.middle, DeckColor.bottom], startPoint: .top, endPoint: .bottom)
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(0.14), .clear],
                                                       startPoint: .top, endPoint: .center), lineWidth: 0.7))
        }
    }

    /// The grab bar in the middle, and in laptop mode the four small buttons at the right, as in the video.
    private func header(width: CGFloat) -> some View {
        ZStack {
            Capsule().fill(DeckColor.well).frame(width: 46, height: 3.5)
            if layout == .laptop && !controlsHidden {
                HStack(spacing: 6) {
                    Spacer()
                    small("keyboard", "Keyboard", action: typing)
                    small("laptopcomputer", "Trackpad only") { layout = .trackpad }
                    small("info.circle", "Details", action: details)
                    small("power", "Shut down", tint: alt ? AltColor.power : Desk.bad, action: shutDown)
                }
                .padding(.trailing, 10)
            }
        }
        .frame(width: width, height: 34)
    }

    private func small(_ symbol: String, _ label: String, tint: Color? = nil,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? (alt ? AltColor.legend : Desk.text))
                .frame(width: 30, height: 22)
                .background(alt ? AltColor.button : Desk.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(alt ? Color.clear : Desk.hairline, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Trackpad mode's tools, on the deck above the pad (the session's own, plus the laptop button).
    private var toolbar: some View {
        // No fixed gaps: seven buttons must fit the narrowest iPhone, so only the spacers stretch.
        HStack(spacing: 0) {
            tool("eye.slash", "Hide controls", action: hide)
            Spacer(minLength: 0)
            tool("keyboard", "Keyboard", action: typing)
            Spacer(minLength: 0)
            tool("laptopcomputer", "MacBook keyboard") { layout = .laptop }
            Spacer(minLength: 0)
            PasteButton(payloadType: String.self) { texts in
                if let text = texts.first { Sharing.paste(text) }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .tint(alt ? AltColor.button : Desk.raised)
            Spacer(minLength: 0)
            tool("plus.magnifyingglass", "Zoom in", action: zoom)
            Spacer(minLength: 0)
            tool("info.circle", "Details", action: details)
            Spacer(minLength: 0)
            tool("power", "Shut down", tint: alt ? AltColor.power : Desk.bad, action: shutDown)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: alt ? 44 : 54)
        // Henge ALT: the tools bare on the deck, as in the video; Henge X: in the session's capsule.
        .background(alt ? Color.clear : Desk.card, in: Capsule())
        .overlay(Capsule().stroke(alt ? Color.clear : Desk.hairline, lineWidth: 0.5))
    }

    private func tool(_ symbol: String, _ label: String, tint: Color? = nil,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: alt ? 18 : 19, weight: .medium))
                .foregroundStyle(tint ?? (alt ? AltColor.legend : Desk.text))
                .frame(width: 40, height: alt ? 40 : 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func trackpad(width: CGFloat) -> some View {
        ZStack {
            if alt {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AltColor.pad)
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.13), lineWidth: 0.7)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [DeckColor.padTop, DeckColor.padBottom], startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.6)
            }
            Trackpad()
        }
        .frame(width: width)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The trackpad alone: the hints in the middle, Click and Right-click along the bottom.
    private var trackpadPanel: some View {
        GeometryReader { g in
            let compact = g.size.height < 240
            VStack(spacing: 0) {
                ZStack {
                    Trackpad()
                    if compact && !alt {
                        Text("Trackpad").font(.system(size: 14)).foregroundStyle(Desk.faint).allowsHitTesting(false)
                    } else if !compact {
                        VStack(spacing: 6) {
                            hint("Drag", "to move")
                            hint("Tap", "to click")
                            hint("Hold, then drag", "to grab")
                            hint("Two fingers", "to scroll")
                        }
                        .allowsHitTesting(false)
                    }
                }
                Rectangle().fill(alt ? Color.white.opacity(0.10) : Desk.hairline).frame(height: 0.5)
                HStack(spacing: 0) {
                    MouseButton(title: "Click", button: 0)
                    Rectangle().fill(alt ? Color.white.opacity(0.10) : Desk.hairline).frame(width: 0.5)
                    MouseButton(title: "Right-click", button: 1)
                }
                .frame(height: alt ? (compact ? 48 : 64) : (compact ? 50 : 70))
            }
            .background(alt ? AltColor.pad.opacity(0.55) : Desk.card)
            .clipShape(RoundedRectangle(cornerRadius: alt ? 22 : 30, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: alt ? 22 : 30, style: .continuous)
                .stroke(alt ? Color.white.opacity(0.10) : Desk.hairline, lineWidth: 0.5))
        }
    }

    private func hint(_ strong: String, _ rest: String) -> some View {
        (Text(strong).foregroundColor(alt ? AltColor.legend : Desk.dim).fontWeight(.semibold)
            + Text(" \(rest)").foregroundColor(alt ? AltColor.faint : Desk.faint))
            .font(.system(size: 15))
    }

    // MARK: Keyboard

    private var keyboard: some View {
        GeometryReader { g in
            let spacing: CGFloat = 4
            let unit = max(18, (g.size.height - spacing * 5) / 5.62) // the function row is two thirds of a key
            VStack(spacing: spacing) {
                row(Rows.function, height: unit * 0.62, functionRow: true)
                ForEach(0..<Rows.main.count, id: \.self) { i in
                    row(Rows.main[i], height: unit, functionRow: false)
                }
            }
        }
        .padding(alt ? 0 : 5) // Henge ALT: the keys straight on the deck, no well
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(alt ? Color.clear : DeckColor.well))
    }

    private func row(_ keys: [KeySpec], height: CGFloat, functionRow: Bool) -> some View {
        GeometryReader { g in
            let total = keys.reduce(CGFloat(0)) { $0 + $1.widthWeight }
            let spacing: CGFloat = 4
            let avail = max(10, g.size.width - spacing * CGFloat(keys.count - 1))
            HStack(spacing: spacing) {
                ForEach(keys) { spec in
                    let kw = avail * spec.widthWeight / total
                    if spec.role == .upDownStack {
                        ArrowStack(fnActive: fnActive, alt: alt) { up in
                            keyHaptic.impactOccurred(intensity: 0.6)
                            tap(up ? (fnActive ? HID.pageUp : HID.up) : (fnActive ? HID.pageDown : HID.down))
                        }
                        .frame(width: kw, height: height)
                    } else {
                        Keycap(spec: spec, functionRow: functionRow, shift: sticky.down.contains(Keys.shift) || capsLocked,
                               lit: lit(spec), fnActive: fnActive, alt: alt,
                               down: { keyDown(spec) }, up: { keyUp(spec) })
                            .frame(width: kw, height: height)
                    }
                }
            }
        }
        .frame(height: height)
    }

    private func lit(_ spec: KeySpec) -> Bool {
        switch spec.role {
        case .capsLock: return capsLocked
        case .fnGlobe: return fnActive
        case .modifier(let code, _, _): return sticky.down.contains(code)
        default: return false
        }
    }

    /// One key, pressed and let go, with the latched modifiers, which then let go too.
    private func tap(_ hid: UInt8) {
        henge_vm_key_hid(hid, 1)
        henge_vm_key_hid(hid, 0)
        StickyKeys.shared.releaseAll()
    }

    /// A shortcut: the modifiers down, the key, the modifiers up.
    private func chord(_ modifiers: [UInt8], _ hid: UInt8) {
        for m in modifiers { henge_vm_key_hid(m, 1) }
        henge_vm_key_hid(hid, 1)
        henge_vm_key_hid(hid, 0)
        for m in modifiers.reversed() { henge_vm_key_hid(m, 0) }
        StickyKeys.shared.releaseAll()
    }

    private func keyDown(_ spec: KeySpec) {
        keyHaptic.impactOccurred(intensity: 0.7)
        switch spec.role {
        case .capsLock:
            capsLocked.toggle()
            henge_vm_key_hid(HID.capsLock, 1)
            henge_vm_key_hid(HID.capsLock, 0)
        case .fnGlobe:
            fnActive.toggle()
        case .modifier(let code, _, _):
            StickyKeys.shared.toggle(code)
        case .function(let action, let fnHid, _, _):
            if fnActive, let fnHid { tap(fnHid); return }
            perform(action)
        case .regular(let hid, _, _, let fnHid, _):
            henge_vm_key_hid(fnActive ? (fnHid ?? hid) : hid, 1)
        case .upDownStack:
            break
        }
    }

    private func keyUp(_ spec: KeySpec) {
        guard case .regular(let hid, _, _, let fnHid, _) = spec.role else { return }
        henge_vm_key_hid(fnActive ? (fnHid ?? hid) : hid, 0)
        StickyKeys.shared.releaseAll()
    }

    private func perform(_ action: FunctionAction) {
        switch action {
        case .escape: tap(HID.escape)
        case .brightnessDown: brightness = max(0.4, brightness - 0.1)
        case .brightnessUp: brightness = min(1.0, brightness + 0.1)
        case .missionControl: chord([HID.control], HID.up)
        case .spotlight: chord([HID.command], HID.space)
        case .dictation: tap(HID.f5)
        case .doNotDisturb: tap(HID.f6)
        case .rewind: tap(HID.f7)
        case .playPause: tap(HID.f8)
        case .fastForward: tap(HID.f9)
        case .mute: tap(HID.mute)
        case .volumeDown: tap(HID.volumeDown)
        case .volumeUp: tap(HID.volumeUp)
        case .touchID: chord([HID.control, HID.command], HID.q)
        }
    }
}

// MARK: - ↑ and ↓, half height, stacked

private struct ArrowStack: View {
    let fnActive: Bool
    let alt: Bool
    let press: (Bool) -> Void
    @State private var upDown = false
    @State private var downDown = false

    var body: some View {
        GeometryReader { g in
            let h = max(8, (g.size.height - 2) / 2)
            VStack(spacing: 2) {
                half(up: true, pressed: $upDown).frame(height: h)
                half(up: false, pressed: $downDown).frame(height: h)
            }
        }
    }

    private func half(up: Bool, pressed: Binding<Bool>) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(alt ? (pressed.wrappedValue ? AltColor.keyDown : AltColor.key)
                          : (pressed.wrappedValue ? DeckColor.arrowDown : DeckColor.arrow))
            Image(systemName: up ? "chevron.up" : "chevron.down")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(alt ? AltColor.legend : Color.white.opacity(0.9))
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if !pressed.wrappedValue { pressed.wrappedValue = true; press(up) }
            }
            .onEnded { _ in pressed.wrappedValue = false })
        .accessibilityLabel(up ? (fnActive ? "page up" : "up arrow") : (fnActive ? "page down" : "down arrow"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - A key

private struct Keycap: View {
    let spec: KeySpec
    let functionRow: Bool
    let shift: Bool
    let lit: Bool
    let fnActive: Bool
    let alt: Bool
    let down: () -> Void
    let up: () -> Void

    /// Held keys stay down on the Mac until let go, so macOS repeats them itself, as with any USB keyboard.
    @State private var pressed = false

    var body: some View {
        let radius: CGFloat = functionRow ? 4 : 6
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(alt ? (pressed ? AltColor.keyDown : lit ? AltColor.keyLatched : AltColor.key)
                          : (pressed ? DeckColor.keyDown : lit ? DeckColor.keyLatched : DeckColor.key))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(alt ? 0 : pressed || lit ? 0.35 : 0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(pressed ? 0.1 : alt ? 0.45 : 0.5), radius: pressed ? 0.3 : alt ? 1 : 0.8,
                        y: pressed ? 0 : alt ? 1 : 0.8)
            legend
            if lit {
                VStack { HStack { Circle().fill(Color.green).frame(width: 3.4, height: 3.4)
                        .shadow(color: .green.opacity(0.8), radius: 2); Spacer() }; Spacer() }
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(pressed ? 0.96 : 1)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressed else { return }
                pressed = true
                down()
            }
            .onEnded { _ in
                guard pressed else { return }
                pressed = false
                up()
            })
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityName: String {
        switch spec.role {
        case .function(_, _, let symbol, let text): return text ?? symbol ?? ""
        case .regular(_, let primary, _, _, _): return primary
        case .modifier(_, _, let name): return name
        case .capsLock: return "caps lock"
        case .fnGlobe: return "fn"
        case .upDownStack: return "arrows"
        }
    }

    @ViewBuilder private var legend: some View {
        let fg = DeckColor.legend
        switch spec.role {
        case .function(_, let fnHid, let symbol, let text):
            if fnActive, let fnHid {
                Text("F\(Int(fnHid) - 0x39)").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(fg)
            } else if let text {
                Text(text).font(.system(size: 8.5, weight: .medium)).foregroundStyle(fg)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .medium)).foregroundStyle(fg)
            }
        case .capsLock:
            corner("caps lock", fg)
        case .fnGlobe:
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: "globe").font(.system(size: 8.5)).foregroundStyle(fg)
                Spacer(minLength: 0)
                Text("fn").font(.system(size: 8, weight: .medium)).foregroundStyle(fg)
            }
            .padding(3.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .modifier(_, let symbol, let name):
            if name == "shift" {
                corner("⇧ shift", fg)
            } else {
                VStack(spacing: 0) {
                    Text(symbol).font(.system(size: 9)).foregroundStyle(fg)
                    Text(name).font(.system(size: 7, weight: .medium)).foregroundStyle(fg).lineLimit(1).minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 2)
            }
        case .regular(_, let primary, let shifted, _, let fnLabel):
            if fnActive, let fnLabel {
                Text(fnLabel).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(fg)
            } else if primary == "space" {
                EmptyView()
            } else if primary == "←" || primary == "→" {
                Image(systemName: primary == "←" ? "chevron.left" : "chevron.right")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(fg)
            } else if primary.count > 1 {
                corner(primary, fg)
            } else if let shifted {
                // Symbol over digit or sign, both small, as on a MacBook.
                VStack(spacing: 0) {
                    Text(shifted).font(.system(size: 7)).foregroundStyle(shift ? fg : alt ? fg.opacity(0.7) : DeckColor.dim)
                    Text(primary).font(.system(size: 10, weight: .medium)).foregroundStyle(shift && !alt ? DeckColor.dim : fg)
                }
            } else {
                Text(primary.uppercased()).font(.system(size: 11, weight: .medium)).foregroundStyle(fg)
            }
        case .upDownStack:
            EmptyView()
        }
    }

    /// A word in the key's bottom corner, as a Mac's wide keys have them.
    private func corner(_ word: String, _ fg: Color) -> some View {
        let right = word == "delete" || word == "return"
        return Text(word)
            .font(.system(size: 7.5, weight: .medium))
            .foregroundStyle(fg)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(3.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: right ? .bottomTrailing : .bottomLeading)
    }
}
