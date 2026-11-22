import SwiftUI

// MARK: - Calendario

struct CalendarAppView: View {
    @EnvironmentObject var nav: NavigationModel
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(title: dateTitle)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(CalendarEvent.today) { e in
                        HStack(spacing: 14) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(time(e.start)).font(.system(size: 15, weight: .semibold))
                                Text("\(e.minutes) min").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            .frame(width: 64, alignment: .trailing)
                            RoundedRectangle(cornerRadius: 2).fill(Color.hue(e.hue)).frame(width: 4, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                                Text(e.location).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                state.open(.maps)
                                nav.searchAndRoute(e.location) { name in
                                    state.showBanner(name == nil ? "Luogo non trovato" : "Percorso verso \(name!)")
                                }
                            } label: {
                                Image(systemName: "car.fill")
                                    .font(.system(size: 16))
                                    .frame(width: 42, height: 42)
                                    .background(Color.blue, in: Circle())
                                    .foregroundColor(.white)
                            }
                            .buttonStyle(PressableStyle())
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        Divider().padding(.leading, 96)
                    }
                }
                .card()
                .padding(14)
            }
        }
    }

    private var dateTitle: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "it_IT")
        f.dateFormat = "EEEE d MMMM"
        return f.string(from: Date()).capitalized
    }

    private func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}

// MARK: - Meteo

struct WeatherView: View {
    var body: some View {
        let w = WeatherSample.current
        return VStack(spacing: 0) {
            AppHeader(title: "Meteo")
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(w.city).font(.system(size: 18, weight: .semibold))
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: w.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 54))
                        Text("\(w.temperature)°")
                            .font(.system(size: 64, weight: .thin))
                    }
                    Text(w.condition).font(.system(size: 17))
                    Text("Max \(w.high)°  Min \(w.low)°")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    Text("Dati dimostrativi")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Prossime ore").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 0) {
                        ForEach(w.hourly.indices, id: \.self) { i in
                            VStack(spacing: 8) {
                                Text(w.hourly[i].0).font(.system(size: 13, weight: .medium))
                                Image(systemName: w.hourly[i].1)
                                    .symbolRenderingMode(.multicolor)
                                    .font(.system(size: 22))
                                    .frame(height: 28)
                                Text("\(w.hourly[i].2)°").font(.system(size: 15, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card()
            }
            .padding(14)
        }
    }
}

// MARK: - Impostazioni

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var location: LocationManager

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(title: "Impostazioni")
            ScrollView {
                VStack(spacing: 14) {
                    section("Display") {
                        pickerRow("Risoluzione", selection: $settings.displayPreset, options: DisplayPreset.allCases) { $0.title }
                        Divider()
                        pickerRow("Aspetto", selection: $settings.appearance, options: AppearanceMode.allCases) { $0.title }
                        Divider()
                        toggleRow("Cornice dello schermo", isOn: $settings.showBezel)
                        Divider()
                        toggleRow("Guida a destra (barra a destra)", isOn: $settings.rightHandDrive)
                        Divider()
                        toggleRow("Formato 24 ore", isOn: $settings.use24h)
                    }

                    section("Sfondo") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(Wallpaper.all) { wp in
                                    Button { settings.wallpaperIndex = wp.id } label: {
                                        VStack(spacing: 6) {
                                            LinearGradient(colors: wp.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                                                .frame(width: 96, height: 58)
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                        .stroke(Color.white, lineWidth: settings.wallpaperIndex == wp.id ? 3 : 0)
                                                )
                                            Text(wp.name).font(.system(size: 12))
                                        }
                                    }
                                    .buttonStyle(PressableStyle())
                                    .foregroundStyle(.primary)
                                }
                            }
                            .padding(12)
                        }
                    }

                    section("Navigazione e voce") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Velocità simulazione").font(.system(size: 16))
                                Spacer()
                                Text("×\(Int(settings.simulationSpeed))").monospacedDigit().foregroundStyle(.secondary)
                            }
                            Slider(value: $settings.simulationSpeed, in: 1...20, step: 1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        Divider()
                        toggleRow("Risposte vocali dell'assistente", isOn: $settings.spokenFeedback)
                    }

                    section("Permessi") {
                        infoRow("Posizione", value: locationText)
                        Divider()
                        infoRow("Libreria Musica", value: media.libraryStatus == .authorized ? "Consentito" : "Non consentito")
                        Divider()
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        } label: {
                            HStack {
                                Text("Apri Impostazioni iOS").font(.system(size: 16))
                                Spacer()
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Text("CarPlay Sim \(version) · simulatore non ufficiale, non affiliato ad Apple. Pensato per LiveContainer.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 10)
                }
                .padding(14)
            }
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var locationText: String {
        switch location.authorization {
        case .authorizedAlways, .authorizedWhenInUse: return "Consentito"
        case .denied, .restricted: return "Negato"
        default: return "Non richiesto"
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            VStack(spacing: 0) { content() }
                .card(radius: 14)
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Text(title).font(.system(size: 16)) }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
    }

    private func infoRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 16))
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }

    private func pickerRow<T: Hashable & Identifiable>(_ title: String, selection: Binding<T>, options: [T],
                                                       label: @escaping (T) -> String) -> some View {
        HStack {
            Text(title).font(.system(size: 16))
            Spacer()
            Menu {
                ForEach(options) { option in
                    Button {
                        selection.wrappedValue = option
                    } label: {
                        if option == selection.wrappedValue {
                            Label(label(option), systemImage: "checkmark")
                        } else {
                            Text(label(option))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(label(selection.wrappedValue))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
    }
}
