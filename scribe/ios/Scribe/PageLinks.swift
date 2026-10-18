import SwiftUI
import UIKit

/// Links between Scribe pages and Electron's notes on the iPad, as on the
/// Mac (see ScribeLink and scribe-core links.rs): copy a link to a page or a
/// lassoed area to paste into a note, open the page or area a note links
/// to, and list the notes that link to the open page.
extension Store {
    /// Copies a link to the lassoed area, or to the whole page when nothing
    /// is selected (or `wholePage`).
    func copyLink(wholePage: Bool = false) {
        guard let doc else { return }
        let area = wholePage ? nil : selectionBounds?.insetBy(dx: -16, dy: -16)
        UIPasteboard.general.string = ScribeLink(pageId: doc.id, area: area).markdown(title: doc.title)
    }

    /// Opens the page a link names (and, for an area, shows it). Looked up
    /// off the main thread: the first lookup after an update reads every
    /// page once.
    func showLinked(_ link: ScribeLink) {
        guard let root else { return }
        let rootPath = root.path
        Task.detached(priority: .userInitiated) { [weak self] in
            let path = (try? Core.call("page_with_id", ["root": rootPath, "id": link.pageId], as: String?.self)) ?? nil
            await MainActor.run {
                guard let self else { return }
                guard let path else {
                    self.problem = "The linked page isn't in your library any more. It may have been deleted."
                    return
                }
                self.flush()
                self.showingGrid = false
                if let area = link.area {
                    self.revealArea = (path, area)
                    self.revealVersion += 1
                }
                self.showPage(at: path)
            }
        }
    }

    /// The Electron notes linking to the open page.
    var linkedNotes: [LinkingNote] {
        guard let id = doc?.id else { return [] }
        return notesLinking?(id) ?? []
    }
}

/// Scrolls `scroll` so `rect` (in `content`'s units, which the scroll view
/// zooms) sits in the middle of the screen, zooming out only if it doesn't
/// fit, and flashes it. True if it changed the zoom.
@MainActor
@discardableResult
func showArea(_ rect: CGRect, in scroll: UIScrollView, content: UIView) -> Bool {
    guard scroll.bounds.width > 0 else { return false }
    let inset = scroll.adjustedContentInset
    let room = CGSize(width: scroll.bounds.width - inset.left - inset.right,
                      height: scroll.bounds.height - inset.top - inset.bottom)
    let padded = rect.insetBy(dx: -40, dy: -40)
    let fit = min(room.width / padded.width, room.height / padded.height)
    var zoomed = false
    if fit < scroll.zoomScale {
        scroll.zoomScale = max(fit, scroll.minimumZoomScale)
        zoomed = true
    }
    // The content view's frame is where the zoomed content sits.
    let zoom = scroll.zoomScale
    let origin = content.frame.origin
    var offset = CGPoint(x: origin.x + rect.midX * zoom - inset.left - room.width / 2,
                         y: origin.y + rect.midY * zoom - inset.top - room.height / 2)
    offset.x = min(max(offset.x, -inset.left), max(-inset.left, scroll.contentSize.width + inset.right - scroll.bounds.width))
    offset.y = min(max(offset.y, -inset.top), max(-inset.top, scroll.contentSize.height + inset.bottom - scroll.bounds.height))
    scroll.setContentOffset(offset, animated: false)

    let glow = UIView(frame: rect.insetBy(dx: -10, dy: -10))
    glow.isUserInteractionEnabled = false
    glow.backgroundColor = UIColor(Color.velvetAccent).withAlphaComponent(0.16)
    glow.layer.borderColor = UIColor(Color.velvetAccent).withAlphaComponent(0.85).cgColor
    glow.layer.borderWidth = 2 / max(zoom, 0.1)
    glow.layer.cornerRadius = 12
    glow.layer.cornerCurve = .continuous
    content.addSubview(glow)
    UIView.animate(withDuration: 0.8, delay: 1.4, options: [.allowUserInteraction]) {
        glow.alpha = 0
    } completion: { _ in glow.removeFromSuperview() }
    return zoomed
}

/// The notes linking to the open page, in the page's toolbar; picking one
/// opens it in Electron.
struct LinkedNotesButton: View {
    let store: Store

    var body: some View {
        let notes = store.linkedNotes
        if !notes.isEmpty {
            Menu {
                Section("Linked from") {
                    ForEach(notes) { note in
                        Button(note.title, systemImage: "doc.text") { store.openNote?(note.path) }
                    }
                }
            } label: {
                Label("\(notes.count)", systemImage: "link")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityLabel(notes.count == 1 ? "Linked from 1 note" : "Linked from \(notes.count) notes")
        }
    }
}
