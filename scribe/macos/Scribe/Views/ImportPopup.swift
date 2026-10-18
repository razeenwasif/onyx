import SwiftUI

/// The popup shown while PDFs import: a little stack of pages that shuffles
/// while it works, the page count, then a tick. Shared by the Mac and the
/// iPad; `dismiss` is called once it has shown the result.
struct ImportPopup: View {
    let progress: ImportProgress
    var accent: Color
    var text: Color
    var muted: Color
    var card: Color
    let dismiss: () -> Void

    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.35 : 0)
                .ignoresSafeArea()
                .onTapGesture { if isFinished { close() } }

            VStack(spacing: 18) {
                PageStack(working: !isFinished, done: progress.phase == .done, failed: isFailed, accent: accent)
                    .frame(width: 92, height: 92)

                VStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(text)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    // Ticks each second so a wait counts down.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(detail(at: context.date))
                            .font(.callout)
                            .foregroundStyle(muted)
                            .multilineTextAlignment(.center)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }

                if !isFinished {
                    ProgressView(value: progress.fraction)
                        .tint(accent)
                        .frame(width: 220)
                        .animation(.easeOut(duration: 0.25), value: progress.fraction)
                } else if isFailed {
                    Button("OK", action: close)
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(width: 320)
            .background(card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(.white.opacity(0.07)))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
            .scaleEffect(shown ? 1 : 0.86)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.4, bounce: 0.3)) { shown = true }
        }
        .onChange(of: progress.phase) { _, phase in
            // A moment to see the tick, then out of the way.
            if phase == .done {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { close() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
    }

    private var isFinished: Bool {
        switch progress.phase {
        case .done, .failed: true
        default: false
        }
    }

    private var isFailed: Bool {
        if case .failed = progress.phase { true } else { false }
    }

    private var title: String {
        switch progress.phase {
        case .reading, .pages: "Importing “\(progress.file)”"
        case .done:
            progress.made.count == 1 ? "Imported “\(progress.file)”" : "Imported \(progress.made.count) notebooks"
        case .failed: "Import didn’t finish"
        }
    }

    private func detail(at now: Date) -> String {
        if let until = progress.waitingUntil, !isFinished {
            let left = max(0, Int(until.timeIntervalSince(now).rounded()))
            return "Microsoft asked to slow down · carrying on in \(left / 60):\(String(format: "%02d", left % 60))"
        }
        let skipped = progress.alreadyHere > 0 ? " · \(progress.alreadyHere) already imported" : ""
        return base + (progress.phase == .pages ? skipped : "")
    }

    private var base: String {
        switch progress.phase {
        case .reading:
            progress.fileCount > 1
                ? "\(progress.unit.capitalized) \(progress.fileIndex + 1) of \(progress.fileCount)"
                : (progress.unit == "file" ? "Opening the PDF…" : "Fetching the page list…")
        case .pages:
            "Page \(progress.page) of \(progress.pageCount)"
                + (progress.fileCount > 1 ? " · \(progress.unit) \(progress.fileIndex + 1) of \(progress.fileCount)" : "")
        case .done:
            progress.pagesMade == 1 ? "1 page, ready to write on" : "\(progress.pagesMade) pages, ready to write on"
        case .failed(let message):
            message
        }
    }

    private func close() {
        withAnimation(.easeIn(duration: 0.2)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { dismiss() }
    }
}

/// Three pages that shuffle while importing and settle into a tick.
private struct PageStack: View {
    let working: Bool
    let done: Bool
    let failed: Bool
    let accent: Color

    @State private var shuffle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(red: 0x2C / 255, green: 0x27 / 255, blue: 0x32 / 255))
                    .overlay(lines.padding(10))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.12)))
                    .frame(width: 52, height: 68)
                    .rotationEffect(.degrees(angle(i)))
                    .offset(x: offset(i), y: working && shuffle && i == 2 ? -8 : 0)
                    .opacity(done || failed ? 0.35 : 1)
            }
            if done || failed {
                Image(systemName: done ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(done ? accent : .orange)
                    .background(Circle().fill(.black.opacity(0.4)).padding(4))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.45), value: done || failed)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { shuffle = true }
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<4) { j in
                Capsule().fill(accent.opacity(j == 0 ? 0.8 : 0.35)).frame(width: j == 3 ? 16 : 30, height: 2.5)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func angle(_ i: Int) -> Double {
        let spread: Double = working && shuffle ? 12 : 7
        return Double(i - 1) * spread
    }

    private func offset(_ i: Int) -> CGFloat {
        CGFloat(i - 1) * (working && shuffle ? 14 : 9)
    }
}
