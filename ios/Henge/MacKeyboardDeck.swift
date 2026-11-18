// SPDX-License-Identifier: GPL-2.0-or-later
//
// macOSiOS X: the laptop deck. WindowsiOS X put a Surface Laptop's keyboard and touchpad under Windows'
// screen (its LaptopDeckView.swift); here the same deck is a MacBook's: a Magic Keyboard with the Mac's
// layout (fn/globe, control, option, command, the Mac's function row) and a Force Touch trackpad below it.
// The trackpad is macOSiOS X's own Trackpad, which the engine presents to macOS as a Magic Trackpad 2, so
// macOS's gestures work on it. Keys go to the Mac as USB HID usages (henge_vm_key_hid); control, option,
// command and shift latch through StickyKeys, so one finger makes a shortcut and ⌘-click works.
import SwiftUI
import UIKit

/// What the deck under the Mac's screen shows, upright. F10 or the toolbar's deck button cycles it.
enum DeckLayout: String, CaseIterable {
    case laptop     // keyboard above, trackpad below: a MacBook
    case trackpad   // the whole deck is a trackpad, with click buttons
    case keyboard   // the whole deck is the keyboard

    static let key = "macosiosx.deck.layout"

    var next: DeckLayout {
        switch self {
        case .laptop: return .trackpad
        case .trackpad: return .keyboard
        case .keyboard: return .laptop
        }
    }

    var title: String {
        switch self {
        case .laptop: return "Laptop"
        case .trackpad: return "Trackpad"
        case .keyboard: return "Keyboard"
        }
    }

    var symbol: String {
        switch self {
        case .laptop: return "laptopcomputer"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .keyboard: return "keyboard"
        }
    }
}

/// Turns the scene, even with the device's orientation lock on: Studio is the Mac on its side, full screen;
/// Laptop is upright, the Mac above the deck. As WindowsiOS X's SceneOrientationController.
@MainActor
enum SceneOrientation {
    static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    /// Studio: the Mac full screen, on its side.
    static func studio() { request(.landscapeRight) }

    /// Laptop: upright, the Mac's screen above the keyboard and trackpad.
    static func laptop() { request(.portrait) }

    /// The next orientation round the device: portrait, landscape right, landscape left.
    static func rotate() {
        guard let scene = activeScene() else { return }
        switch scene.interfaceOrientation {
        case .portrait, .portraitUpsideDown: request(.landscapeRight)
        case .landscapeRight: request(.landscapeLeft)
        default: request(.portrait)
        }
    }

    private static func request(_ mask: UIInterfaceOrientationMask) {
        guard let scene = activeScene() else { return }
        // A request, not a lock: turning the device afterwards turns the scene as usual.
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            HengeLog.log("deck", "orientation request refused: \(error.localizedDescription)")
        }
    }
}

// MARK: - The keyboard's model

private enum FunctionAction: Equatable {
    case escape
    case spotlight
    case finder
    case safari
    case terminal
    case missionControl
    case showDesktop
    case appSwitcher
    case screenshot
    case dragLock
    case cycleDeck
    case rotate
    case studio
    case forwardDelete
}

private enum KeyRole: Equatable {
    case functionKey(action: FunctionAction, fnHid: UInt8?, fnTag: String?, symbol: String?, text: String?)
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

