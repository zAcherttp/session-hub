import SwiftUI

// Liquid Glass on macOS 26+, standard materials before that.
// Per Apple's guidance, glass is reserved for the control layer (toolbar, floating bars, buttons);
// content — columns and cards — stays opaque so glass never sits on glass.

extension View {
    @ViewBuilder
    func glassPanel(in shape: some Shape, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08)))
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }

    /// Lets glass elements that share an id morph into each other as they appear and disappear.
    @ViewBuilder
    func glassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26, *) { glassEffectID(id, in: namespace) } else { self }
    }

    /// Drops the opaque toolbar strip so the toolbar's glass controls float over the content beneath.
    @ViewBuilder
    func floatingToolbar() -> some View {
        if #available(macOS 15, *) { toolbarBackgroundVisibility(.hidden, for: .windowToolbar) } else { self }
    }

    /// Extends this view's content (mirrored and blurred) underneath the floating sidebar, so the
    /// sidebar's glass picks up the content's color, as Music does with its artwork.
    @ViewBuilder
    func extendsUnderSidebar() -> some View {
        if #available(macOS 26, *) { backgroundExtensionEffect() } else { self }
    }

    /// Soft fade where scrolling content meets the toolbar.
    @ViewBuilder
    func softScrollEdge() -> some View {
        if #available(macOS 26, *) { scrollEdgeEffectStyle(.soft, for: .top) } else { self }
    }
}

/// Groups nearby glass shapes so they render and blend as one (a `GlassEffectContainer` on macOS 26).
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

enum Metrics {
    /// Margin between the board and the window edges (and between columns).
    static let windowPadding: CGFloat = 12
    /// Concentric radii: card radius = column radius − column padding.
    static let columnRadius: CGFloat = 20
    static let columnPadding: CGFloat = 8
    static let cardRadius: CGFloat = columnRadius - columnPadding
    /// Inset of buttons inside a dock capsule; equal on top, bottom and trailing keeps the
    /// button capsule concentric with the dock capsule.
    static let dockInset: CGFloat = 6
    /// Keeps the last cards scrollable above the floating dock.
    static let dockClearance: CGFloat = 76
}
