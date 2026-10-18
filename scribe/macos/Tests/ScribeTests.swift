import AppKit
import XCTest
@testable import ScribeUI

final class CoreBridgeTests: XCTestCase {
    func testColoursCrossTheBoundary() {
        let black = Core.parseColor("#1A1A1A")
        XCTAssertEqual(black, 0x1A1A_1AFF)
        XCTAssertEqual(Core.adapt(black, dark: true), 0xEFE6_D8FF)
        XCTAssertEqual(Core.adapt(black, dark: false), black)
        XCTAssertEqual(Core.parseColor("nonsense", fallback: 7), 7)
    }

    func testOutlineIsAClosedFilledShape() {
        let path = Core.outlinePath(points: [0, 0, 0.5, 20, 0, 0.5, 40, 10, 0.8], width: 3,
                                    pressureSensitive: true, fit: true, taper: true)
        XCTAssertFalse(path.isEmpty)
        XCTAssertGreaterThan(path.boundingBox.width, 40)
    }

    func testPartialEraseSplitsAStroke() throws {
        let pieces = try XCTUnwrap(Core.strokeErase(points: [0, 0, 0.5, 100, 0, 0.5], width: 2, fit: true,
                                                    at: CGPoint(x: 50, y: 0), radius: 5))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertNil(Core.strokeErase(points: [0, 0, 0.5, 100, 0, 0.5], width: 2, fit: true,
                                      at: CGPoint(x: 50, y: 50), radius: 5))
    }

    func testTableParsingAndOptionalResults() throws {
        let table = try Core.call("parse_table", ["text": "a\tb\n1\t2"], as: ParsedTable?.self)
        XCTAssertEqual(table?.rows, [["a", "b"], ["1", "2"]])
        let none = try Core.call("parse_table", ["text": "just prose"], as: ParsedTable?.self)
        XCTAssertNil(none)
    }

    func testErrorsSurfaceAsThrows() {
        XCTAssertThrowsError(try Core.run("no_such_op"))
    }

    func testPagesRoundTripThroughTheCore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-tests-\(newID())")
        defer { try? FileManager.default.removeItem(at: dir) }

        let nb: String = try Core.call("create_notebook", ["root": dir.path, "name": "NB", "firstSection": "S"])
        let tree: [NotebookInfo] = try Core.call("tree", ["root": dir.path])
        XCTAssertEqual(tree.first?.path, nb)
        let section = try XCTUnwrap(tree.first?.sections.first)

        let file: String = try Core.call("create_page", ["section": section.path, "title": "Hello"])
        var doc: PageDoc = try Core.readPage(file)
        doc.textBoxes = [TextBoxDTO(text: "Hello there", spans: [TextSpanDTO(start: 0, length: 5, bold: true)])]
        let _: WriteResult = try Core.writePage(file, doc)

        let back: PageDoc = try Core.readPage(file)
        XCTAssertEqual(back.textBoxes.first?.text, "Hello there")
        XCTAssertEqual(back.textBoxes.first?.spans?.first?.bold, true)

