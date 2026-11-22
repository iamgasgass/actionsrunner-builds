import CarPlay
import SwiftUI

/// Schermata di un'app CarPlay installata: carica l'app e mostra i suoi template.
struct GuestAppView: View {
    let appID: String
    @EnvironmentObject var library: AppLibrary
    @EnvironmentObject var runtime: GuestRuntime

    var body: some View {
        ZStack {
            CP.background
            if let app = library.app(id: appID) {
                if let session = runtime.sessions[appID] {
                    GuestSessionView(session: session)
                } else if let error = runtime.errors[appID] {
                    GuestErrorView(app: app, message: error) { runtime.retry(app) }
                } else {
                    GuestLaunchView(app: app)
                        .onAppear { runtime.launch(app) }
                }
            } else {
                Text("App non trovata")
                    .foregroundColor(CP.secondaryText)
            }
        }
    }
}

/// Schermata di avvio: icona dell'app al centro, come quando un'app CarPlay si apre.
struct GuestLaunchView: View {
    let app: GuestApp

    var body: some View {
        VStack(spacing: 14) {
            GuestIconView(app: app, size: 76)
            ProgressView().tint(.white)
        }
    }
}

struct GuestErrorView: View {
    let app: GuestApp
    let message: String
    let retry: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GuestIconView(app: app, size: 60)
                Text("Impossibile aprire \(app.name)")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                Text(message)
                    .font(.system(size: 14))
                    .foregroundColor(CP.secondaryText)
                    .multilineTextAlignment(.center)
                Button("Riprova", action: retry)
                    .buttonStyle(CPCapsuleButtonStyle(prominent: true))
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }
}

struct GuestSessionView: View {
    @ObservedObject var session: GuestSession

    var body: some View {
        let _ = session.tick
        ZStack {
            CP.background.ignoresSafeArea()

            if let top = session.top {
                CPTemplateScreen(session: session, template: top)
                    .id(ObjectIdentifier(top))
            } else {
                VStack(spacing: 12) {
                    GuestIconView(app: session.app, size: 64)
                    Text(session.app.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            if let presented = session.presented {
                CPPresentedView(session: session, template: presented)
                    .transition(.opacity)
            }

            if let err = session.lastError {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                        Text(err).font(.system(size: 12)).foregroundColor(.white).lineLimit(3)
                        Button { session.lastError = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(CP.secondaryText)
                        }
                    }
                    .padding(10)
                    .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 10))
                    .padding(10)
                }
            }
        }
    }
}

/// Template in cima allo stack, con barra di navigazione dove prevista.
struct CPTemplateScreen: View {
    @ObservedObject var session: GuestSession
    let template: CPTemplate

    var body: some View {
        if let tabs = template as? CPTabBarTemplate {
            CPTabBarView(session: session, tabBar: tabs)
        } else if let map = template as? CPMapTemplate {
            CPMapTemplateView(session: session, map: map)
        } else if template is CPNowPlayingTemplate {
            VStack(spacing: 0) {
                CPNavigationBar(session: session, template: template, title: "In riproduzione")
                CPNowPlayingView(session: session)
            }
        } else {
            VStack(spacing: 0) {
                CPNavigationBar(session: session, template: template, title: template.cpsTitle)
                CPTemplateContent(session: session, template: template)
            }
        }
    }
}

/// Contenuto di un template (senza barra di navigazione).
struct CPTemplateContent: View {
    @ObservedObject var session: GuestSession
    let template: CPTemplate

