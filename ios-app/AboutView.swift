import SwiftUI
import UIKit

/// About tab: version, project links and credits. Owns its `NavigationStack`
/// for the settings toolbar.
struct AboutView: View {
    /// Observed so labels redraw when the language changes.
    @EnvironmentObject private var loc: Localizer

    @State private var showSettings = false
    @State private var showReport = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header.cascadeItem(0)
                    summary.cascadeItem(1)
                    links.cascadeItem(2)
                    thanks.cascadeItem(3)
                    builtWith.cascadeItem(4)
                }
                .padding(20)
                .pageColumn()
            }
            .background(AppBackground())
            .toolbar { settingsToolbarItem(isPresented: $showSettings) }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showReport) { ReportProblemView() }
        }
    }

    // MARK: Header

    private var header: some View {
        BrandHeader(icon: "info.circle", image: "AppLogo", title: "iLoader X",
                    subtitle: L("an app by iamgasgass")) {
            Text(versionText)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.muted)
        }
    }

    /// Version and build number, read from the app bundle.
    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return L("Version %@ (%@)", short, build)
    }

    // MARK: What it is

    private var summary: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle(L("About"), systemImage: "info.circle")
                Text(L("iLoader X installs SideStore and LiveContainer straight onto your iPhone, with no PC involved."))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Links

    private var links: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle(L("Links"), systemImage: "link")
                AboutRow(systemImage: "chevron.left.forwardslash.chevron.right",
                         title: L("Source code"),
                         urlString: "https://github.com/iamgasgass/iLoaderX")
                // Required by SideInstaller's licence (section 4): credit and link.
                AboutRow(systemImage: "arrow.triangle.branch",
                         title: "Based on SideInstaller by FrizzleM",
                         detail: L("iLoader X is a fork of it, with its own name, bundle ID and icon."),
                         urlString: "https://github.com/FrizzleM/SideInstaller")
                AboutRow(systemImage: "exclamationmark.bubble",
                         title: L("Report a problem"),
                         detail: L("Opens a GitHub issue with this app's details, its log and crash logs."),
                         action: { showReport = true })
                AboutRow(systemImage: "cup.and.saucer",
                         title: L("Support the project"),
                         detail: "PayPal.me/iamgasgass",
                         urlString: "https://paypal.me/iamgasgass")
            }
        }
    }

    // MARK: Special thanks

    private var thanks: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle(L("Special thanks"), systemImage: "heart")
                AboutRow(systemImage: "arrow.triangle.branch",
                         title: "FrizzleM",
                         detail: L("For SideInstaller, the base iLoader X is built on."),
                         urlString: "https://github.com/FrizzleM")
                AboutRow(systemImage: "hammer",
                         title: "jkcoxson",
                         detail: L("For idevice, the library iLoader X talks to your iPhone through. None of this exists without it."),
                         urlString: "https://github.com/jkcoxson/idevice")
                AboutRow(systemImage: "ladybug",
                         title: "Vexon",
                         detail: L("For the support, and for spotting the bugs that got fixed because of it."))
                AboutRow(systemImage: "character.bubble",
                         title: "so-5699",
                         detail: L("For the Japanese translation."),
                         urlString: "https://github.com/so-5699")
                AboutRow(systemImage: "character.bubble",
                         title: "kes158",
                         detail: L("For the Korean translation."),
                         urlString: "https://github.com/kes158")
                AboutRow(systemImage: "character.bubble",
                         title: "Mr3242-Scripter",
                         detail: L("For the Turkish translation."),
                         urlString: "https://github.com/Mr3242-Scripter")
            }
        }
    }

    // MARK: Built with

    private var builtWith: some View {
        PanelCard {
            VStack(alignment: .leading, spacing: 16) {
                sectionTitle(L("Built with"), systemImage: "shippingbox")
                Text(L("The open source work this app is built on:"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                AboutRow(systemImage: "iphone.gen3",
                         title: "idevice",
                         detail: L("Pairing, the tunnel and the install itself. By jkcoxson, MIT."),
                         urlString: "https://github.com/jkcoxson/idevice")
                AboutRow(systemImage: "signature",
                         title: "isideload",
                         detail: L("Apple ID sign in, certificates and signing on the device. By nab138, MIT."),
                         urlString: "https://github.com/nab138/isideload")
                AboutRow(systemImage: "checkmark.seal",
                         title: "apple-codesign-quick",
                         detail: L("The code signer isideload uses for each app. By Dadoum, LGPL-2.1."),
                         urlString: "https://github.com/Dadoum/apple-crates")
                AboutRow(systemImage: "arrow.down.app",
                         title: "SideInstaller",
                         detail: L("The app iLoader X is a fork of: pairing, signing and installing on the device. By FrizzleM, SideInstaller License."),
                         urlString: "https://github.com/FrizzleM/SideInstaller")
                AboutRow(systemImage: "shippingbox",
                         title: "SideStore",
                         detail: L("The sideloading app this installs for you."),
                         urlString: "https://github.com/SideStore/SideStore")
                AboutRow(systemImage: "square.stack.3d.up",
                         title: "LiveContainer",
                         detail: L("Runs sideloaded apps without spending an app slot on each one."),
                         urlString: "https://github.com/LiveContainer/LiveContainer")
                AboutRow(systemImage: "gamecontroller",
                         title: "Madeira",
                         detail: L("Runs Windows PC games on your iPhone. By Will Faust, GPL-3.0."),
                         urlString: "https://github.com/willfaust/Madeira")
                AboutRow(systemImage: "externaldrive",
                         title: "DeveloperDiskImage",
                         detail: L("The developer disk image location spoofing mounts. Mirrored by doronz88."),
                         urlString: "https://github.com/doronz88/DeveloperDiskImage")
            }
        }
    }

    // MARK: Helpers

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        SectionTitle(title: title, systemImage: systemImage)
    }
}

// MARK: - Row

/// A row with an icon, a title and an optional detail line. Rows with a
/// `urlString` open it and show an arrow; rows with an `action` run it and
/// show a chevron.
private struct AboutRow: View {
    var systemImage: String
    var title: String
    var detail: String? = nil
    var urlString: String? = nil
    var action: (() -> Void)? = nil

    @Environment(\.openURL) private var openURL

    var body: some View {
        if let action {
            Button(action: action) { content(accessory: "chevron.right") }
                .buttonStyle(.plain, sound: .tick)
        } else if let url = urlString.flatMap(URL.init(string:)) {
            Button { openURL(url) } label: { content(accessory: "arrow.up.right") }
                // `.plain` keeps the row from using the accent color.
                .buttonStyle(.plain, sound: .tick)
        } else {
            content(accessory: nil)
        }
    }

    private func content(accessory: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Theme.muted)
                // Fixed width so the icons line up.
                .frame(width: 24, alignment: .center)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let accessory {
                Image(systemName: accessory)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.muted)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