    static func fn(_ id: String, _ action: FunctionAction, fnHid: UInt8? = nil, tag: String? = nil,
                   symbol: String? = nil, text: String? = nil, w: CGFloat = 1.0) -> KeySpec {
        KeySpec(id: id, widthWeight: w, role: .functionKey(action: action, fnHid: fnHid, fnTag: tag, symbol: symbol, text: text))
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
    static let a: UInt8 = 0x04, d: UInt8 = 0x07, five: UInt8 = 0x22
    static let returnKey: UInt8 = 0x28, escape: UInt8 = 0x29, delete: UInt8 = 0x2a, tab: UInt8 = 0x2b, space: UInt8 = 0x2c
    static let capsLock: UInt8 = 0x39, f11: UInt8 = 0x44, forwardDelete: UInt8 = 0x4c
    static let right: UInt8 = 0x4f, left: UInt8 = 0x50, down: UInt8 = 0x51, up: UInt8 = 0x52
    static let home: UInt8 = 0x4a, pageUp: UInt8 = 0x4b, end: UInt8 = 0x4d, pageDown: UInt8 = 0x4e
    static let control: UInt8 = 0xe0, shift: UInt8 = 0xe1, option: UInt8 = 0xe2, command: UInt8 = 0xe3
}

// MARK: - The deck

/// The lower half of a MacBook, under the Mac's screen: keyboard and trackpad, as the layout says.
struct MacKeyboardDeck: View {
    @Binding var layout: DeckLayout

    @ObservedObject private var sticky = StickyKeys.shared
    @State private var capsLocked = false
    @State private var fnActive = false
    @State private var dragLocked = false

    private let keyDownHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let keyUpHaptic = UIImpactFeedbackGenerator(style: .soft)

    init(layout: Binding<DeckLayout>) { _layout = layout }

    // The function row, MacBook height (about two thirds of a key). Tapped alone each key does what its
    // picture says on the Mac; with fn on it sends F1–F12, as a Mac keyboard does.
    private static let functionRow: [KeySpec] = [
        .fn("esc", .escape, text: "esc", w: 1.4),
        .fn("f1", .spotlight, fnHid: 0x3a, tag: "F1", symbol: "magnifyingglass"),
        .fn("f2", .finder, fnHid: 0x3b, tag: "F2", symbol: "folder"),
        .fn("f3", .safari, fnHid: 0x3c, tag: "F3", symbol: "safari"),
        .fn("f4", .terminal, fnHid: 0x3d, tag: "F4", symbol: "terminal"),
        .fn("f5", .missionControl, fnHid: 0x3e, tag: "F5", symbol: "rectangle.3.group"),
        .fn("f6", .showDesktop, fnHid: 0x3f, tag: "F6", symbol: "menubar.dock.rectangle"),
        .fn("f7", .appSwitcher, fnHid: 0x40, tag: "F7", symbol: "square.on.square"),
        .fn("f8", .screenshot, fnHid: 0x41, tag: "F8", symbol: "camera.viewfinder"),
        .fn("f9", .dragLock, fnHid: 0x42, tag: "F9", symbol: "hand.draw"),
        .fn("f10", .cycleDeck, fnHid: 0x43, tag: "F10", symbol: "rectangle.split.1x2"),
        .fn("f11", .rotate, fnHid: 0x44, tag: "F11", symbol: "rotate.right"),
        .fn("f12", .studio, fnHid: 0x45, tag: "F12", symbol: "arrow.up.left.and.arrow.down.right"),
        .fn("fwddel", .forwardDelete, symbol: "delete.right", w: 1.1),
    ]