    var body: some View {
        if let list = template as? CPListTemplate {
            CPListView(session: session, list: list)
        } else if let grid = template as? CPGridTemplate {
            CPGridView(session: session, grid: grid)
        } else if let info = template as? CPInformationTemplate {
            CPInformationView(session: session, info: info)
        } else if let poi = template as? CPPointOfInterestTemplate {
            CPPointOfInterestView(session: session, poi: poi)
        } else if let contact = template as? CPContactTemplate {
            CPContactView(session: session, contact: contact)
        } else if let search = template as? CPSearchTemplate {
            CPSearchView(session: session, search: search)
        } else if template is CPNowPlayingTemplate {
            CPNowPlayingView(session: session)
        } else if let map = template as? CPMapTemplate {
            CPMapTemplateView(session: session, map: map)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 34))
                Text("Template non supportato: \(String(describing: type(of: template)))")
                    .font(.system(size: 14))
            }
            .foregroundColor(CP.secondaryText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Tab bar

struct CPTabBarView: View {
    @ObservedObject var session: GuestSession
    let tabBar: CPTabBarTemplate

    var body: some View {
        let templates = tabBar.templates
        let index = min(max(0, selectedIndex(templates)), max(0, templates.count - 1))
        VStack(spacing: 0) {
            if templates.indices.contains(index) {
                let current = templates[index]
                CPNavigationBar(session: session, template: current, title: nil) {
                    tabs(templates, selected: index)
                }
                CPTemplateContent(session: session, template: current)
                    .id(ObjectIdentifier(current))
            }
        }
    }

    private func selectedIndex(_ templates: [CPTemplate]) -> Int {
        if let selected = CPSObjC.get(tabBar, NSSelectorFromString("selectedTemplate")) as? CPTemplate,
           let i = templates.firstIndex(where: { $0 === selected }) {
            return i
        }
        return session.selectedTab
    }

    private func tabs(_ templates: [CPTemplate], selected: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(templates.enumerated()), id: \.offset) { i, t in
                Button {
                    session.selectedTab = i
                    session.guest("Tab") {
                        let select = NSSelectorFromString("selectTemplate:")
                        if tabBar.responds(to: select) { CPSObjC.send(tabBar, select, t) }
                        if let delegate = tabBar.delegate {
                            CPSObjC.send(delegate, NSSelectorFromString("tabBarTemplate:didSelectTemplate:"), tabBar, t)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if let img = t.tabImage {
                            Image(uiImage: img).renderingMode(.template).resizable().scaledToFit().frame(width: 18, height: 18)
                        } else if t.tabTitle == nil {
                            Image(systemName: t.tabSystemItem.cpsSymbol).font(.system(size: 15))
                        }
                        Text(t.tabTitle ?? t.tabSystemItem.cpsTitle)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if t.showsTabBadge {
                            Circle().fill(Color.red).frame(width: 7, height: 7)
                        }
                    }
                    .foregroundColor(i == selected ? .black : .white)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(i == selected ? Color.white : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(CP.buttonFill))
    }
}

// MARK: - Liste

struct CPListView: View {
    @ObservedObject var session: GuestSession
    let list: CPListTemplate

    var body: some View {
        let sections = list.sections
        let isEmpty = sections.allSatisfy { $0.items.isEmpty }
        if isEmpty {
            VStack(spacing: 6) {
                Text(list.emptyViewTitleVariants.first ?? "")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                Text(list.emptyViewSubtitleVariants.first ?? "")
                    .font(.system(size: 15))
                    .foregroundColor(CP.secondaryText)
            }
            .multilineTextAlignment(.center)
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                        if let header = section.header, !header.isEmpty {
                            Text(header)
                                .font(CP.headerFont)
                                .foregroundColor(CP.secondaryText)
                                .padding(.horizontal, CP.horizontalPadding)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                        }
                        ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                            CPListRow(session: session, item: item)
                            Rectangle()
                                .fill(CP.separator)
                                .frame(height: 0.5)
                                .padding(.leading, CP.horizontalPadding)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }
}

struct CPListRow: View {
    @ObservedObject var session: GuestSession
    let item: CPListTemplateItem

    var body: some View {
        if let row = item as? CPListImageRowItem {
            imageRow(row)
        } else {
            Button {
                if let selectable = item as? CPSelectableListItem { session.select(selectable) }
            } label: {
                standardRow
            }
            .buttonStyle(CPRowButtonStyle())
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
        }
    }

    private var enabled: Bool {
        (item as? CPListItem)?.isEnabled ?? true
    }

    private var standardRow: some View {
        let listItem = item as? CPListItem
        let message = item as? CPMessageListItem
        let playingLeading = listItem?.isPlaying == true && listItem?.playingIndicatorLocation == .leading
        let playingTrailing = listItem?.isPlaying == true && listItem?.playingIndicatorLocation == .trailing
        return HStack(spacing: 12) {
            if playingLeading { CPPlayingIndicator() }
            if let image = listItem?.image {
                CPImage(image: image, size: CP.rowImage)
            } else if let lead = message?.leadingConfiguration, let img = lead.leadingImage {
                CPImage(image: img, size: CP.rowImage, radius: CP.rowImage / 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.text ?? message?.conversationIdentifier ?? "")
                        .font(CP.rowFont)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if listItem?.isExplicitContent == true {
                        Image(systemName: "e.square.fill")
                            .font(.system(size: 13))
                            .foregroundColor(CP.secondaryText)
                    }
                }
                if let detail = listItem?.detailText ?? message?.detailText, !detail.isEmpty {
                    Text(detail)
                        .font(CP.detailFont)
                        .foregroundColor(CP.secondaryText)
                        .lineLimit(1)
                }
                if let progress = listItem?.playbackProgress, progress > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(white: 0.3))
                            Capsule().fill(Color.white).frame(width: g.size.width * min(1, progress))
                        }
                    }
                    .frame(width: 80, height: 3)
                }
            }
            Spacer(minLength: 8)
            if let trailing = message?.trailingText {
                Text(trailing).font(CP.detailFont).foregroundColor(CP.secondaryText)
            }
            if playingTrailing { CPPlayingIndicator() }
            accessory(listItem)
        }
        .padding(.horizontal, CP.horizontalPadding)
        .padding(.vertical, 6)
        .frame(minHeight: CP.rowMinHeight)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func accessory(_ item: CPListItem?) -> some View {
        if let item = item {
            if let img = item.accessoryImage {
                CPImage(image: img, size: 20, radius: 0, template: true)
            } else {
                switch item.accessoryType {
                case .disclosureIndicator:
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(CP.tertiaryText)
                case .cloud:
                    Image(systemName: "icloud.and.arrow.down")
                        .font(.system(size: 16))
                        .foregroundColor(CP.secondaryText)
                default:
                    EmptyView()
                }
            }
        }
    }

    private func imageRow(_ row: CPListImageRowItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                session.select(row)
            } label: {
                HStack {
                    Text(row.text ?? "")
                        .font(CP.rowFont)
                        .foregroundColor(.white)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(CP.tertiaryText)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                ForEach(Array(row.gridImages.enumerated()), id: \.offset) { index, image in
                    Button {
                        if let handler = row.listImageRowHandler {
                            session.guest("Immagine") { handler(row, index) {} }
                        }
                    } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 64, height: 64)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, CP.horizontalPadding)
        .padding(.vertical, 10)
    }
}

