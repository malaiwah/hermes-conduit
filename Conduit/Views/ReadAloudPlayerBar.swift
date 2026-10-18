//
//  ReadAloudPlayerBar.swift
//  Conduit
//
//  While a reply is read aloud, a small player sits where the minimised
//  call bar does (#759): pause and resume, the Read Aloud speed (changeable
//  while it plays) and stop. Tapping it opens a reading view that follows
//  the reply sentence by sentence. The highlight is an estimate: Hermes'
//  speech stream sends no timings (ReadAloudScript).
//

import SwiftUI

struct ReadAloudPlayerBar: View {
    @ObservedObject var controller: MessageReadAloudController
    @State private var showsReading = false
    /// The reply the reading view shows; it stays after playback ends so
    /// the open view does not empty under the reader.
    @State private var shownReading: MessageReadAloudController.NowReading?
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 24

    var body: some View {
        // A VStack rather than a bare `if`, so the sheet keeps its host when
        // the bar leaves at the end of the reply.
        VStack(spacing: 0) {
            if let reading = controller.nowReading {
                row(reading)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: controller.nowReading?.messageID)
        .onChange(of: controller.nowReading, initial: true) { _, reading in
            if let reading { shownReading = reading }
        }
        .sheet(isPresented: $showsReading) {
            if let shownReading {
                ReadAloudReadingView(controller: controller, reading: shownReading)
            }
        }
    }

    private var status: String {
        if case .preparing = controller.state { return AppLocalization.string("Preparing…") }
        return controller.isPaused ? AppLocalization.string("Paused") : AppLocalization.string("Reading aloud")
    }

    private func row(_ reading: MessageReadAloudController.NowReading) -> some View {
        HStack(spacing: 6) {
            Button {
                shownReading = reading
                showsReading = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.conduitAccent)
                        .frame(width: iconWidth)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: reading.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text(AppLocalization.string("Shows the reply as it is read")))

            ReadAloudControls(controller: controller, size: .compact)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .conduitGlassControl(cornerRadius: 20, tint: Color.conduitAccent.opacity(0.10))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// Pause or resume, speed and stop, for the bar and the reading view.
struct ReadAloudControls: View {
    enum Size {
        case compact
        case large
    }

    @ObservedObject var controller: MessageReadAloudController
    let size: Size

    private var isPlaying: Bool {
        if case .playing = controller.state { return true }
        return false
    }

    private var isActive: Bool {
        switch controller.state {
        case .preparing, .playing: return true
        case .idle, .failed: return false
        }
    }

    private var buttonSide: CGFloat { size == .compact ? 44 : 56 }
    private var symbolFont: Font { size == .compact ? .body.weight(.semibold) : .title2.weight(.semibold) }

    var body: some View {
        HStack(spacing: size == .compact ? 0 : 28) {
            Menu {
                Picker(selection: Binding(
                    get: { controller.speed },
                    set: { speed in
                        Haptics.light()
                        controller.setSpeed(speed)
                    }
                )) {
                    ForEach(ReadAloudSpeed.allCases) { speed in
                        Text(verbatim: speed.label).tag(speed)
                    }
                } label: {
                    Text(AppLocalization.string("Speed"))
                }
            } label: {
                Text(verbatim: controller.speed.label)
                    .font((size == .compact ? Font.caption : Font.body).weight(.semibold).monospacedDigit())
                    .frame(minWidth: buttonSide, minHeight: buttonSide)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text(AppLocalization.string("Speed")))
            .accessibilityValue(Text(verbatim: controller.speed.label))

            Button {
                Haptics.light()
                controller.togglePause()
            } label: {
                Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
                    .font(symbolFont)
                    .frame(minWidth: buttonSide, minHeight: buttonSide)
                    .contentShape(Rectangle())
            }
            .disabled(!isPlaying)
            .accessibilityLabel(controller.isPaused
                ? Text(AppLocalization.string("Resume reading response"))
                : Text(AppLocalization.string("Pause reading response")))

            Button {
                Haptics.medium()
                controller.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(symbolFont)
                    .frame(minWidth: buttonSide, minHeight: buttonSide)
                    .contentShape(Rectangle())
            }
            .disabled(!isActive)
            .accessibilityLabel(Text(AppLocalization.string("Stop reading response")))
        }
        .foregroundStyle(Color.conduitAccent)
    }
}

/// The reply being read, highlighted sentence by sentence as the voice is
/// estimated to reach it.
struct ReadAloudReadingView: View {
    @ObservedObject var controller: MessageReadAloudController
    let reading: MessageReadAloudController.NowReading
    @Environment(\.dismiss) private var dismiss
    @State private var current: Int?
    /// When the reader last scrolled by hand: following the voice waits a
    /// few seconds after that, so re-reading isn't snapped back.
    @State private var lastManualScroll: Date?

    private struct Paragraph: Identifiable {
        let id: Int
        let segments: [ReadAloudScript.Segment]
    }

    private var paragraphs: [Paragraph] {
        var result: [Paragraph] = []
        for segment in reading.script.segments {
            if let last = result.last, last.id == segment.paragraph {
                result[result.count - 1] = Paragraph(id: last.id, segments: last.segments + [segment])
            } else {
                result.append(Paragraph(id: segment.paragraph, segments: [segment]))
            }
        }
        return result
    }

    private var isReadingThis: Bool {
        controller.nowReading?.messageID == reading.messageID
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(paragraphs) { paragraph in
                            paragraphView(paragraph)
                                .id(paragraph.id)
                        }
                        Text(AppLocalization.string("The highlight is an estimate of where the voice is, so it can run a little ahead or behind."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in
                    lastManualScroll = Date()
                })
                .onChange(of: current) { _, index in
                    guard let index, reading.script.segments.indices.contains(index) else { return }
                    if let lastManualScroll, Date().timeIntervalSince(lastManualScroll) < 5 { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(reading.script.segments[index].paragraph, anchor: UnitPoint(x: 0.5, y: 0.35))
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ReadAloudControls(controller: controller, size: .large)
                    .disabled(!isReadingThis)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
            .navigationTitle(Text(verbatim: reading.title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text(AppLocalization.string("Done")) }
                }
            }
        }
        .task(id: reading.messageID) {
            // The audio gives no events to follow, so the estimate is read
            // a few times a second; the view redraws only when it moves on.
            while !Task.isCancelled {
                let index = isReadingThis ? controller.followAlongIndex() : nil
                if index != current {
                    withAnimation(.easeInOut(duration: 0.25)) { current = index }
                }
                // Once this reply has ended nothing can move; check rarely in
                // case it is played again.
                try? await Task.sleep(for: .milliseconds(isReadingThis ? 150 : 1_000))
            }
        }
    }

    @ViewBuilder
    private func paragraphView(_ paragraph: Paragraph) -> some View {
        if paragraph.segments.count == 1, let code = paragraph.segments.first, code.kind == .code {
            VStack(alignment: .leading, spacing: 6) {
                Text(AppLocalization.string("Code"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(verbatim: code.text)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
        } else {
            Text(attributed(paragraph))
                .font(.title3)
                .lineSpacing(4)
                .textSelection(.enabled)
                // The highlight is colour; VoiceOver hears which paragraph
                // the voice is in.
                .accessibilityValue(isSpeaking(paragraph) ? Text(AppLocalization.string("Reading aloud")) : Text(verbatim: ""))
        }
    }

    private func isSpeaking(_ paragraph: Paragraph) -> Bool {
        guard let current else { return false }
        return paragraph.segments.contains { $0.id == current }
    }

    /// The paragraph's sentences as running text: the one being spoken
    /// marked, the ones already heard dimmed.
    private func attributed(_ paragraph: Paragraph) -> AttributedString {
        var text = AttributedString()
        for (offset, segment) in paragraph.segments.enumerated() {
            if offset > 0 { text += AttributedString(" ") }
            var sentence = AttributedString(segment.text)
            if let current {
                if segment.id == current {
                    sentence.backgroundColor = Color.conduitAccent.opacity(0.22)
                } else if segment.id < current {
                    sentence.foregroundColor = .secondary
                }
            }
            text += sentence
        }
        return text
    }
}