        let hits: [PageInfo] = try Core.call("search", ["root": dir.path, "query": "THERE"])
        XCTAssertEqual(hits.map(\.path), [file])
    }

    func testStarsAndThumbnails() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scribe-tests-\(newID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try Core.call("create_notebook", ["root": dir.path, "name": "NB", "firstSection": "S"], as: String.self)
        let tree: [NotebookInfo] = try Core.call("tree", ["root": dir.path])
        let section = try XCTUnwrap(tree.first?.sections.first)
        let file: String = try Core.call("create_page", ["section": section.path, "title": "Ink"])

        // A thick cream diagonal across the page.
        var doc: PageDoc = try Core.readPage(file)
        doc.strokes = [StrokeDTO(width: 30, height: 30, points: [100, 100, 1, 740, 1000, 1])]
        let _: WriteResult = try Core.writePage(file, doc)

        try Core.run("set_bookmarked", ["path": file, "bookmarked": true])
        let page = try XCTUnwrap((try Core.call("pages", ["section": section.path], as: [PageInfo].self)).first)
        XCTAssertTrue(page.isBookmarked)
        XCTAssertEqual(page.pageId, doc.id)

        let image = await Thumbnails.shared.image(for: page, root: dir.path)
        let thumb = try XCTUnwrap(image)
        XCTAssertEqual(thumb.width, Thumbnails.pixelWidth)
        XCTAssertEqual(thumb.height, Int((1188.0 * Double(Thumbnails.pixelWidth) / 840).rounded()))

        // The middle of the stroke is ink, far brighter than the dark paper.
        let gray = CGContext(data: nil, width: thumb.width, height: thumb.height, bitsPerComponent: 8, bytesPerRow: thumb.width,
                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        gray.draw(thumb, in: CGRect(x: 0, y: 0, width: thumb.width, height: thumb.height))
        let pixels = gray.data!.assumingMemoryBound(to: UInt8.self)
        // The stroke's midpoint, (420, 550) on the page, at thumbnail scale.
        let scale = Double(Thumbnails.pixelWidth) / 840
        let mid = Int(550 * scale) * thumb.width + Int(420 * scale)
        XCTAssertGreaterThan(pixels[mid], 150)
        XCTAssertLessThan(pixels[thumb.width * 4 + thumb.width - 4], 60)

        let cached = dir.appendingPathComponent(".scribe/thumbs.nosync/\(doc.id).png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
    }
}

final class RichTextTests: XCTestCase {
    func testSpansRoundTripThroughAttributedText() {
        var box = TextBoxDTO(text: "Shopping: apples and pears")
        box.spans = [
            TextSpanDTO(start: 21, length: 5, bold: true),
            TextSpanDTO(start: 0, length: 8, underline: true, fontFamily: "Handwritten", color: "#C02828"),
        ]

        let attributed = RichText.build(box, dark: true)
        let spans = RichText.spans(of: attributed, base: TextStyle(box: box))

        XCTAssertEqual(spans.count, 2)
        let sorted = spans.sorted { $0.start < $1.start }
        XCTAssertEqual(sorted[0].start, 0)
        XCTAssertEqual(sorted[0].length, 8)
        XCTAssertEqual(sorted[0].underline, true)
        XCTAssertEqual(sorted[0].fontFamily, "Handwritten")
        XCTAssertEqual(sorted[0].color, "#C02828")
        XCTAssertNil(sorted[0].bold)
        XCTAssertEqual(sorted[1].start, 21)
        XCTAssertEqual(sorted[1].bold, true)
    }

    func testPlainBoxHasNoSpans() {
        let box = TextBoxDTO(text: "Nothing special")
        XCTAssertTrue(RichText.spans(of: RichText.build(box, dark: false), base: TextStyle(box: box)).isEmpty)
    }

    func testStaleSpansAreClippedNotTrusted() {
        var box = TextBoxDTO(text: "short")
        box.spans = [TextSpanDTO(start: 3, length: 500, bold: true), TextSpanDTO(start: 99, length: 2, italic: true)]
        let s = RichText.build(box, dark: false)
        XCTAssertEqual(s.length, 5)
        XCTAssertEqual(RichText.spans(of: s, base: TextStyle(box: box)).first?.length, 2)
    }

    func testDarkModeChangesPaintNotStoredColour() {
        let box = TextBoxDTO(text: "ink")
        let dark = RichText.build(box, dark: true)
        let colour = dark.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(colour?.hexString, "#EFE6D8")
        XCTAssertEqual(dark.attribute(.scribeColor, at: 0, effectiveRange: nil) as? String, "#1A1A1A")
    }

    func testWindowsFontNamesFoldOntoLogicalOnes() {
        XCTAssertEqual(ScribeFonts.canonical("Segoe Print"), "Handwritten")
        XCTAssertEqual(ScribeFonts.canonical("Consolas"), "Cascadia Code")
        XCTAssertEqual(ScribeFonts.canonical("Georgia"), "Georgia")
    }
}

final class PageModelTests: XCTestCase {
    func testUndoRedoOfInk() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let page = PageModel(path: "/tmp/x.json", sectionPath: "/tmp", doc: PageDoc())
        page.undoManager = undo

        undo.beginUndoGrouping()
        page.addStroke(StrokeDTO(points: [0, 0, 0.5, 10, 10, 0.5]))
        undo.endUndoGrouping()
        XCTAssertEqual(page.strokes.count, 1)

        undo.undo()
        XCTAssertEqual(page.strokes.count, 0)
        undo.redo()
        XCTAssertEqual(page.strokes.count, 1)
    }

    func testPageGrowsWithContentAndNeverShrinks() {
        let page = PageModel(path: "/tmp/x.json", sectionPath: "/tmp", doc: PageDoc())
        XCTAssertEqual(page.pageSize, PageModel.defaultSize)
        page.addStroke(StrokeDTO(points: [100, 3000, 0.5, 120, 3010, 0.5]))
        XCTAssertGreaterThan(page.pageSize.height, 3000 + PageModel.growthMargin - 10)
    }

    func testEmptyTextIsDroppedOnSave() {
        let page = PageModel(path: "/tmp/x.json", sectionPath: "/tmp", doc: PageDoc())
        page.addTextBox(at: .zero, text: "   ", focus: false)
        page.addTextBox(at: .zero, text: "kept", focus: false)
        XCTAssertEqual(page.toDoc().textBoxes.map(\.text), ["kept"])
    }

    func testDeletingASelectionIsUndoable() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let page = PageModel(path: "/tmp/x.json", sectionPath: "/tmp", doc: PageDoc())
        page.undoManager = undo
        undo.beginUndoGrouping()
        page.addStroke(StrokeDTO(points: [0, 0, 0.5, 10, 10, 0.5]))
        undo.endUndoGrouping()

        page.select(lasso: [-5, -5, 20, -5, 20, 20, -5, 20])
        XCTAssertTrue(page.hasSelection)
        undo.beginUndoGrouping()
        page.deleteSelection()
        undo.endUndoGrouping()
        XCTAssertTrue(page.strokes.isEmpty)
        undo.undo()
        XCTAssertEqual(page.strokes.count, 1)
    }
}

