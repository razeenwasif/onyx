import AppKit
import XCTest
@testable import Scribe

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
        var doc: PageDoc = try Core.call("read_page", ["path": file])
        doc.textBoxes = [TextBoxDTO(text: "Hello there", spans: [TextSpanDTO(start: 0, length: 5, bold: true)])]
        let _: WriteResult = try Core.call("write_page", ["path": file, "page": try Core.json(doc)])

        let back: PageDoc = try Core.call("read_page", ["path": file])
        XCTAssertEqual(back.textBoxes.first?.text, "Hello there")
        XCTAssertEqual(back.textBoxes.first?.spans?.first?.bold, true)

        let hits: [PageInfo] = try Core.call("search", ["root": dir.path, "query": "THERE"])
        XCTAssertEqual(hits.map(\.path), [file])
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
