import SwiftUI
import AppKit

/// Ad-Owl's look: a violet-to-magenta backdrop with frosted cards.
enum Owl {
    static let pink = Color(hex: 0xFF5AD2)
    static let violet = Color(hex: 0x9B2FE6)
    static let amber = Color(hex: 0xFFB020)
    static let accent = LinearGradient(colors: [Color(hex: 0xFF6AD5), Color(hex: 0x9B2FE6)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
    static let secondaryText = Color.white.opacity(0.7)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: opacity)
    }
}

struct AppBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x2A0D5E), Color(hex: 0x561A9A), Color(hex: 0x9A1FA4)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            RadialGradient(colors: [Color(hex: 0xE040C8, opacity: 0.45), .clear],
                           center: UnitPoint(x: 0.35, y: 0.5), startRadius: 0, endRadius: 560)
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Frosted card used for every panel on the gradient.
    func glassCard(padding: CGFloat = 16) -> some View {
        self.padding(padding)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.10)))
    }
}

/// Small gradient tile holding an SF Symbol.
struct IconTile: View {
    let symbol: String
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Owl.accent, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .shadow(color: Owl.pink.opacity(0.35), radius: 6, y: 2)
    }
}

/// The big round call-to-action at the bottom of the main screen.
struct OrbButton: View {
    let title: String
    var busy = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(0.10), lineWidth: 8).padding(-9)
                Circle().fill(Owl.accent)
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                if busy {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(width: 92, height: 92)
            .shadow(color: Owl.pink.opacity(hover && enabled ? 0.85 : 0.55), radius: hover && enabled ? 30 : 20)
            .scaleEffect(hover && enabled ? 1.04 : 1)
            .opacity(enabled || busy ? 1 : 0.5)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

/// Frosted capsule button for secondary actions.
struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Pill(configuration: configuration) }

    private struct Pill: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(.white.opacity(configuration.isPressed ? 0.24 : 0.13), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
                .opacity(enabled ? 1 : 0.5)
        }
    }
}

/// The app icon, large, with a soft glow: the hero illustration.
struct OwlArt: View {
    /// The icon's 1024px bitmap at 512pt. Icon images otherwise report a tiny point size
    /// (32pt from NSApp, 128pt from the .icns), and SwiftUI upscales that into a blur.
    private static let art: NSImage = {
        guard let icns = Bundle.main.image(forResource: "AppIcon"),
              let best = icns.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) else {
            return NSApp.applicationIconImage
        }
        let image = NSImage(size: NSSize(width: best.pixelsWide / 2, height: best.pixelsHigh / 2))
        image.addRepresentation(best)
        return image
    }()

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFF6AD5, opacity: 0.5), .clear],
                                     center: .center, startRadius: 0, endRadius: 170))
                .scaleEffect(1.3)
            Image(nsImage: Self.art)
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .shadow(color: Color(hex: 0x1A0033, opacity: 0.5), radius: 24, y: 18)
        }
    }
}

/// Title + subtitle header used by every page except the main screen.
struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 30, weight: .light))
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Owl.secondaryText)
            }
            .padding(.horizontal, 32).padding(.top, 48).padding(.bottom, 14)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}