final class InkReaderTests: XCTestCase {
    /// Block capitals drawn as pen strokes, 60 units tall, starting at `x`.
    private func letters(_ word: String, x: Double = 40, y: Double = 40) -> [StrokeDTO] {
        let (w, h) = (36.0, 60.0)
        func line(_ a: (Double, Double), _ b: (Double, Double)) -> StrokeDTO {
            // Several samples per segment, at an even, firm pressure.
            let pts = (0...8).flatMap { i -> [Double] in
                let t = Double(i) / 8
                return [a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, 0.7]
            }
            return StrokeDTO(width: 6, height: 6, points: pts)
        }
        var out: [StrokeDTO] = []
        for (i, ch) in word.enumerated() {
            let l = x + Double(i) * (w + 18), r = l + w, t = y, b = y + h, m = y + h / 2
            switch ch {
            case "H": out += [line((l, t), (l, b)), line((r, t), (r, b)), line((l, m), (r, m))]
            case "E": out += [line((l, t), (l, b)), line((l, t), (r, t)), line((l, m), (r - 8, m)), line((l, b), (r, b))]
            case "L": out += [line((l, t), (l, b)), line((l, b), (r, b))]
            case "O": out += [line((l, t), (r, t)), line((r, t), (r, b)), line((r, b), (l, b)), line((l, b), (l, t))]
            default: break
            }
        }
        return out
    }

    func testReadsWritingFromInk() throws {
        var doc = PageDoc()
        doc.strokes = letters("HELLO")
        let image = try XCTUnwrap(InkReader.render(doc))
        let text = InkReader.recognize(image)
        XCTAssertTrue(text.uppercased().contains("HELLO"), "read \"\(text)\"")
    }

    func testHighlighterAloneGivesNoImage() {
        var doc = PageDoc()
        doc.strokes = [StrokeDTO(highlighter: true, points: [0, 0, 0.5, 100, 0, 0.5])]
        XCTAssertNil(InkReader.render(doc))
    }

    func testPageWithoutInkGivesNoImage() {
        XCTAssertNil(InkReader.render(PageDoc()))
    }
}

