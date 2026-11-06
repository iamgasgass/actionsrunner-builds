import SwiftUI

/// Layout in stile app ChatGPT per iOS: chat a schermo intero con menu laterale
/// che scorre da sinistra (tap sull'icona o swipe dal bordo).
struct RootView: View {
    @Environment(AppState.self) private var app
    @State private var sidebarOpen = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        @Bindable var app = app
        GeometryReader { geo in
            let width = min(geo.size.width * 0.84, 360)
            let offset = max(0, min(width, (sidebarOpen ? width : 0) + dragOffset))

            ZStack(alignment: .leading) {
                SidebarView(close: { setSidebar(false) })
                    .frame(width: width)

                NavigationStack {
                    ChatView(openSidebar: { setSidebar(true) })
                }
                .background(Color(.systemBackground))
                .overlay {
                    Color.black
                        .opacity(Double(offset / width) * 0.25)
                        .ignoresSafeArea()
                        .allowsHitTesting(sidebarOpen)
                        .onTapGesture { setSidebar(false) }
                }
                .shadow(color: .black.opacity(offset > 0 ? 0.12 : 0), radius: 12)
                .offset(x: offset)
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        let horizontal = abs(value.translation.width) > abs(value.translation.height)
                        guard horizontal else { return }
                        if sidebarOpen {
                            dragOffset = min(0, value.translation.width)
                        } else if value.startLocation.x < 40 {
                            dragOffset = max(0, value.translation.width)
                        }
                    }
                    .onEnded { value in
                        let predicted = value.predictedEndTranslation.width
                        if sidebarOpen {
                            setSidebar(!(predicted < -width / 3))
                        } else if value.startLocation.x < 40 {
                            setSidebar(predicted > width / 3)
                        }
                        dragOffset = 0
                    }
            )
        }
        .sheet(isPresented: $app.showSettings) {
            SettingsView()
        }
    }

    private func setSidebar(_ open: Bool) {
        if open { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            sidebarOpen = open
            dragOffset = 0
        }
    }
}
