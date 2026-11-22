import SwiftUI

/// Griglia delle app, a pagine.
struct HomeView: View {
    @EnvironmentObject var state: AppState
    @State private var page = 0

    var body: some View {
        GeometryReader { geo in
            let columns = geo.size.width > 700 ? 5 : 4
            let rows = 2
            let perPage = columns * rows
            let apps = CarApp.homeOrder
            let pages = stride(from: 0, to: apps.count, by: perPage).map { Array(apps[$0..<min($0 + perPage, apps.count)]) }
            let iconSize = min(92, max(56, min(geo.size.width / CGFloat(columns) - 40, geo.size.height / CGFloat(rows) - 70)))

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    ForEach(pages.indices, id: \.self) { index in
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 18) {
                            ForEach(pages[index]) { app in
                                Button {
                                    state.open(app)
                                } label: {
                                    VStack(spacing: 8) {
                                        AppIconView(app: app, size: iconSize)
                                        Text(app.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(.white)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                            .shadow(color: .black.opacity(0.5), radius: 2)
                                    }
                                }
                                .buttonStyle(PressableStyle())
                            }
                        }
                        .padding(.horizontal, 24)
                        .frame(maxHeight: .infinity)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: pages.count > 1 ? .always : .never))
            }
        }
    }
}
