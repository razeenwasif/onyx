import SwiftUI

/// A month of daily notes, like the desktop's calendar pane: days that have
/// a note are marked, and picking a day opens (or starts) its note.
struct CalendarSheet: View {
    let store: VaultStore
    /// Inside the Context panel: the month in a row above the grid, no
    /// navigation bar of its own.
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var month = Calendar.current.dateInterval(of: .month, for: Date())!.start

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

    var body: some View {
        if embedded {
            VStack(spacing: 14) {
                HStack {
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(month.formatted(.dateTime.month(.wide).year())).font(.headline).foregroundStyle(Color.evFg)
                    Spacer()
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                }
                grid
                Button("Today's note") { store.openDaily() }.font(.footnote)
            }
        } else {
            sheet
        }
    }

    private var grid: some View {
        VStack(spacing: 18) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, day in
                    Text(day).font(.caption.weight(.semibold)).foregroundStyle(Color.evSubtle)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                    if let date { dayCell(date) } else { Color.clear.frame(height: 44) }
                }
            }
            let count = notesThisMonth
            Text(count == 0 ? "No daily notes this month" : count == 1 ? "1 daily note this month" : "\(count) daily notes this month")
                .font(.footnote)
                .foregroundStyle(Color.evSubtle)
        }
    }

    private var sheet: some View {
        NavigationStack {
            VStack(spacing: 18) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(weekdays.enumerated()), id: \.offset) { _, day in
                        Text(day).font(.caption.weight(.semibold)).foregroundStyle(Color.evSubtle)
                    }
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, date in
                        if let date { dayCell(date) } else { Color.clear.frame(height: 44) }
                    }
                }

                let count = notesThisMonth
                Text(count == 0 ? "No daily notes this month" : count == 1 ? "1 daily note this month" : "\(count) daily notes this month")
                    .font(.footnote)
                    .foregroundStyle(Color.evSubtle)
                Spacer()
            }
            .padding(20)
            .background(Color.evBg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                // The month, with arrows either side, as the title.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 14) {
                        Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Previous month")
                        Text(month.formatted(.dateTime.month(.wide).year()))
                            .font(.headline)
                            .foregroundStyle(Color.evFg)
                            .frame(minWidth: 150)
                        Button { shift(1) } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel("Next month")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Today") {
                        store.openDaily()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.height(560), .large])
    }

    private var weekdays: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// The month's days, padded so the 1st falls under its weekday.
    private var cells: [Date?] {
        let days = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + (0..<days).map { calendar.date(byAdding: .day, value: $0, to: month) }
    }

    private var notesThisMonth: Int {
        cells.compactMap { $0 }.filter { store.files[VaultStore.dailyPath($0)] != nil }.count
    }

    private func shift(_ months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: month) {
            withAnimation(.easeInOut(duration: 0.2)) { month = next }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let has = store.files[VaultStore.dailyPath(date)] != nil
        let today = calendar.isDateInToday(date)
        let open = store.current == VaultStore.dailyPath(date)
        return Button {
            store.openDaily(date)
            if !embedded { dismiss() }
        } label: {
            VStack(spacing: 3) {
                Text("\(calendar.component(.day, from: date))")
                    .font(.body.weight(today ? .bold : .regular))
                    .foregroundStyle(today ? Color.evAccent : Color.evFg)
                Circle()
                    .fill(has ? Color.evAccent : .clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(open ? Color.evBgSel : today ? Color.evAccent.opacity(0.1) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted) + (has ? ", has a note" : ""))
    }
}
