// SPDX-License-Identifier: GPL-2.0-or-later

#if TIP_JAR

import AndariumCore
import AndariumCoreTestSupport
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import Andarium

/// The sender line of Buy me tokens: a circular avatar, the developer's name and role, and a logo
/// button for each profile. The values here are the arrangement's placeholders (`example`) and
/// images drawn in the test; the maker's own are local to an AppStore build.
@MainActor
@Suite(.serialized)
struct TipJarHeaderTests {
    /// The sites the build gives a button: the header's X button exists only where the build names
    /// a handle for it (`SHEET_X`).
    private static var sites: [TipJarSenderContent.Link.Site] {
        #if SHEET_X
        [.github, .x]
        #else
        [.github]
        #endif
    }

    private static func drawn() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 20)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 2, y: 2, width: 20, height: 16))
        }
    }

    private static func content(
        name: String? = "example", github: String? = "example", x: String? = "example_x",
        avatar: Bool = true, githubLogo: Bool = true, xLogo: Bool = true
    ) -> TipJarSenderContent {
        TipJarSenderContent(
            developer: TipJarDeveloper(name: name, githubHandle: github, xHandle: x),
            avatar: avatar ? drawn() : nil, githubLogo: githubLogo ? drawn() : nil, xLogo: xLogo ? drawn() : nil)
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    // MARK: What the header holds

    @Test func theArtworkMakesTheWholeHeader() throws {
        let header = Self.content()
        #expect(header.name == "example")
        #expect(header.avatar != nil)
        #expect(header.links.map(\.site) == Self.sites)
        let addresses = ["github": "https://github.com/example", "x": "https://x.com/example_x"]
        #expect(header.links.map(\.url.absoluteString) == header.links.map { addresses[$0.site.rawValue]! })
        #expect(header.links.map(\.name) == header.links.map { $0.site == .github ? "GitHub" : "X" },
                "the brands' names, whatever the language")
        for link in header.links {
            #expect(link.logo.renderingMode == .alwaysTemplate, "\(link.name) takes the text's colour")
            #expect(link.aspectRatio == 1.2, "\(link.name) keeps the logo's proportions")
        }
    }

    /// Each piece follows what exists: no avatar keeps the mark, no name reads the role alone, and a
    /// logo button needs its handle and its logo.
    @Test func eachPieceFollowsWhatExists() {
        let role = String(localized: TipJarWords.sender)
        let anonymous = TipJarSenderContent()
        #expect(anonymous.avatar == nil && anonymous.links.isEmpty && anonymous.name == nil)
        #expect(anonymous.line == role && anonymous.spokenLine == role)
        let named = Self.content(github: nil, x: nil)
        #expect(named.line == "example \u{00B7} \(role)" && named.spokenLine == "example, \(role)")
        #expect(named.links.isEmpty)
        #expect(Self.content(avatar: false).avatar == nil)
        #expect(Self.content(name: nil).line == role)
        #expect(Self.content(githubLogo: false).links.map(\.site) == Self.sites.filter { $0 != .github }, "no logo, no button")
        #expect(Self.content(github: nil).links.map(\.site) == Self.sites.filter { $0 != .github }, "no handle, no button")
        #expect(Self.content(github: nil, xLogo: false).links.isEmpty)
        // A handle that is no account name builds no address.
        #expect(Self.content(github: "-bad", x: "way_too_long_for_an_x_account").links.isEmpty)
        #expect(Self.content(github: "a/b", x: "a b").links.isEmpty)
    }

    /// The build's own values and assets: whatever Info.plist and the product hold, no more.
    @Test func theLiveHeaderHoldsExactlyWhatTheBuildHolds() {
        typealias Configuration = TipJarDeveloperConfiguration
        let live = TipJarSenderContent.live
        func key(_ name: String) -> String? { Bundle.main.object(forInfoDictionaryKey: name) as? String }
        #expect(live.name == key(Configuration.nameKey))
        #expect((live.avatar != nil) == (UIImage(named: Configuration.avatarAsset) != nil))
        #expect((live.avatar != nil) == (key(Configuration.nameKey) != nil), "the avatar comes with the name")
        #expect(live.links.contains { $0.site == .github } == (key(Configuration.githubKey) != nil && UIImage(named: Configuration.githubAsset) != nil))
        #expect(live.links.contains { $0.site == .github } == (key(Configuration.githubKey) != nil), "the mark comes with the handle")
        #if SHEET_X
        #expect(live.links.contains { $0.site == .x } == (key(Configuration.xKey) != nil && UIImage(named: Configuration.xAsset) != nil))
        #else
        #expect(!live.links.contains { $0.site == .x }, "no X button without a handle of its own")
        #expect(key(Configuration.xKey) == nil)
        #endif
        // The arrangement states all three placeholders and takes the drawn artwork.
        if key(Configuration.nameKey) == "example" {
            #expect(live.name == "example" && live.avatar != nil)
            #expect(live.links.map(\.url.absoluteString).first == "https://github.com/example")
        }
    }

    // MARK: The sheet

    private func app() -> AppModel {
        let host = HostDevice(
            name: "iPhone", processorCount: 6, memory: MemoryPolicy(maximumsMiB: [4096]), freeStorageBytes: 40_000_000_000
        )
        let model = AppModel(
            guest: Guest.fresh(on: host), host: host,
            system: SystemInfo(version: "17", release: "r2", kernel: "Linux 6.18", architecture: "arm64, 4 KiB pages", appVersion: "1"),
            capabilities: .device, createRequirementBytes: 1
        )
        model.launchApplied = true
        model.driver = StubDriver(plan: .normal)
        model.phase = .home
        model.tipJarServices.products = { TipJarProductsFixture.arranged }
        model.tipJarServices.store = TipJarStoreServices(
            canMakePayments: { true },
            products: { ids in ids.map { TipJarProduct(identifier: $0, displayPrice: "$1.00") } },
            purchase: { _ in .cancelled },
            transactions: { AsyncStream { $0.finish() } })
        return model
    }

    /// Opens the real sheet over Home and returns what VoiceOver finds in it.
    private func openSheet(_ model: AppModel, lease: HostWindow.Lease) async throws -> (UIViewController, [ToolbarProbe.Element]) {
        let controller = AndariumHostingController(
            rootView: RootView(entry: AppEntry(overrides: LaunchOverrides())).environment(model), model: model)
        lease.window.rootViewController = controller
        try #require(await eventually { controller.viewIfLoaded?.window != nil })
        model.tipJarSheetOpen = true
        try #require(await eventually { controller.presentedViewController?.view.window != nil })
        try await Task.sleep(for: .seconds(1.5))
        return (controller, ToolbarProbe.elements(in: lease.window, above: 5000, includeUnlabelled: true))
    }

    /// One sender element, read once before the messages, with the role in it; each logo its own
    /// link; the avatar nowhere in the accessibility tree.
    @Test func voiceOverReadsTheSenderOnceAndFindsTheLinks() async throws {
        let model = app()
        var opened: [URL] = []
        model.tipJarServices.sender = { Self.content() }
        model.tipJarServices.openLink = { opened.append($0); return .handled }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let (controller, elements) = try await openSheet(model, lease: lease)
        let sheetView = controller.presentedViewController?.view
        let role = String(localized: TipJarWords.sender)
        let sender = elements.filter { $0.label == "example, \(role)" }
        try #require(sender.count == 1, "one sender element: \(elements.map(\.description))")
        #expect(sender[0].traits.contains(.header))
        // Before the first bubble.
        let bubble = String(localized: TipJarWords.coffee)
        let first = try #require(elements.first { $0.label == bubble || $0.label.hasPrefix(String(bubble.prefix(12))) })
        #expect(sender[0].top < first.top, "the sender comes before the messages")
        // No element without a label in the header's band: the avatar is decorative. (A control of Home
        // behind a form sheet is not the sheet's.)
        func inSheet(_ element: ToolbarProbe.Element) -> Bool {
            guard let view = element.object as? UIView, let sheetView else { return true }
            return view.isDescendant(of: sheetView)
        }
        let band = elements.filter { $0.label.isEmpty && abs($0.top - sender[0].top) < 40 && inSheet($0) }
        #expect(band.isEmpty, "unlabelled elements by the sender: \(band.map(\.description))")
        // Each link its own element with the link trait, labelled with the brand.
        let brands = Self.sites.map { $0 == .github ? "GitHub" : "X" }
        let links = elements.filter { $0.traits.contains(.link) }
        #expect(links.map(\.label).sorted() == brands.sorted(), "\(elements.map(\.description))")
        // A tap hands the profile to openURL, which the arrangement's seam sees.
        for name in brands {
            let link = try #require(links.first { $0.label == name })
            #expect(link.object.accessibilityActivate(), "\(name) activates")
        }
        #expect(await eventually { opened.count == brands.count })
        let addresses = ["GitHub": "https://github.com/example", "X": "https://x.com/example_x"]
        #expect(opened.map(\.absoluteString).sorted() == brands.map { addresses[$0]! }.sorted())
    }

    /// The link elements of a header drawn at a text size, in reading order, once there are `count`.
    private func linkTargets(of content: TipJarSenderContent, at size: DynamicTypeSize, count: Int) async throws -> [CGRect] {
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let controller = UIHostingController(
            rootView: TipJarSender(content: content)
                .dynamicTypeSize(size)
                .padding(16)
                .frame(width: 380)
                .frame(maxHeight: .infinity, alignment: .top))
        lease.window.rootViewController = controller
        var links: [CGRect] = []
        let drawn = await eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            links = ToolbarProbe.elements(in: lease.window, above: 5000, includeUnlabelled: true)
                .filter { $0.traits.contains(.link) }.map { $0.object.accessibilityFrame }
                .sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
            return links.count == count
        }
        try #require(drawn, "the logos were not drawn; is ApplicationAccessibilityEnabled on?")
        lease.window.rootViewController = nil
        return links
    }

    /// The logos are a touch target each, 44 pt tall, no larger than the target, and no two of them
    /// overlap.
    @Test func theLogosKeepTheirSizeAndTheirTargets() async throws {
        let links = try await linkTargets(of: Self.content(), at: .large, count: Self.sites.count)
        for frame in links {
            #expect(frame.width <= 48 && frame.height >= 43.5 && frame.height <= 48, "a logo's target: \(frame)")
        }
        for (first, second) in zip(links, links.dropFirst()) {
            #expect(!first.insetBy(dx: 0.5, dy: 0.5).intersects(second.insetBy(dx: 0.5, dy: 0.5)),
                    "two targets overlap: \(first) \(second)")
        }
    }

    /// A lone logo is a 44 pt square target (no neighbour shares its sides).
    @Test func aLoneLogoIsA44PointTarget() async throws {
        let links = try await linkTargets(of: Self.content(x: nil), at: .large, count: 1)
        let frame = try #require(links.first)
        #expect(frame.width >= 43.5 && frame.width <= 48 && frame.height >= 43.5 && frame.height <= 48,
                "the lone logo's target: \(frame)")
    }

    // MARK: The gaps

    /// A solid logo, so that its drawn edges are its frame's.
    private static func solid() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 24, height: 20)).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 20))
        }
    }

    /// The runs of columns (or rows) of `image` that hold a black pixel, in points, inside `area`.
    private static func inkRuns(in image: UIImage, area: CGRect, columns: Bool) -> [ClosedRange<CGFloat>] {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let scale = image.scale
        let perRow = cgImage.bytesPerRow
        let perPixel = cgImage.bitsPerPixel / 8
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let at = y * perRow + x * perPixel
            return bytes[at] < 48 && bytes[at + 1] < 48 && bytes[at + 2] < 48
        }
        let x0 = max(0, Int(area.minX * scale)), x1 = min(cgImage.width, Int(area.maxX * scale))
        let y0 = max(0, Int(area.minY * scale)), y1 = min(cgImage.height, Int(area.maxY * scale))
        guard x0 < x1, y0 < y1 else { return [] }
        let range = columns ? x0..<x1 : y0..<y1
        var runs: [ClosedRange<CGFloat>] = []
        var start: Int?
        for position in range {
            let hit = columns ? (y0..<y1).contains { isInk(position, $0) } : (x0..<x1).contains { isInk($0, position) }
            if hit, start == nil { start = position }
            if !hit, let from = start {
                runs.append(CGFloat(from) / scale ... CGFloat(position) / scale)
                start = nil
            }
        }
        if let from = start { runs.append(CGFloat(from) / scale ... CGFloat(range.upperBound) / scale) }
        return runs
    }

    /// The name, the GitHub mark and the X mark read as one tight group: the gap from the name to the
    /// first mark and between the marks is one inline gap (8 pt). The touch targets are 44 pt tall and
    /// do not space the glyphs.
    @Test func theNameAndTheMarksAreOneTightGroup() async throws {
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let developer = TipJarDeveloper(name: "example", githubHandle: "example", xHandle: "example_x")
        let content = TipJarSenderContent(
            developer: developer, avatar: nil, githubLogo: Self.solid(), xLogo: Self.solid())
        let controller = UIHostingController(
            rootView: TipJarSender(content: content)
                .dynamicTypeSize(.large)
                .padding(16)
                .frame(width: 380)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.white))
        controller.overrideUserInterfaceStyle = .light
        lease.window.rootViewController = controller
        var name: CGRect = .null
        let drawn = await eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let elements = ToolbarProbe.elements(in: lease.window, above: 5000, includeUnlabelled: true)
            // The developer's name, which is one element; the window can hold headers of its own.
            name = elements.first { $0.traits.contains(.header) && $0.label.hasPrefix("example") }?.object.accessibilityFrame ?? .null
            return !name.isNull && elements.filter { $0.traits.contains(.link) }.count == Self.sites.count
        }
        try #require(drawn, "the header was not drawn; is ApplicationAccessibilityEnabled on?")
        try await Task.sleep(for: .milliseconds(300))
        let view = controller.view!
        let line = try #require(view.window).screen.coordinateSpace.convert(name, to: view)
        // 8-bit sRGB, which `inkRuns` reads a byte to a component: an iPad app on a Mac is given 16-bit
        // floating-point pixels by default.
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        let picture = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        try #require(picture.cgImage?.bitsPerComponent == 8, "the picture is not 8 bits to a component")
        // The marks are the ink right of the name.
        let area = CGRect(x: line.maxX, y: line.minY - 12, width: view.bounds.width - line.maxX, height: line.height + 24)
        let marks = Self.inkRuns(in: picture, area: area, columns: true)
        try #require(marks.count == Self.sites.count, "the marks drawn: \(marks) in \(area), the name at \(line)")
        let gap = 8.0
        #expect(abs(marks[0].lowerBound - line.maxX - gap) <= 1.5, "the name to the first mark: \(marks[0].lowerBound - line.maxX) pt")
        for (first, second) in zip(marks, marks.dropFirst()) {
            #expect(abs(second.lowerBound - first.upperBound - gap) <= 1.5, "between the marks: \(second.lowerBound - first.upperBound) pt")
        }
    }

    // MARK: The close control

    /// Every view under `root` of the given type.
    private static func views<V: UIView>(of type: V.Type, under root: UIView) -> [V] {
        var found: [V] = []
        if let match = root as? V { found.append(match) }
        for child in root.subviews { found += views(of: type, under: child) }
        return found
    }

    /// The sheet closes with the system's close button: one control in the bar, a symbol and no text, that
    /// VoiceOver names with the system's word (not ours: the sheet's catalog has no word for it), and no
    /// "Done" in the bar. It closes the sheet.
    @Test func theSheetClosesWithTheSystemCloseButtonThatNamesItself() async throws {
        let model = app()
        model.tipJarServices.sender = { Self.content() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let (controller, elements) = try await openSheet(model, lease: lease)
        let sheet = try #require(controller.presentedViewController?.view, "the sheet")
        let bars = Self.views(of: UINavigationBar.self, under: sheet)
        try #require(bars.count == 1, "one bar in the sheet: \(bars)")
        // A bar button is two nested views: the outermost ones are the bar's buttons (the title, which
        // the sheet draws in the middle, is a control of the bar too, and no button).
        let controls = bars.flatMap { Self.views(of: UIControl.self, under: $0) }
            .filter { String(describing: type(of: $0)).contains("BarButton") }
        let outer = controls.filter { control in !controls.contains { $0 !== control && control.isDescendant(of: $0) } }
        try #require(outer.count == 1, "one button in the bar: \(controls)")
        let button = outer[0]
        let symbols = Self.views(of: UIImageView.self, under: button).compactMap(\.image).filter(\.isSymbolImage)
        #expect(!symbols.isEmpty, "the button draws a symbol: \(button.subviews)")
        let texts = Self.views(of: UILabel.self, under: button).compactMap(\.text).filter { !$0.isEmpty }
        #expect(texts.isEmpty, "the button draws no word: \(texts)")
        // The system names it: a word, and not the sheet's own Done.
        let done = String(localized: TipJarWords.done)
        let named = elements.filter { element in
            guard let view = element.object as? UIView else { return false }
            return element.traits.contains(.button) && (view === button || view.isDescendant(of: button))
        }
        try #require(!named.isEmpty, "VoiceOver finds the button: \(elements.map(\.description))")
        for element in named {
            #expect(!element.label.isEmpty && element.label != done, "VoiceOver says \(element.description)")
        }
        #expect(!elements.contains { $0.label == done }, "no Done in the sheet before a tip: \(elements.map(\.description))")
        // It closes the sheet.
        button.performPrimaryAction()
        #expect(await eventually { !model.tipJarSheetOpen })
    }

    /// The sheet takes the shared presentation: turned and bent, it rises to a little below the fold (its
    /// own detent, a height fitted to the conversation, gives way); in every other pose, flat, upright or
    /// on the cover, it keeps its own. The device here is a phone's window, and the shared presentation's
    /// height comes from the reading, so the sheet's height tells which presentation it has.
    @Test(arguments: [FoldSessionHostingTests.Pose.turnedBook, .turnedFlat, .uprightBook, .uprightFlat, .cover])
    func turnedAndBentTheSheetRisesToTheFoldAndElsewhereKeepsItsOwnHeight(_ pose: FoldSessionHostingTests.Pose) async throws {
        let model = app()
        model.tipJarServices.sender = { Self.content() }
        model.fold = pose.reading
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let host = UIHostingController(rootView: Color.clear.tipJarSheet(model).environment(model))
        lease.window.rootViewController = host
        try #require(await eventually { host.viewIfLoaded?.window != nil })
        model.tipJarSheetOpen = true
        try #require(await eventually { host.presentedViewController?.view.window != nil })
        try await Task.sleep(for: .seconds(1.5))
        let sheet = try #require(host.presentedViewController?.presentationController?.presentedView, "the sheet")
        // The detent is the height below the fold; the sheet's frame adds the system's margin to it.
        let below = FoldSheet.detentHeight(pose.reading)
        if let below {
            #expect(abs(sheet.frame.height - below) < 20, "\(pose): the sheet is \(sheet.frame.height) tall, not \(below)")
        } else {
            #expect(sheet.frame.height > 450, "\(pose): the sheet is \(sheet.frame.height) tall, its own height")
        }
        model.tipJarSheetOpen = false
        #expect(await eventually { host.presentedViewController == nil })
        lease.window.rootViewController = nil
    }

    /// A conversation shorter than the sheet stands at the top, under the title bar, and is neither
    /// centred nor pushed down to the bar of tiers. The sheet is the window's own view here, taller than
    /// its conversation.
    @Test func aConversationShorterThanTheSheetStandsAtTheTop() async throws {
        let model = app()
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let jar = try #require(model.makeTipJarModel())
        let controller = UIHostingController(
            rootView: TipJarSheet(jar: jar, sender: Self.content(), device: "iPhone") {}
                .environment(model))
        lease.window.rootViewController = controller
        try #require(await eventually { controller.viewIfLoaded?.window != nil })
        try await Task.sleep(for: .seconds(1.5))
        controller.view.layoutIfNeeded()
        let bar = try #require(Self.views(of: UINavigationBar.self, under: controller.view).first, "the title bar")
        let barBottom = bar.convert(bar.bounds, to: nil).maxY
        let elements = ToolbarProbe.elements(in: lease.window, above: 5000, includeUnlabelled: true)
        let role = String(localized: TipJarWords.sender)
        let header = try #require(elements.first { $0.label == "example, \(role)" }, "the sender: \(elements.map(\.description))")
        let chip = try #require(elements.first { $0.label.hasPrefix("Lite") }, "a tier: \(elements.map(\.description))")
        // The room between the title bar and the tiers is more than the conversation needs, or the
        // test says nothing.
        try #require(chip.top - barBottom > 380, "the sheet is \(chip.top - barBottom) pt tall above its tiers")
        #expect(header.top - barBottom < 30, "the conversation starts \(header.top - barBottom) pt under the title bar")
    }

    /// A conversation that fitted and the tip makes overflow follows its newest bubble: the thank-you
    /// stands above the Done button, not under it. The sheet is a small phone's window at a larger text
    /// size, where the conversation fills the sheet and the thank-you does not fit under it.
    @Test func aTipThatOverflowsTheSheetKeepsTheNewestBubbleAboveTheBar() async throws {
        let model = app()
        model.tipJarServices.store.purchase = { .purchased(TipJarTransaction(productIdentifier: $0) {}) }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let jar = try #require(model.makeTipJarModel())
        let controller = UIHostingController(
            rootView: TipJarSheet(jar: jar, sender: Self.content(), device: "iPhone") {}
                .environment(model)
                .dynamicTypeSize(.xLarge)
                .frame(width: 375, height: Self.smallPhoneSheet)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        lease.window.rootViewController = controller
        try #require(await eventually { controller.viewIfLoaded?.window != nil && jar.phase == .loaded })
        try await Task.sleep(for: .seconds(1.5))
        controller.view.layoutIfNeeded()
        // The conversation fits the sheet before the tip, and fills it past its end after the tip: or
        // the test says nothing.
        func scroll() throws -> UIScrollView {
            try #require(Self.views(of: UIScrollView.self, under: controller.view).max { $0.bounds.height < $1.bounds.height }, "the conversation")
        }
        func overflow() throws -> CGFloat {
            let scroll = try scroll()
            return scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom - scroll.bounds.height
        }
        let before = try overflow()
        try #require(before <= 1, "the conversation fills the sheet before the tip by \(before) pt")
        jar.purchase(.ultra)
        try #require(await eventually { jar.thanked })
        try await Task.sleep(for: .seconds(1.5))
        controller.view.layoutIfNeeded()
        let after = try overflow()
        try #require(after > 8, "the thank-you overflows the sheet by \(after) pt")
        let bar = try #require(Self.views(of: UINavigationBar.self, under: controller.view).first, "the title bar")
        let barBottom = bar.convert(bar.bounds, to: nil).maxY
        let elements = ToolbarProbe.elements(in: lease.window, above: 5000, includeUnlabelled: true)
        let thanks = String(localized: TipJarWords.thanksText)
        let newest = try #require(
            elements.first { $0.label == thanks || $0.label.hasPrefix(String(thanks.prefix(12))) }, "the thank-you: \(elements.map(\.description))")
        let done = try #require(elements.first { $0.label == String(localized: TipJarWords.done) }, "Done: \(elements.map(\.description))")
        let frame = newest.object.accessibilityFrame
        #expect(frame.maxY <= done.top, "the newest bubble ends at \(frame.maxY), under Done at \(done.top)")
        #expect(frame.minY >= barBottom, "the newest bubble starts at \(frame.minY), under the title bar at \(barBottom)")
    }

    /// The window of the test above, as tall as a 667 pt phone's sheet.
    private static let smallPhoneSheet: CGFloat = 640

    /// Where purchases are not allowed the sheet says so once, in the title, over the dimmed tiers: no
    /// second line says it again, and VoiceOver reads the title one time.
    @Test func whereTipsAreNotAllowedTheTitleAloneSaysSo() async throws {
        let model = app()
        model.tipJarServices.sender = { Self.content() }
        model.tipJarServices.store.canMakePayments = { false }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let (_, elements) = try await openSheet(model, lease: lease)
        let title = String(localized: TipJarWords.restrictedTitle(device: "iPhone"))
        #expect(elements.filter { $0.label == title }.count == 1, "the title once: \(elements.map(\.description))")
        #expect(!elements.contains { $0.label.localizedCaseInsensitiveContains("restricted") },
                "no second line: \(elements.map(\.description))")
    }

    @Test func withoutTheDeveloperTheHeaderIsTheRoleAlone() async throws {
        let model = app()
        model.tipJarServices.sender = { TipJarSenderContent() }
        let lease = try await HostWindow.take()
        defer { lease.give() }
        let (_, elements) = try await openSheet(model, lease: lease)
        let role = String(localized: TipJarWords.sender)
        #expect(elements.filter { $0.label == role }.count == 1, "\(elements.map(\.description))")
        #expect(!elements.contains { $0.traits.contains(.link) }, "no link without a handle and a logo")
    }
}

#endif
