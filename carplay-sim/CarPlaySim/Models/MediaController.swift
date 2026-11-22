import AVFoundation
import MediaPlayer
import SwiftUI

struct RadioStation: Identifiable, Hashable {
    let id: String
    let name: String
    let genre: String
    let url: URL
    let hue: Double
}

struct DemoTrack: Hashable {
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let hue: Double
}

/// Gestisce riproduzione: radio in streaming (AVPlayer), libreria Musica di sistema e brani demo.
final class MediaController: NSObject, ObservableObject, AVPlayerItemMetadataOutputPushDelegate {
    enum Source: Equatable {
        case none
        case radio
        case library
        case demo
    }

    @Published private(set) var source: Source = .none
    @Published private(set) var title = "Niente in riproduzione"
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var artwork: UIImage?
    @Published private(set) var hue: Double = 0.6
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentStation: RadioStation?
    @Published private(set) var libraryStatus: MPMediaLibraryAuthorizationStatus = MPMediaLibrary.authorizationStatus()
    @Published private(set) var demoIndex = 0
    @Published var shuffle = false
    @Published var repeatAll = true

    static let stations: [RadioStation] = [
        RadioStation(id: "groovesalad", name: "Groove Salad", genre: "Ambient / Downtempo",
                     url: URL(string: "https://ice1.somafm.com/groovesalad-128-mp3")!, hue: 0.33),
        RadioStation(id: "indiepop", name: "Indie Pop Rocks!", genre: "Indie Pop",
                     url: URL(string: "https://ice1.somafm.com/indiepop-128-mp3")!, hue: 0.92),
        RadioStation(id: "secretagent", name: "Secret Agent", genre: "Lounge / Spy",
                     url: URL(string: "https://ice1.somafm.com/secretagent-128-mp3")!, hue: 0.05),
        RadioStation(id: "lush", name: "Lush", genre: "Vocals / Chill",
                     url: URL(string: "https://ice1.somafm.com/lush-128-mp3")!, hue: 0.80),
        RadioStation(id: "dronezone", name: "Drone Zone", genre: "Ambient",
                     url: URL(string: "https://ice1.somafm.com/dronezone-128-mp3")!, hue: 0.58),
        RadioStation(id: "defcon", name: "DEF CON Radio", genre: "Electronic",
                     url: URL(string: "https://ice1.somafm.com/defcon-128-mp3")!, hue: 0.45),
        RadioStation(id: "radioparadise", name: "Radio Paradise", genre: "Eclectic",
                     url: URL(string: "https://stream.radioparadise.com/aac-128")!, hue: 0.12)
    ]

    static let demoTracks: [DemoTrack] = [
        DemoTrack(title: "Autostrada di notte", artist: "I Simulatori", album: "Chilometri", duration: 214, hue: 0.62),
        DemoTrack(title: "Corsia di sorpasso", artist: "Banda Larga", album: "Statale 1", duration: 187, hue: 0.02),
        DemoTrack(title: "Navigatore", artist: "Luna Park", album: "Ricalcolo", duration: 243, hue: 0.78),
        DemoTrack(title: "Casello", artist: "I Simulatori", album: "Chilometri", duration: 198, hue: 0.14),
        DemoTrack(title: "Lungomare", artist: "Onde Medie", album: "FM", duration: 226, hue: 0.50)
    ]

    private var player: AVPlayer?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var statusObservation: NSKeyValueObservation?
    private let musicPlayer = MPMusicPlayerController.systemMusicPlayer
    private var timer: Timer?

