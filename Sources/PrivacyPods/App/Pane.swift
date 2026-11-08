import SwiftUI

/// The layout the Settings and Status windows share: true black, white text, sections separated
/// by hairlines rather than cards. A grouped `Form` keeps its rounded section fills even on a
/// black background, so the windows lay themselves out with these instead.
///
/// The pane has no scroll view: the window takes its size from the content, so nothing is ever
/// below the fold and there is no empty space under the last row.
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

/// A `LabeledContent` as one line of a pane: label left, value or control right, hairline under.
/// Going through `LabeledContent` keeps the label attached to the control for VoiceOver. Values
/// are white like everything else; a view that wants one quieter or louder colours it itself.
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

/// A one-line warning under a row, with the icon carrying the meaning as well as the colour.
struct PaneNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .font(.callout)
            .padding(.vertical, 7)
    }
}

private struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(.white.opacity(0.14))
            .frame(height: 1)
    }
}