// MARK: - Griglia

struct CPGridView: View {
    @ObservedObject var session: GuestSession
    let grid: CPGridTemplate

    var body: some View {
        let buttons = grid.gridButtons
        let columns = buttons.count <= 4 ? max(1, buttons.count) : Int((Double(buttons.count) / 2).rounded(.up))
        VStack {
            Spacer(minLength: 0)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns), spacing: 18) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    Button {
                        session.tap(handlerOf: button, label: "Griglia")
                    } label: {
                        VStack(spacing: 8) {
                            Image(uiImage: button.image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 56, height: 56)
                            Text(button.titleVariants.first ?? "")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .disabled(!button.isEnabled)
                    .opacity(button.isEnabled ? 1 : 0.4)
                }
            }
            .padding(.horizontal, 24)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Informazioni

struct CPInformationView: View {
    @ObservedObject var session: GuestSession
    let info: CPInformationTemplate

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(info.items.enumerated()), id: \.offset) { _, item in
                        if info.layout == .twoColumn {
                            HStack(alignment: .top) {
                                Text(item.title ?? "")
                                    .font(.system(size: 15))
                                    .foregroundColor(CP.secondaryText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                detail(item)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 3) {
                                if let t = item.title, !t.isEmpty {
                                    Text(t).font(.system(size: 15)).foregroundColor(CP.secondaryText)
                                }
                                detail(item)
                            }
                        }
                    }
                }
                .padding(CP.horizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !info.actions.isEmpty {
                HStack(spacing: 10) {
                    ForEach(Array(info.actions.enumerated()), id: \.offset) { _, action in
                        CPTextButtonView(session: session, button: action)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func detail(_ item: CPInformationItem) -> some View {
        if let rating = item as? CPInformationRatingItem, let value = rating.rating?.doubleValue {
            let maximum = Int(rating.maximumRating?.intValue ?? 5)
            HStack(spacing: 2) {
                ForEach(0..<max(1, maximum), id: \.self) { i in
                    Image(systemName: Double(i) + 0.5 <= value ? "star.fill" : (Double(i) < value ? "star.leadinghalf.filled" : "star"))
                        .foregroundColor(.white)
                }
            }
        } else {
            Text(item.detail ?? "")
                .font(.system(size: 17))
                .foregroundColor(.white)
        }
    }
}

struct CPTextButtonView: View {
    @ObservedObject var session: GuestSession
    let button: CPTextButton

    var body: some View {
        Button {
            session.tap(handlerOf: button, label: button.title)
        } label: {
            Text(button.title)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(CPCapsuleButtonStyle(prominent: button.textStyle == .confirm))
        .foregroundColor(button.textStyle == .cancel ? .red : .white)
    }
}

// MARK: - Contatto

struct CPContactView: View {
    @ObservedObject var session: GuestSession
    let contact: CPContactTemplate

    var body: some View {
        let c = contact.contact
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            if let img = c.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
            } else {
                Circle().fill(Color(white: 0.35)).frame(width: 96, height: 96)
                    .overlay(Image(systemName: "person.fill").font(.system(size: 44)).foregroundColor(.white))
            }
            Text(c.name)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white)
            if let s = c.subtitle { Text(s).font(.system(size: 15)).foregroundColor(CP.secondaryText) }
            if let i = c.informativeText { Text(i).font(.system(size: 14)).foregroundColor(CP.tertiaryText) }
            HStack(spacing: 22) {
                ForEach(Array((c.actions ?? []).enumerated()), id: \.offset) { _, action in
                    Button {
                        session.tap(handlerOf: action, label: "Contatto")
                    } label: {
                        VStack(spacing: 6) {
                            Circle()
                                .fill(CP.buttonFill)
                                .frame(width: 58, height: 58)
                                .overlay(
                                    Group {
                                        if let img = action.image {
                                            Image(uiImage: img).renderingMode(.template).resizable().scaledToFit().frame(width: 26, height: 26)
                                        } else {
                                            Image(systemName: symbol(for: action)).font(.system(size: 22))
                                        }
                                    }
                                    .foregroundColor(.white)
                                )
                            Text(action.title ?? "")
                                .font(.system(size: 13))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!action.isEnabled)
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func symbol(for button: CPButton) -> String {
        switch button {
        case is CPContactCallButton: return "phone.fill"
        case is CPContactMessageButton: return "message.fill"
        case is CPContactDirectionsButton: return "car.fill"
        default: return "circle.fill"
        }
    }
}

// MARK: - Ricerca

struct CPSearchView: View {
    @ObservedObject var session: GuestSession
    let search: CPSearchTemplate
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(CP.secondaryText)
                TextField("Cerca", text: $session.searchText)
                    .focused($focused)
                    .submitLabel(.search)
                    .foregroundColor(.white)
                    .onSubmit {
                        if let d = search.delegate {
                            session.guest("Cerca") { CPSObjC.send(d, NSSelectorFromString("searchTemplateSearchButtonPressed:"), search) }
                        }
                    }
                    .onChange(of: session.searchText) { update($0) }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 10).fill(CP.buttonFill))
            .padding(12)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(session.searchResults.enumerated()), id: \.offset) { _, item in
                        Button {
                            choose(item)
                        } label: {
                            CPListRow(session: session, item: item)
                                .allowsHitTesting(false)
                        }
                        .buttonStyle(CPRowButtonStyle())
                        Rectangle().fill(CP.separator).frame(height: 0.5).padding(.leading, CP.horizontalPadding)
                    }
                }
            }
        }
        .onAppear {
            focused = true
            update(session.searchText)
        }
    }

