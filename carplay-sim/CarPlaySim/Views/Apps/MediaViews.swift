import MediaPlayer
import SwiftUI

// MARK: - In riproduzione

struct NowPlayingView: View {
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var state: AppState
    @State private var scrubbing: Double?

    var body: some View {
        GeometryReader { geo in
            let artSize = min(geo.size.height - 60, geo.size.width * 0.38)
            ZStack {
                LinearGradient(colors: [Color.hue(media.hue, s: 0.6, b: 0.45).opacity(0.85), Color.black.opacity(0.85)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()

                HStack(spacing: 28) {
                    ArtworkView(image: media.artwork, hue: media.hue,
                                symbol: media.source == .radio ? "dot.radiowaves.left.and.right" : "music.note",
                                cornerRadius: 16)
                        .frame(width: artSize, height: artSize)
                        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)

                    VStack(alignment: .leading, spacing: 14) {
                        Text(sourceLabel)
                            .font(.system(size: 13, weight: .semibold))
                            .textCase(.uppercase)
                            .foregroundColor(.white.opacity(0.6))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(media.title)
                                .font(.system(size: 26, weight: .bold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                            Text(media.artist)
                                .font(.system(size: 18))
                                .foregroundColor(.white.opacity(0.75))
                                .lineLimit(1)
                            if !media.album.isEmpty {
                                Text(media.album)
                                    .font(.system(size: 15))
                                    .foregroundColor(.white.opacity(0.5))
                                    .lineLimit(1)
                            }
                        }

                        progress

                        controls

                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").font(.system(size: 12))
                            SystemVolumeView().frame(height: 30)
                            Image(systemName: "speaker.wave.3.fill").font(.system(size: 12))
                        }
                        .foregroundColor(.white.opacity(0.7))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 20)
            }
        }
    }

    private var sourceLabel: String {
        switch media.source {
        case .none: return "Nessuna sorgente"
        case .radio: return media.isBuffering ? "Radio · connessione…" : "Radio · in diretta"
        case .library: return "Libreria Musica"
        case .demo: return "Demo (audio simulato)"
        }
    }

    @ViewBuilder
    private var progress: some View {
        if media.source == .radio {
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text("LIVE").font(.system(size: 12, weight: .bold))
                Text(Formatters.time(media.elapsed))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.6))
            }
        } else if media.duration > 0 {
            VStack(spacing: 2) {
                Slider(value: Binding(
                    get: { scrubbing ?? (media.elapsed / max(media.duration, 1)) },
                    set: { scrubbing = $0 }
                ), in: 0...1, onEditingChanged: { editing in
                    if !editing, let s = scrubbing {
                        media.seek(to: s)
                        scrubbing = nil
                    }
                })
                .tint(.white)
                HStack {
                    Text(Formatters.time(media.elapsed))
                    Spacer()
                    Text("-" + Formatters.time(max(0, media.duration - media.elapsed)))
                }
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            Button { media.shuffle.toggle() } label: {
                Image(systemName: "shuffle")
                    .foregroundColor(media.shuffle ? Color.pink : Color.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            Button { media.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 30)) }
                .frame(maxWidth: .infinity)
            Button { media.togglePlayPause() } label: {
                Image(systemName: media.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 58))
            }
            .frame(maxWidth: .infinity)
            Button { media.next() } label: { Image(systemName: "forward.fill").font(.system(size: 30)) }
                .frame(maxWidth: .infinity)
            Button { state.open(media.source == .radio ? .radio : .music) } label: {
                Image(systemName: "list.bullet")
            }
            .frame(maxWidth: .infinity)
        }
        .font(.system(size: 20, weight: .semibold))
        .buttonStyle(PressableStyle())
        .foregroundColor(.white)
    }
}

// MARK: - Musica

