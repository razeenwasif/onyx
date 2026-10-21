import SwiftUI
import UIKit

/// A `[[scribe:…]]` link on a line of its own, shown as a card (the
/// desktop's lib/scribe-cards.ts): the page, or the lassoed area of it, as
/// Scribe draws it, with its title, notebook and Open in Scribe. Links
/// inside a sentence stay links.
struct InkCard: View {
    let link: ScribeLink
    let page: LinkedPage
    let label: String?
    let store: VaultStore
    @State private var image: UIImage?
    @State private var failed = false

    /// Pictures are drawn this many pixels wide (the column at 2×).
    static let pixels = 1300

    /// A line that is nothing but a Scribe link: its target and title.
    static func parse(line: String) -> (target: String, label: String?)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        var body = Substring(t)
        if body.hasPrefix("!") { body = body.dropFirst() }
        guard body.hasPrefix("[["), body.hasSuffix("]]") else { return nil }
        let inner = body.dropFirst(2).dropLast(2)
        guard !inner.contains("[["), !inner.contains("]]") else { return nil }
        let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
        guard let target = parts.first, ScribeLink(target: target) != nil else { return nil }
        return (target, parts.count > 1 ? parts[1] : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            Button { store.openScribe?(link) } label: { picture }
                .buttonStyle(.plain)
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2).fill(Color.evInk).frame(width: 9, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label?.isEmpty == false ? label! : page.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.evFg)
                    Text(meta).font(.system(size: 12.5)).foregroundStyle(Color.evSubtle)
                }
                Spacer(minLength: 8)
                Button { store.openScribe?(link) } label: {
                    HStack(spacing: 6) {
                        Text("Open in Scribe")
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(uiColor: UIColor(hex: "#F4B8A0")))
                    .padding(.horizontal, 13)
                    .frame(height: 34)
                    .background(Color.evInk.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.evBgAlt)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.evInk.opacity(0.28)))
        .padding(.vertical, 4)
        .task(id: "\(page.id)\(page.modified)\(link.area.map { "\($0)" } ?? "")") { await load() }
    }

    @ViewBuilder
    private var picture: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: Velvet.page)
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                if link.area == nil {
                    // A whole page shows its top; the fade says there's more.
                    LinearGradient(colors: [.clear, Color(uiColor: Velvet.page).opacity(0.92)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 48)
                }
            } else {
                Text(failed ? "Scribe couldn't draw this page" : "Drawing the page…")
                    .font(.footnote)
                    .foregroundStyle(Color.evSubtle)
                    .frame(height: 120)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var meta: String {
        let place = [page.notebook, page.section].filter { !$0.isEmpty }.joined(separator: " · ")
        return "Scribe" + (place.isEmpty ? "" : " · \(place)") + (link.area != nil ? " · a lassoed area" : "")
    }

    private func load() async {
        let path = page.path, id = page.id, area = link.area
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ink-cards", isDirectory: true)
        let file = await Task.detached(priority: .userInitiated) {
            PageCards.image(page: path, id: id, area: area, pixels: Self.pixels, folder: folder)
        }.value
        if let file, let picture = UIImage(contentsOfFile: file) {
            image = picture
        } else {
            failed = true
        }
    }
}