    // The MacBook's ANSI (U.S.) layout. macOS reads the keys by position, so another layout chosen in
    // macOS's settings types its own characters from the same keys.
    private static let mainRows: [[KeySpec]] = [
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
            .key("q", shifted: "Q", hid: 0x14), .key("w", shifted: "W", hid: 0x1a), .key("e", shifted: "E", hid: 0x08),
            .key("r", shifted: "R", hid: 0x15), .key("t", shifted: "T", hid: 0x17), .key("y", shifted: "Y", hid: 0x1c),
            .key("u", shifted: "U", hid: 0x18), .key("i", shifted: "I", hid: 0x0c), .key("o", shifted: "O", hid: 0x12),
            .key("p", shifted: "P", hid: 0x13), .key("[", shifted: "{", hid: 0x2f), .key("]", shifted: "}", hid: 0x30),
            .key("\\", shifted: "|", hid: 0x31),
        ],
        [
            KeySpec(id: "caps", widthWeight: 1.8, role: .capsLock),
            .key("a", shifted: "A", hid: 0x04), .key("s", shifted: "S", hid: 0x16), .key("d", shifted: "D", hid: 0x07),
            .key("f", shifted: "F", hid: 0x09), .key("g", shifted: "G", hid: 0x0a), .key("h", shifted: "H", hid: 0x0b),
            .key("j", shifted: "J", hid: 0x0d), .key("k", shifted: "K", hid: 0x0e), .key("l", shifted: "L", hid: 0x0f),
            .key(";", shifted: ":", hid: 0x33), .key("'", shifted: "\"", hid: 0x34),
            .key("return", hid: HID.returnKey, w: 1.8),
        ],
        [
            .mod("lshift", Keys.shift, "⇧", "shift", w: 2.35),
            .key("z", shifted: "Z", hid: 0x1d), .key("x", shifted: "X", hid: 0x1b), .key("c", shifted: "C", hid: 0x06),
            .key("v", shifted: "V", hid: 0x19), .key("b", shifted: "B", hid: 0x05), .key("n", shifted: "N", hid: 0x11),
            .key("m", shifted: "M", hid: 0x10), .key(",", shifted: "<", hid: 0x36), .key(".", shifted: ">", hid: 0x37),
            .key("/", shifted: "?", hid: 0x38),
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

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .top) {
                aluminium
                VStack(spacing: 8) {
                    switch layout {
                    case .laptop:
                        let keyboardH = max(150, min(h * 0.62, (w - 20) * 0.62))
                        keyboardWell(height: keyboardH)
                            .frame(height: keyboardH)
                            .padding(.horizontal, 8)
                        trackpad(width: min(w - 24, max(w * 0.62, 240)), height: max(h - keyboardH - 26, 60))
                    case .trackpad:
                        trackpad(width: w - 20, height: max(h - 66, 60))
                        clickButtons.frame(height: 44).padding(.horizontal, 10)
                    case .keyboard:
                        keyboardWell(height: h - 18)
                            .frame(height: h - 18)
                            .padding(.horizontal, 8)
                    }
                }
                .padding(.top, 9)
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .onDisappear {
            if dragLocked { henge_vm_mouse_button(0, 0); dragLocked = false }
        }
    }

    // MARK: Surface

