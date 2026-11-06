import SwiftUI
import PhotosUI
import UIKit

struct InputBar: View {
    @Environment(AppState.self) private var app
    @Binding var text: String
    @Binding var imageData: Data?
    var focused: FocusState<Bool>.Binding
    var onSend: () -> Void
    var onOptions: () -> Void

    @State private var pickerItem: PhotosPickerItem?

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageData != nil
    }

    var body: some View {
        @Bindable var settings = app.settings
        VStack(alignment: .leading, spacing: 8) {
            // Allegato immagine
            if let data = imageData, let image = UIImage(data: data) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Button {
                        imageData = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.7))
                            .font(.system(size: 20))
                    }
                    .offset(x: 6, y: -6)
                }
                .padding(.leading, 4)
            }

            TextField("Chiedi qualsiasi cosa", text: $text, axis: .vertical)
                .lineLimit(1...8)
                .font(.body)
                .focused(focused)
                .padding(.horizontal, 6)
                .padding(.top, 4)

            HStack(spacing: 10) {
                // Menu "+"
                Menu {
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Label("Foto", systemImage: "photo")
                    }
                    Toggle(isOn: $settings.webSearch) {
                        Label("Cerca sul web", systemImage: "globe")
                    }
                    Toggle(isOn: $settings.focusMode) {
                        Label("Modalità focus", systemImage: "scope")
                    }
                    Button(action: onOptions) {
                        Label("Tono e formato", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 36, height: 36)
                        .background(Circle().stroke(Color(.separator), lineWidth: 1))
                }
                .foregroundStyle(.primary)

                if settings.webSearch {
                    chip("Cerca", icon: "globe") { settings.webSearch = false }
                }
                if settings.focusMode {
                    chip("Focus", icon: "scope") { settings.focusMode = false }
                }

                Spacer()

                // Invio / Stop
                if app.isStreaming {
                    Button {
                        app.stopStreaming()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.primary))
                    }
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.primary.opacity(canSend ? 1 : 0.25)))
                    }
                    .disabled(!canSend)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .onChange(of: pickerItem) {
            guard let item = pickerItem else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    imageData = InputBar.compress(data)
                }
                pickerItem = nil
            }
        }
    }

    private func chip(_ title: String, icon: String, remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Ridimensiona a max 1280px e comprime in JPEG per contenere la dimensione della richiesta.
    static func compress(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 1280
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: 0.75)
    }
}