    override init() {
        super.init()
        setupRemoteCommands()
        musicPlayer.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(libraryItemChanged),
                                               name: .MPMusicPlayerControllerNowPlayingItemDidChange, object: musicPlayer)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryItemChanged),
                                               name: .MPMusicPlayerControllerPlaybackStateDidChange, object: musicPlayer)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    deinit {
        timer?.invalidate()
        musicPlayer.endGeneratingPlaybackNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Audio session

    func activatePlaybackSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
    }

    // MARK: - Radio

    func play(station: RadioStation) {
        stopAll()
        activatePlaybackSession()
        let item = AVPlayerItem(url: station.url)
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        item.add(output)
        metadataOutput = output

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                self?.isBuffering = p.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self?.isPlaying = p.timeControlStatus != .paused
                self?.updateNowPlayingInfo()
            }
        }
        self.player = player
        player.play()

        source = .radio
        currentStation = station
        title = station.name
        artist = station.genre
        album = "Radio in diretta"
        artwork = nil
        hue = station.hue
        elapsed = 0
        duration = 0
        isPlaying = true
        updateNowPlayingInfo()
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        guard source == .radio else { return }
        for group in groups {
            for item in group.items {
                guard let value = item.stringValue, !value.isEmpty else { continue }
                if item.commonKey == .commonKeyTitle || item.identifier == .icyMetadataStreamTitle {
                    let parts = value.components(separatedBy: " - ")
                    if parts.count >= 2 {
                        artist = parts[0].trimmingCharacters(in: .whitespaces)
                        title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                    } else {
                        title = value
                        artist = currentStation?.name ?? ""
                    }
                    album = currentStation?.name ?? ""
                    updateNowPlayingInfo()
                    return
                }
            }
        }
    }

    // MARK: - Libreria Musica

    func requestLibraryAccess(completion: (() -> Void)? = nil) {
        MPMediaLibrary.requestAuthorization { status in
            DispatchQueue.main.async {
                self.libraryStatus = status
                completion?()
            }
        }
    }

    var libraryAvailable: Bool { libraryStatus == .authorized }

    func playLibrary(shuffled: Bool = true) {
        guard libraryAvailable else {
            requestLibraryAccess { [weak self] in
                guard let self = self else { return }
                if self.libraryAvailable { self.playLibrary(shuffled: shuffled) } else { self.playDemo(index: 0) }
            }
            return
        }
        let songs = MPMediaQuery.songs()
        guard let items = songs.items, !items.isEmpty else {
            playDemo(index: 0)
            return
        }
        stopAll()
        musicPlayer.setQueue(with: songs)
        musicPlayer.shuffleMode = shuffled ? .songs : .off
        musicPlayer.repeatMode = .all
        musicPlayer.play()
        source = .library
        isPlaying = true
        libraryItemChanged()
    }

    func playLibrary(collection: MPMediaItemCollection, startAt item: MPMediaItem? = nil) {
        stopAll()
        musicPlayer.setQueue(with: collection)
        if let item = item { musicPlayer.nowPlayingItem = item }
        musicPlayer.play()
        source = .library
        isPlaying = true
        libraryItemChanged()
    }

    @objc private func libraryItemChanged() {
        DispatchQueue.main.async {
            guard self.source == .library else { return }
            let item = self.musicPlayer.nowPlayingItem
            self.title = item?.title ?? "Sconosciuto"
            self.artist = item?.artist ?? ""
            self.album = item?.albumTitle ?? ""
            self.duration = item?.playbackDuration ?? 0
            self.artwork = item?.artwork?.image(at: CGSize(width: 600, height: 600))
            self.isPlaying = self.musicPlayer.playbackState == .playing
            self.hue = Double(abs(self.title.hashValue % 100)) / 100
        }
    }

    // MARK: - Demo

    func playDemo(index: Int) {
        if source != .demo { stopAll() }
        let tracks = MediaController.demoTracks
        demoIndex = (index % tracks.count + tracks.count) % tracks.count
        let t = tracks[demoIndex]
        source = .demo
        title = t.title
        artist = t.artist
        album = t.album
        duration = t.duration
        elapsed = 0
        artwork = nil
        hue = t.hue
        isPlaying = true
        updateNowPlayingInfo()
    }

    // MARK: - Controlli

    func togglePlayPause() {
        switch source {
        case .none:
            playDemo(index: 0)
        case .radio:
            if isPlaying { player?.pause() } else { activatePlaybackSession(); player?.play() }
        case .library:
            if musicPlayer.playbackState == .playing { musicPlayer.pause() } else { musicPlayer.play() }
            isPlaying.toggle()
        case .demo:
            isPlaying.toggle()
        }
        updateNowPlayingInfo()
    }

    func pause() {
        if isPlaying { togglePlayPause() }
    }

    func resume() {
        if !isPlaying { togglePlayPause() }
    }

    func next() {
        switch source {
        case .none: playDemo(index: 0)
        case .radio:
            let all = MediaController.stations
            let idx = all.firstIndex(where: { $0.id == currentStation?.id }) ?? -1
            play(station: all[(idx + 1) % all.count])
        case .library: musicPlayer.skipToNextItem()
        case .demo:
            if shuffle {
                playDemo(index: Int.random(in: 0..<MediaController.demoTracks.count))
            } else {
                playDemo(index: demoIndex + 1)
            }
        }
    }

    func previous() {
        switch source {
        case .none: playDemo(index: 0)
        case .radio:
            let all = MediaController.stations
            let idx = all.firstIndex(where: { $0.id == currentStation?.id }) ?? 0
            play(station: all[(idx - 1 + all.count) % all.count])
        case .library:
            if musicPlayer.currentPlaybackTime > 3 { musicPlayer.skipToBeginning() } else { musicPlayer.skipToPreviousItem() }
        case .demo:
            if elapsed > 3 { elapsed = 0 } else { playDemo(index: demoIndex - 1) }
        }
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let t = max(0, min(1, fraction)) * duration
        switch source {
        case .library: musicPlayer.currentPlaybackTime = t
        case .demo: elapsed = t
        default: break
        }
        updateNowPlayingInfo()
    }

    func stopAll() {
        player?.pause()
        statusObservation = nil
        player = nil
        metadataOutput = nil
        if source == .library { musicPlayer.pause() }
        currentStation = nil
        isBuffering = false
    }

    // MARK: - Timer

    private func tick() {
        switch source {
        case .library:
            elapsed = musicPlayer.currentPlaybackTime.isFinite ? musicPlayer.currentPlaybackTime : 0
        case .demo:
            guard isPlaying else { return }
            elapsed += 0.5
            if elapsed >= duration {
                if repeatAll || demoIndex < MediaController.demoTracks.count - 1 {
                    next()
                } else {
                    isPlaying = false
                    elapsed = duration
                }
            }
        case .radio:
            if let t = player?.currentTime().seconds, t.isFinite { elapsed = t }
        case .none:
            break
        }
    }

    // MARK: - Centro di controllo

    private func updateNowPlayingInfo() {
        guard source == .radio || source == .demo else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyAlbumTitle: album,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed
        ]
        if source == .radio {
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        } else {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause(); return .success
        }
        center.playCommand.addTarget { [weak self] _ in
            self?.resume(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            self?.next(); return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous(); return .success
        }
    }
}