    /// A MacBook's space grey aluminium, with the light from above.
    private var aluminium: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.20, green: 0.205, blue: 0.22),
                                    Color(red: 0.15, green: 0.155, blue: 0.17),
                                    Color(red: 0.11, green: 0.115, blue: 0.125)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color.white.opacity(0.07), .clear], center: .init(x: 0.5, y: 0.05),
                           startRadius: 10, endRadius: 360)
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.7)
        }
    }

    private func keyboardWell(height: CGFloat) -> some View {
        let spacing: CGFloat = 3.5
        let pad: CGFloat = 5
        let rowsH = max(110, height - pad * 2 - spacing * 5)
        let unit = rowsH / 5.66 // the function row is two thirds of a key's height
        return VStack(spacing: spacing) {
            row(Self.functionRow, height: unit * 0.66, functionRow: true).frame(height: unit * 0.66)
            ForEach(0..<Self.mainRows.count, id: \.self) { i in
                row(Self.mainRows[i], height: unit, functionRow: false).frame(height: unit)
            }
        }
        .padding(pad)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.55)))
    }

    private func row(_ keys: [KeySpec], height: CGFloat, functionRow: Bool) -> some View {
        GeometryReader { g in
            let total = keys.reduce(CGFloat(0)) { $0 + $1.widthWeight }
            let spacing: CGFloat = 3.5
            let avail = max(10, g.size.width - spacing * CGFloat(keys.count - 1))
            HStack(spacing: spacing) {
                ForEach(keys) { spec in
                    let kw = avail * spec.widthWeight / total
                    if spec.role == .upDownStack {
                        ArrowStack(fnActive: fnActive) { up in
                            keyDownHaptic.impactOccurred(intensity: 0.68)
                            tap(up ? (fnActive ? HID.pageUp : HID.up) : (fnActive ? HID.pageDown : HID.down))
                        }
                        .frame(width: kw, height: height)
                    } else {
                        Keycap(spec: spec, functionRow: functionRow, shift: sticky.down.contains(Keys.shift) || capsLocked,
                               lit: lit(spec), fnActive: fnActive,
                               down: { keyDown(spec) }, up: { keyUp(spec) })
                        .frame(width: kw, height: height)
                    }
                }
            }
        }
    }

    private func trackpad(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.17, green: 0.175, blue: 0.19), Color(red: 0.14, green: 0.145, blue: 0.16)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(dragLocked ? 0.45 : 0.12), lineWidth: dragLocked ? 1 : 0.6)
            if dragLocked {
                Label("Drag lock: F9 lets go", systemImage: "hand.draw")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .allowsHitTesting(false)
            }
            Trackpad()
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var clickButtons: some View {
        HStack(spacing: 0) {
            MouseButton(title: "Click", button: 0)
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 0.5)
            MouseButton(title: "Right-click", button: 1)
        }
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Keys

    private func lit(_ spec: KeySpec) -> Bool {
        switch spec.role {
        case .capsLock: return capsLocked
        case .fnGlobe: return fnActive
        case .modifier(let code, _, _): return sticky.down.contains(code)
        case .functionKey(let action, _, _, _, _):
            switch action {
            case .dragLock: return dragLocked
            case .cycleDeck: return layout != .laptop
            default: return false
            }
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

    /// Opens an app the way a Mac user does without a mouse: Spotlight, its name, return.
    private func launch(_ app: String) {
        chord([HID.command], HID.space)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            await Keys.typeSlowly(app)
            try? await Task.sleep(nanoseconds: 350_000_000)
            henge_vm_key_hid(HID.returnKey, 1)
            henge_vm_key_hid(HID.returnKey, 0)
        }
    }

    private func keyDown(_ spec: KeySpec) {
        keyDownHaptic.impactOccurred(intensity: 0.7)
        switch spec.role {
        case .capsLock:
            capsLocked.toggle()
            henge_vm_key_hid(HID.capsLock, 1)
            henge_vm_key_hid(HID.capsLock, 0)
        case .fnGlobe:
            fnActive.toggle()
        case .modifier(let code, _, _):
            StickyKeys.shared.toggle(code)
        case .functionKey(let action, let fnHid, _, _, _):
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
        keyUpHaptic.impactOccurred(intensity: 0.22)
        henge_vm_key_hid(fnActive ? (fnHid ?? hid) : hid, 0)
        StickyKeys.shared.releaseAll()
    }

    private func perform(_ action: FunctionAction) {
        switch action {
        case .escape: tap(HID.escape)
        case .spotlight: chord([HID.command], HID.space)                 // ⌘Space
        case .finder: launch("Finder")
        case .safari: launch("Safari")
        case .terminal: launch("Terminal")
        case .missionControl: chord([HID.control], HID.up)              // ⌃↑
        case .showDesktop: tap(HID.f11)                                 // F11, macOS's default for Show Desktop
        case .appSwitcher: chord([HID.command], HID.tab)                // ⌘Tab: back to the last app
        case .screenshot: chord([HID.command, HID.shift], HID.five)     // ⌘⇧5: the screenshot toolbar
        case .dragLock:
            dragLocked.toggle()
            henge_vm_mouse_button(0, dragLocked ? 1 : 0)
        case .cycleDeck:
            withAnimation(.snappy(duration: 0.2)) { layout = layout.next }
        case .rotate: SceneOrientation.rotate()
        case .studio: SceneOrientation.studio()
        case .forwardDelete: tap(HID.forwardDelete)
        }
    }
}

// MARK: - ↑ and ↓, half height, stacked

private struct ArrowStack: View {
    let fnActive: Bool
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
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(pressed.wrappedValue ? Color(white: 0.32) : Color(white: 0.09))
            Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(.system(size: 6.5))
                .foregroundStyle(Color.white.opacity(0.9))
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

// MARK: - A Magic Keyboard key

private struct Keycap: View {
    let spec: KeySpec
    let functionRow: Bool
    let shift: Bool
    let lit: Bool
    let fnActive: Bool
    let down: () -> Void
    let up: () -> Void

    /// Held keys stay down on the Mac until let go, so macOS repeats them itself, as with any USB keyboard.
    @State private var pressed = false

    var body: some View {
        let radius: CGFloat = functionRow ? 3.5 : 5
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(pressed ? Color(white: 0.30) : lit ? Color(white: 0.20) : Color(white: 0.085))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(pressed || lit ? 0.35 : 0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(pressed ? 0.1 : 0.5), radius: pressed ? 0.3 : 0.8, y: pressed ? 0 : 0.8)
            legend
            if lit && showsLight {
                // The caps lock key's green light, and the same for whatever is latched.
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

    private var showsLight: Bool {
        switch spec.role {
        case .capsLock, .fnGlobe, .modifier: return true
        case .functionKey(let action, _, _, _, _): return action == .dragLock || action == .cycleDeck
        default: return false
        }
    }

    private var accessibilityName: String {
        switch spec.role {
        case .functionKey(_, _, let tag, let symbol, let text): return fnActive ? (tag ?? text ?? "") : (text ?? symbol ?? tag ?? "")
        case .regular(_, let primary, _, _, _): return primary
        case .modifier(_, _, let name): return name
        case .capsLock: return "caps lock"
        case .fnGlobe: return "fn"
        case .upDownStack: return "arrows"
        }
    }

    @ViewBuilder private var legend: some View {
        let fg = Color.white.opacity(0.92)
        let dim = Color.white.opacity(0.55)
        switch spec.role {
        case .functionKey(_, _, let tag, let symbol, let text):
            if fnActive, let tag {
                Text(tag).font(.system(size: 9, weight: .semibold)).foregroundStyle(fg)
            } else if let text {
                Text(text).font(.system(size: 9, weight: .medium)).foregroundStyle(fg)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .medium)).foregroundStyle(fg)
            }
        case .capsLock:
            corner("caps lock", fg)
        case .fnGlobe:
            VStack(alignment: .leading, spacing: 0) {
                Text("fn").font(.system(size: 8.5, weight: .medium)).foregroundStyle(fg)
                Spacer(minLength: 0)
                Image(systemName: "globe").font(.system(size: 8.5)).foregroundStyle(fg)
            }
            .padding(3.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .modifier(_, let symbol, let name):
            VStack(alignment: .trailing, spacing: 0) {
                Text(symbol).font(.system(size: 9.5)).foregroundStyle(fg)
                Spacer(minLength: 0)
                Text(name).font(.system(size: 7.5, weight: .medium)).foregroundStyle(fg).lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(3.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: name == "shift" ? .leading : .trailing)
        case .regular(_, let primary, let shifted, _, let fnLabel):
            if fnActive, let fnLabel {
                Text(fnLabel).font(.system(size: 9, weight: .semibold)).foregroundStyle(fg)
            } else if primary == "space" {
                EmptyView()
            } else if primary == "←" || primary == "→" {
                Image(systemName: primary == "←" ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 6.5)).foregroundStyle(fg)
            } else if primary.count > 1 {
                corner(primary, fg)
            } else if let shifted, shifted.uppercased() != primary.uppercased() {
                VStack(spacing: 0) {
                    Text(shifted).font(.system(size: 7.5)).foregroundStyle(shift ? fg : dim)
                    Text(primary).font(.system(size: 10.5, weight: .medium)).foregroundStyle(shift ? dim : fg)
                }
            } else {
                // Mac keycaps print letters in capitals.
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
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(fg)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(3.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: right ? .bottomTrailing : .bottomLeading)
    }
}
