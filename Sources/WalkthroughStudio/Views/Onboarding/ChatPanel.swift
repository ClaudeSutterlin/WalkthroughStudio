import SwiftUI

/// The playback chat (ON-9.1 to 9.8): the conversation about the video on the stage,
/// with citations as chips, tool calls as small rows, jump proposals as buttons and
/// contradictions as amber cards.
///
/// Native rather than in the hub's web view for the reason the companion is: a reply
/// that streams in, with buttons that drive the player, is app chrome.
struct ChatPanel: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var session: ChatSession
    @FocusState private var inputFocused: Bool

    /// Amber for flags: the one colour in the panel that means "the package may be
    /// wrong here", so it is not the brand coral.
    static let amber = Color(red: 0.96, green: 0.70, blue: 0.20)

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if session.items.isEmpty && session.live.isEmpty {
                            emptyState
                        }
                        ForEach(session.items) { item in row(item) }
                        ForEach(session.live) { item in row(item) }
                        if session.isAnswering {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Answering…").font(.caption).foregroundStyle(Brand.muted)
                            }
                        }
                        Color.clear.frame(height: 1).id("chat-bottom")
                    }
                    .padding(12)
                }
                .onChange(of: session.items.count) { _, _ in proxy.scrollTo("chat-bottom") }
                .onChange(of: session.live) { _, _ in proxy.scrollTo("chat-bottom") }
            }
            Divider()
            input
        }
        .background(Brand.cream)
        .onChange(of: vm.chatFocusRequest) { _, _ in inputFocused = true }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ item: ChatItem) -> some View {
        switch item.kind {
        case .question(let text, let t):
            VStack(alignment: .trailing, spacing: 2) {
                Text(PlaybackClock.timecode(t))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Brand.muted)
                Text(text)
                    .font(.callout)
                    .foregroundStyle(Brand.charcoal)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Brand.soft)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)

        case .answer(let parsed):
            answer(parsed)

        case .tool(let label):
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                Text(label).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption2)
            .foregroundStyle(Brand.muted)

        case .jump(let t, let why):
            Button {
                if let id = vm.currentVideoID {
                    vm.open(anchor: "video:\(id)#t=\(PackageTools.seconds(t))")
                }
            } label: {
                Label("Jump to \(PlaybackClock.timecode(t))" + (why.isEmpty ? "" : ": \(why)"),
                      systemImage: "arrow.uturn.forward")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Brand.coral)
                    .foregroundStyle(Brand.cream)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)

        case .flag(let claim, let reason, let anchor):
            VStack(alignment: .leading, spacing: 4) {
                Label("Flagged for the package author", systemImage: "flag.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.charcoal)
                Text("The narration says: \(claim)")
                    .font(.caption)
                    .foregroundStyle(Brand.charcoal)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The code shows: \(reason)")
                    .font(.caption)
                    .foregroundStyle(Brand.charcoal)
                    .fixedSize(horizontal: false, vertical: true)
                if !anchor.isEmpty { chip(anchor, resolved: session.resolves(anchor)) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChatPanel.amber.opacity(0.22))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(ChatPanel.amber, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .notice(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle.fill").foregroundStyle(Brand.coral)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Brand.charcoal)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Text runs and chips, flowed. SwiftUI has no inline buttons inside `Text`, so
    /// the reply is paragraphs of text with each paragraph's chips beneath it, in
    /// order. A chip that does not resolve is plain text with a warning glyph.
    private func answer(_ parsed: CitationParser.Parsed) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(ChatPanel.paragraphs(parsed.runs).enumerated()), id: \.offset) { _, paragraph in
                VStack(alignment: .leading, spacing: 4) {
                    if !paragraph.text.isEmpty {
                        Text(paragraph.text)
                            .font(.callout)
                            .foregroundStyle(Brand.charcoal)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !paragraph.chips.isEmpty {
                        ChipFlow(spacing: 4) {
                            ForEach(Array(paragraph.chips.enumerated()), id: \.offset) { _, chip in
                                self.chip(chip.anchor, label: chip.label, resolved: chip.resolved)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    struct Paragraph {
        var text: String
        var chips: [(anchor: String, label: String, resolved: Bool)]
    }

    /// Splits runs at blank lines. A citation's label stays in the sentence (so the
    /// prose still reads), and the chip that opens it follows the paragraph.
    static func paragraphs(_ runs: [CitationParser.Run]) -> [Paragraph] {
        var out: [Paragraph] = []
        var current = Paragraph(text: "", chips: [])
        func close() {
            current.text = current.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !current.text.isEmpty || !current.chips.isEmpty { out.append(current) }
            current = Paragraph(text: "", chips: [])
        }
        for run in runs {
            switch run {
            case .text(let text):
                let pieces = text.components(separatedBy: "\n\n")
                for (index, piece) in pieces.enumerated() {
                    if index > 0 { close() }
                    current.text += piece
                }
            case .citation(let anchor, let label, let resolved):
                current.text += resolved ? label : label + " ⚠︎"
                if resolved { current.chips.append((anchor, label, resolved)) }
            }
        }
        close()
        return out
    }

    private func chip(_ anchor: String, label: String? = nil, resolved: Bool) -> some View {
        Button {
            vm.open(anchor: anchor)
        } label: {
            Text(label ?? MarkdownLite.anchorLabel(anchor))
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Brand.soft)
                .foregroundStyle(Brand.coral)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!resolved)
        .help(anchor)
    }

    // MARK: Input

    private var emptyState: some View {
        Text("Ask about what is on screen. The assistant has read what the narration has said so "
             + "far, the code in the shot and the package around it. ? jumps here.")
            .font(.caption)
            .foregroundStyle(Brand.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var input: some View {
        VStack(alignment: .leading, spacing: 6) {
            if vm.pausedForChat {
                HStack(spacing: 6) {
                    Text("Paused while you ask.")
                        .font(.caption2)
                        .foregroundStyle(Brand.muted)
                    Button("Resume") { vm.resumeAfterChat() }
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }
            HStack(spacing: 6) {
                TextField("Ask about this moment…", text: $session.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .onChange(of: session.draft) { _, text in
                        if !text.isEmpty { vm.pauseForTyping() }
                    }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Brand.coral)
                }
                .buttonStyle(.plain)
                .disabled(session.isAnswering
                          || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if session.spentUSD > 0 {
                Text("This chat: " + SpendMeter.format(session.spentUSD) + " (estimate)")
                    .font(.caption2)
                    .foregroundStyle(Brand.muted)
            }
        }
        .padding(10)
        .background(Brand.cream)
    }

    private func send() {
        let text = session.draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !session.isAnswering else { return }
        vm.ask(text)
    }
}

/// Lays chips out left to right, wrapping.
struct ChipFlow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: min(widest, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
