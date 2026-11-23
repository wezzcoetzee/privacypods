import SwiftUI

/// A grouped `Form` keeps rounded fills on black, hence these; no scroll view, so the window sizes to its content.
struct Pane<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) { content }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
            .frame(width: width, alignment: .leading)
            .background(Color.black)
            .foregroundStyle(.white)
            .labeledContentStyle(PaneRowStyle())
            .preferredColorScheme(.dark)
    }
}

struct PaneSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            Hairline()
            content
        }
    }
}

/// Uses `LabeledContent` so VoiceOver keeps the label attached to the control.
private struct PaneRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                configuration.content
                    .monospacedDigit()
            }
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            Hairline()
        }
    }
}

struct PaneNotice: View {
    enum Tone {
        case warning, info
    }

    let text: String
    var tone: Tone = .warning

    var body: some View {
        Label(text, systemImage: tone == .warning ? "exclamationmark.triangle.fill" : "info.circle")
            .foregroundStyle(tone == .warning ? Color.orange : .white)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 7)
    }
}

struct PaneLead: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 7)
            Hairline()
        }
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(height: 1)
    }
}
