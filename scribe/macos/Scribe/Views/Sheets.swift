import SwiftUI

/// Writes or edits a LaTeX equation, with a live preview.
struct LatexSheet: View {
    let app: AppModel
    let editing: LatexItem?

    @State private var latex = ""
    @State private var scale: Double = 22
    @Environment(\.dismiss) private var dismiss

    private static let snippets: [(String, String, String)] = [
        ("x/y", #"\frac{a}{b}"#, "Fraction"),
        ("√x", #"\sqrt{x}"#, "Square root"),
        ("x²", "x^{2}", "Superscript"),
        ("xᵢ", "x_{i}", "Subscript"),
        ("∫", #"\int_{a}^{b} f(x) \, dx"#, "Integral"),
        ("∑", #"\sum_{i=1}^{n} x_i"#, "Summation"),
        ("lim", #"\lim_{x \to 0}"#, "Limit"),
        ("±", #"\pm"#, "Plus-minus"),
        ("∞", #"\infty"#, "Infinity"),
        ("α", #"\alpha"#, "Alpha"),
        ("β", #"\beta"#, "Beta"),
        ("θ", #"\theta"#, "Theta"),
        ("π", #"\pi"#, "Pi"),
        ("≠", #"\neq"#, "Not equal"),
        ("≤", #"\le"#, "Less than or equal"),
        ("≥", #"\ge"#, "Greater than or equal"),
        ("matrix", #"\begin{pmatrix} a & b \\ c & d \end{pmatrix}"#, "Matrix"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "Insert Equation" : "Edit Equation")
                .font(.title3.weight(.semibold))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Self.snippets, id: \.1) { label, snippet, help in
                        Button(label) { latex += (latex.isEmpty || latex.hasSuffix(" ") ? "" : " ") + snippet }
                            .help(help)
                            .controlSize(.small)
                    }
                }
            }

            TextEditor(text: $latex)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 70)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))

            HStack {
                Text("Size")
                Slider(value: $scale, in: 10...60, step: 1)
                Text("\(Int(scale)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
            }

            ScrollView([.horizontal, .vertical]) {
                MathView(latex: latex, fontSize: scale, color: .labelColor)
                    .fixedSize()
                    .padding(12)
            }
            .frame(minHeight: 110, maxHeight: 220)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background.secondary))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Insert Equation" : "Update Equation") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(latex.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            latex = editing?.dto.latex ?? #"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#
            scale = editing.map { $0.dto.scale > 0 ? $0.dto.scale : 22 } ?? 22
        }
    }

    private func commit() {
        let text = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        if let item = editing, let page = app.page {
            let before = item.dto
            item.dto.latex = text
            item.dto.scale = scale
            let after = item.dto
            page.commitEdit(item, name: "Edit Equation", before: { $0.dto = before }, after: { $0.dto = after })
        } else {
            app.insertLatex(text, scale: scale)
        }
        dismiss()
    }
}

/// Picks a table's shape.
struct TableSheet: View {
    let app: AppModel

    @State private var rows = 3
    @State private var columns = 3
    @State private var header = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert Table").font(.title3.weight(.semibold))
            Form {
                Stepper("Rows: \(rows)", value: $rows, in: 1...50)
                Stepper("Columns: \(columns)", value: $columns, in: 1...20)
                Toggle("Header row", isOn: $header)
            }
            preview
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert Table") {
                    app.insertTable(rows: rows, columns: columns, header: header)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private var preview: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<min(rows, 8), id: \.self) { r in
                GridRow {
                    ForEach(0..<min(columns, 10), id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(r == 0 && header ? Color.scribeAccent.opacity(0.55) : Color.secondary.opacity(0.25))
                            .frame(height: 12)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