    private func update(_ text: String) {
        guard let d = search.delegate else { return }
        let completion = CPSObjC.makeListCompletion { [weak session] items in
            session?.searchResults = items.compactMap { $0 as? CPListItem }
        }
        session.guest("Cerca") {
            CPSObjC.send(d, NSSelectorFromString("searchTemplate:updatedSearchText:completionHandler:"), search, text, completion)
        }
    }

    private func choose(_ item: CPListItem) {
        guard let d = search.delegate else { return }
        let completion = CPSObjC.makeVoidCompletion {}
        session.guest("Risultato") {
            CPSObjC.send(d, NSSelectorFromString("searchTemplate:selectedResult:completionHandler:"), search, item, completion)
        }
    }
}

// MARK: - Template presentati (alert, action sheet, voce)

struct CPPresentedView: View {
    @ObservedObject var session: GuestSession
    let template: CPTemplate

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            if let alert = template as? CPAlertTemplate {
                card(title: alert.titleVariants.first ?? "", message: nil, actions: alert.actions)
            } else if let sheet = template as? CPActionSheetTemplate {
                card(title: sheet.title ?? "", message: sheet.message, actions: sheet.actions)
            } else if let voice = template as? CPVoiceControlTemplate {
                voiceView(voice)
            } else {
                CPTemplateContent(session: session, template: template)
                    .background(CP.background)
            }
        }
    }

    private func card(title: String, message: String?, actions: [CPAlertAction]) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                if let m = message, !m.isEmpty {
                    Text(m)
                        .font(.system(size: 15))
                        .foregroundColor(CP.secondaryText)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(18)
            VStack(spacing: 8) {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    Button {
                        if CPSObjC.handler(of: action) != nil {
                            session.tap(handlerOf: action, label: action.title)
                        } else {
                            session.dismissPresented()
                        }
                    } label: {
                        Text(action.title)
                            .font(.system(size: 17, weight: action.style == .cancel ? .semibold : .regular))
                            .foregroundColor(action.style == .destructive ? .red : .white)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(CP.buttonFill))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding([.horizontal, .bottom], 14)
        }
        .frame(width: 360)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(CP.panel))
    }

    private func titles(_ state: CPVoiceControlState?) -> [String]? {
        let t: [String]? = state?.titleVariants
        return t
    }

    private func voiceView(_ voice: CPVoiceControlTemplate) -> some View {
        let state = voice.voiceControlStates.first { $0.identifier == voice.activeStateIdentifier } ?? voice.voiceControlStates.first
        return VStack(spacing: 16) {
            if let img = state?.image {
                Image(uiImage: img).resizable().scaledToFit().frame(width: 90, height: 90)
            } else {
                Circle()
                    .fill(AngularGradient(colors: [.pink, .purple, .blue, .cyan, .pink], center: .center))
                    .frame(width: 80, height: 80)
            }
            Text(titles(state)?.first ?? "")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            Button("Annulla") { session.dismissPresented() }
                .buttonStyle(CPCapsuleButtonStyle())
        }
    }
}
