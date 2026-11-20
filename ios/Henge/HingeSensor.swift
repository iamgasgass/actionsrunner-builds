// SPDX-License-Identifier: GPL-2.0-or-later
//
// Henge X: the iPhone Duo's hinge, as WindowsiOS X reads it (its HingeSensorView.swift). Folded partly
// open, like a laptop, the session turns upright so the fold runs between the Mac's screen and the deck
// (Laptop); opened flat, it leaves the orientation to the device (on its side: Studio).
//
// UIHingeInteraction is only in the iOS 27.1 SDK. ios/scripts/package_ipa.sh adds HENGEX_HINGE when the
// SDK type-checks a probe that uses it; with an older SDK this compiles to nothing and every device takes
// its layout from its orientation alone.
import SwiftUI
import UIKit

/// The Duo's model identifier: the only iPhone with a hinge sensor.
enum Hinge {
    static var present: Bool { HengeLog.deviceModel == "iPhone19,4" }
}

/// An invisible view that reports the hinge: its status (0 unknown, 1 closed, 2 partly open, 3 fully open)
/// and its angle in degrees, when the sensor gives one.
struct HingeSensorView: UIViewRepresentable {
    var onUpdate: (Int, Double?) -> Void

    func makeUIView(context: Context) -> Sensor {
        let view = Sensor()
        view.onUpdate = onUpdate
        return view
    }

    func updateUIView(_ view: Sensor, context: Context) { view.onUpdate = onUpdate }

    final class Sensor: UIView {
        var onUpdate: ((Int, Double?) -> Void)?
        private var installed = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) { fatalError("made in code") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !installed, Hinge.present, NSClassFromString("UIHingeInteraction") != nil else { return }
            installed = true
            #if HENGEX_HINGE
            if #available(iOS 27.1, *) {
                addInteraction(UIHingeInteraction { [weak self] _, update in
                    guard let hinge = update.hinge else { self?.onUpdate?(0, nil); return }
                    self?.onUpdate?(hinge.status.rawValue, Double(hinge.angle) * 180 / .pi)
                })
                HengeLog.log("hinge", "UIHingeInteraction installed")
            }
            #endif
        }
    }
}

/// What the hinge asks of the session: Laptop when it is folded like one (partly open, or between 30° and
/// 166°, WindowsiOS X's thresholds), otherwise nothing.
enum HingePosture {
    static func wantsLaptop(status: Int, degrees: Double?) -> Bool {
        if status == 2 { return true }
        if let degrees, degrees >= 30, degrees <= 166 { return true }
        return false
    }
}
