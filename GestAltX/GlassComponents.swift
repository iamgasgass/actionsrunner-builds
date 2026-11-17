//
//  GlassComponents.swift
//  GestAltX
//
//  Controlli di GestAltX (interruttori, selettori, gruppi di righe) costruiti
//  con le stesse primitive Liquid Glass di GlassUI.swift.
//

import SwiftUI

/// Righe impilate in un riquadro di vetro interno, separate da `GlassDivider`
/// (stesso aspetto dell'elenco di KeyValueEditor in ActionsRunner).
struct GlassRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                    if index > 0 { GlassDivider() }
                    subview
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .liquidGlassCard(cornerRadius: 18, borderOpacity: 0.10, shadow: false)
    }
}

/// Scheda di sezione: intestazione con simbolo, righe di vetro e nota a piè di pagina.
struct GlassCardSection<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSectionHeading(title: title, subtitle: subtitle, symbol: symbol)
            GlassRows { content }
            footer
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassSection()
    }
}

extension GlassCardSection where Footer == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.content = content()
        self.footer = EmptyView()
    }
}

/// Selettore a menu su una riga: titolo a sinistra, valore scelto a destra.
struct GlassPickerRow<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    @ViewBuilder var content: Content

    init(_ title: String, selection: Binding<SelectionValue>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._selection = selection
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Picker(title, selection: $selection) { content }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.secondary)
        }
    }
}

/// Gruppo espandibile dentro un riquadro di vetro.
struct GlassDisclosure<Content: View>: View {
    let title: String
    var symbol: String? = nil
    @ViewBuilder var content: Content
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.22)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                    }
                    Text(title)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Group(subviews: content) { subviews in
                        ForEach(subviews) { subview in
                            GlassDivider().padding(.top, 10)
                            subview
                                .padding(.top, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }
}

/// Avviso di rischio elevato accanto al titolo di un interruttore.
struct GlassRiskBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .accessibilityLabel("High Risk")
    }
}

extension View {
    /// Interruttore delle righe di vetro (traccia verde di sistema, leggibile in chiaro e scuro).
    func glassToggle() -> some View {
        self
            .toggleStyle(.switch)
            .tint(.green)
            .font(.system(.body, design: .rounded))
    }
}