final class PDFBackgroundTests: XCTestCase {
    /// A one-page A4 PDF with a line of text on it, in a temp section folder.
    private func section(with text: String) throws -> (String, BackgroundDTO) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("assets/doc.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        (text as NSString).draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 40)])
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return (dir.path, BackgroundDTO(kind: "pdf", asset: "assets/doc.pdf", pdfPage: 0))
    }

    func testPageScalesToTheStandardWidth() throws {
        let (dir, bg) = try section(with: "Hello")
        let page = try XCTUnwrap(PDFBackground.page(for: bg, sectionPath: dir))
        let size = PDFBackground.size(of: page)
        XCTAssertEqual(size.width, PageModel.defaultSize.width)
        XCTAssertEqual(size.height, ceil(842 * PageModel.defaultSize.width / 595))
    }

    func testPagesGrowToFitThePDF() throws {
        let (dir, bg) = try section(with: "Hello")
        var doc = PageDoc()
        doc.background = bg
        let model = PageModel(path: dir + "/p.json", sectionPath: dir, doc: doc)
        XCTAssertGreaterThanOrEqual(model.pageSize.height, PDFBackground.size(of: PDFBackground.page(for: bg, sectionPath: dir)!).height)
    }

    func testTextOnThePDFIsReadable() throws {
        let (dir, bg) = try section(with: "Thermodynamics")
        let page = try XCTUnwrap(PDFBackground.page(for: bg, sectionPath: dir))
        XCTAssertTrue((page.string ?? "").contains("Thermodynamics"))
        let image = try XCTUnwrap(PDFBackground.image(of: page))
        XCTAssertTrue(InkReader.recognize(image).localizedCaseInsensitiveContains("thermodynamics"))
    }

    func testOtherBackgroundsAreNotPDFs() {
        XCTAssertNil(PDFBackground.page(for: BackgroundDTO(), sectionPath: "/tmp"))
    }
}

/// Answers OneNote requests from a script instead of Microsoft.
private final class ScriptedGraph: URLProtocol {
    nonisolated(unsafe) static var answers: [Int] = []
    nonisolated(unsafe) static var requests = 0

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "graph.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests += 1
        let code = Self.answers.isEmpty ? 200 : Self.answers.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Retry-After": "0"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class OneNoteClientTests: XCTestCase {
    override func setUp() {
        URLProtocol.registerClass(ScriptedGraph.self)
        OneNoteClient.slowDownStep = 0.05
    }

    override func tearDown() {
        URLProtocol.unregisterClass(ScriptedGraph.self)
        OneNoteClient.slowDownStep = 15
    }

    func testSlowDownIsWaitedOutNotFatal() async throws {
        ScriptedGraph.answers = [429, 429, 503, 200]
        ScriptedGraph.requests = 0
        let waits = WaitLog()
        var client = OneNoteClient(token: "t")
        client.onWait = { wait in waits.add(wait?.until) }
        let (data, response) = try await client.get("https://graph.test/page")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ok")
        XCTAssertEqual(ScriptedGraph.requests, 4)
        // Each of the three waits is announced, then cleared as it retries.
        XCTAssertEqual(waits.entries.count, 6)
        XCTAssertEqual(waits.entries.compactMap { $0 }.count, 3)
        XCTAssertNil(waits.entries.last!)
    }

    func testAPageMicrosoftKeepsFailingOnIsGivenUp() async {
        ScriptedGraph.answers = [504, 504, 504, 200]
        ScriptedGraph.requests = 0
        do {
            _ = try await OneNoteClient(token: "t").get("https://graph.test/page")
            XCTFail("expected the page to be given up")
        } catch OneNoteClient.Failure.unavailable {
            XCTAssertEqual(ScriptedGraph.requests, OneNoteClient.serverTries)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testExpiredTokenStopsAtOnce() async {
        ScriptedGraph.answers = [401]
        do {
            _ = try await OneNoteClient(token: "t").get("https://graph.test/page")
            XCTFail("expected the token to be refused")
        } catch OneNoteClient.Failure.tokenExpired {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

private final class WaitLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Date?] = []
    var entries: [Date?] { lock.withLock { log } }
    func add(_ d: Date?) { lock.withLock { log.append(d) } }
}