struct MusicLibraryView: View {
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var state: AppState
    @State private var tab = 0
    @State private var playlists: [MPMediaItemCollection] = []
    @State private var albums: [MPMediaItemCollection] = []

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(title: "Musica") {
                Picker("", selection: $tab) {
                    Text("Libreria").tag(0)
                    Text("Demo").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }

            ScrollView {
                VStack(spacing: 0) {
                    if tab == 0 {
                        libraryContent
                    } else {
                        demoContent
                    }
                }
                .card()
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .onAppear(perform: loadLibrary)
        .onChange(of: media.libraryStatus) { _ in loadLibrary() }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if media.libraryStatus == .authorized {
            Button { media.playLibrary(shuffled: true); state.open(.nowPlaying) } label: {
                CarListRow(title: "Riproduzione casuale", subtitle: "Tutti i brani", trailingSymbol: nil) {
                    iconCircle("shuffle", .pink)
                }
            }
            .buttonStyle(.plain)
            Divider().padding(.leading, 66)

            if playlists.isEmpty && albums.isEmpty {
                Text("Nessun brano trovato nella libreria. Prova i brani Demo o la Radio.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .padding(20)
            }

            ForEach(playlists, id: \.persistentID) { list in
                Button { media.playLibrary(collection: list); state.open(.nowPlaying) } label: {
                    CarListRow(title: list.value(forProperty: MPMediaPlaylistPropertyName) as? String ?? "Playlist",
                               subtitle: "\(list.count) brani") {
                        iconCircle("music.note.list", .orange)
                    }
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 66)
            }

            ForEach(albums, id: \.persistentID) { album in
                Button { media.playLibrary(collection: album); state.open(.nowPlaying) } label: {
                    CarListRow(title: album.representativeItem?.albumTitle ?? "Album",
                               subtitle: album.representativeItem?.albumArtist ?? album.representativeItem?.artist) {
                        if let img = album.representativeItem?.artwork?.image(at: CGSize(width: 80, height: 80)) {
                            Image(uiImage: img)
                                .resizable()
                                .frame(width: 38, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            iconCircle("square.stack.fill", .purple)
                        }
                    }
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 66)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "music.note.house.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.pink)
                Text(media.libraryStatus == .denied || media.libraryStatus == .restricted
                     ? "Accesso alla libreria negato. Abilitalo in Impostazioni di iOS, oppure usa i brani Demo."
                     : "Consenti l'accesso alla libreria Musica per riprodurre i tuoi brani.")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                if media.libraryStatus == .notDetermined {
                    Button("Consenti accesso") { media.requestLibraryAccess() }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private var demoContent: some View {
        ForEach(Array(MediaController.demoTracks.enumerated()), id: \.offset) { index, track in
            VStack(spacing: 0) {
                Button { media.playDemo(index: index); state.open(.nowPlaying) } label: {
                    CarListRow(title: track.title, subtitle: "\(track.artist) · \(Formatters.time(track.duration))",
                               trailingSymbol: media.source == .demo && media.demoIndex == index ? "speaker.wave.2.fill" : nil) {
                        ArtworkView(image: nil, hue: track.hue, cornerRadius: 6)
                            .frame(width: 38, height: 38)
                    }
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 66)
            }
        }
    }

    private func iconCircle(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .frame(width: 38, height: 38)
            .background(color, in: Circle())
            .foregroundColor(.white)
    }

    private func loadLibrary() {
        guard media.libraryStatus == .authorized else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = MPMediaQuery.playlists().collections ?? []
            let a = Array((MPMediaQuery.albums().collections ?? []).prefix(60))
            DispatchQueue.main.async {
                playlists = p
                albums = a
            }
        }
    }
}

// MARK: - Radio

struct RadioView: View {
    @EnvironmentObject var media: MediaController
    @EnvironmentObject var state: AppState

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(title: "Radio") {
                if media.source == .radio {
                    Button { state.open(.nowPlaying) } label: {
                        Label("In onda", systemImage: "waveform")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.pink, in: Capsule())
                            .foregroundColor(.white)
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(MediaController.stations) { station in
                        Button {
                            media.play(station: station)
                            state.open(.nowPlaying)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack {
                                    LinearGradient(colors: [Color.hue(station.hue, s: 0.7, b: 0.95), Color.hue(station.hue, s: 0.9, b: 0.4)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .font(.system(size: 28, weight: .bold))
                                        .foregroundColor(.white.opacity(0.9))
                                    if media.currentStation?.id == station.id {
                                        VStack {
                                            HStack {
                                                Spacer()
                                                EqualizerBars().frame(width: 16, height: 14).padding(8)
                                            }
                                            Spacer()
                                        }
                                    }
                                }
                                .frame(height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                Text(station.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                Text(station.genre)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(10)
                            .card(radius: 16)
                        }
                        .buttonStyle(PressableStyle())
                        .foregroundStyle(.primary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

                Text("Stream: SomaFM e Radio Paradise (serve connessione a Internet).")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 14)
            }
        }
    }
}
