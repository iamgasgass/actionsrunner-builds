import SwiftUI

/// Schermata Home in stile CarPlay: griglia di icone a pagine con indicatore di pagina.
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: AppLibrary

    private var items: [HomeItem] {
        CarApp.homeOrder.map { HomeItem.builtin($0) } + library.apps.map { HomeItem.guest($0.id) }
    }

    var body: some View {
        GeometryReader { geo in
            let columns = geo.size.width > 900 ? 6 : (geo.size.width > 620 ? 5 : 4)
            let rows = 2
            let perPage = columns * rows
            let all = items
            let pages = stride(from: 0, to: all.count, by: perPage).map { Array(all[$0..<min($0 + perPage, all.count)]) }
            let cellWidth = geo.size.width / CGFloat(columns)
            let iconSize = min(80, max(52, min(cellWidth - 34, (geo.size.height - 40) / CGFloat(rows) - 46)))

            VStack(spacing: 0) {
                TabView(selection: $state.homePage) {
                    ForEach(pages.indices, id: \.self) { index in
                        VStack(spacing: 0) {
                            ForEach(0..<rows, id: \.self) { row in
                                HStack(spacing: 0) {
                                    ForEach(0..<columns, id: \.self) { col in
                                        let i = row * columns + col
                                        if i < pages[index].count {
                                            HomeIconButton(item: pages[index][i], size: iconSize)
                                                .frame(width: cellWidth)
                                        } else {
                                            Color.clear.frame(width: cellWidth, height: 1)
                                        }
                                    }
                                }
                                .frame(maxHeight: .infinity)
                            }
                        }
                        .padding(.vertical, 10)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                if pages.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(pages.indices, id: \.self) { i in
                            Circle()
                                .fill(Color.white.opacity(i == state.homePage ? 1 : 0.35))
                                .frame(width: 7, height: 7)
                        }
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }
}

struct HomeIconButton: View {
    let item: HomeItem
    let size: CGFloat
    @EnvironmentObject var state: AppState
    @EnvironmentObject var library: AppLibrary

    var body: some View {
        Button {
            state.open(item)
        } label: {
            VStack(spacing: 7) {
                HomeIconView(item: item, size: size)
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: size + 24)
            }
        }
        .buttonStyle(PressableStyle())
    }

    private var title: String {
        switch item {
        case .builtin(let app): return app.title
        case .guest(let id): return library.app(id: id)?.name ?? "App"
        }
    }
}
