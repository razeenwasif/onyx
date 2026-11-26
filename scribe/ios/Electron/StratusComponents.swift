import SwiftUI

/// Stratus-style status dot with optional live pulse halo.
struct StratusStatusDot: View {
    let color: Color
    var size: CGFloat = 6
    var pulse: Bool = false
    @State private var pulsing = false

    var body: some View {
        ZStack {
            if pulse {
                Circle()
                    .fill(color.opacity(0.35))
                    .frame(width: size * 2.1, height: size * 2.1)
                    .scaleEffect(pulsing ? 1.25 : 0.85)
                    .opacity(pulsing ? 0.15 : 0.55)
                    .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
            }
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
    }
}

/// Borderless tonal tag/badge pill matching Stratus `TagPill`.
struct StratusTagPill: View {
    let text: String
    var tint: Color = .evDim
    var background: Color = .evSurfacePill
    var monospaced: Bool = false

    var body: some View {
        Text(text)
            .font(monospaced ? .system(size: 10.5, weight: .medium, design: .monospaced) : .system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Borderless tonal action pill matching Stratus `ActionPillButton`.
struct StratusActionPill: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .evFg
    var background: Color = .evSurfacePill
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Borderless tonal filter pill matching Stratus `FilterPillButton`.
struct StratusFilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.evFg : Color.evDim)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color.evBgSel : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Uppercase micro-section header (`10.5pt` semibold, tracking 0.8, `evSubtle`).
struct StratusSectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.evSubtle)
            if let trailing {
                Spacer()
                Text(trailing)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.evSubtle)
                    .monospacedDigit()
            }
        }
    }
}

/// Compact KPI stat column matching Stratus `MetricStatColumn`.
struct StratusMetricStat: View {
    let label: String
    let value: String
    var subtitle: String? = nil
    var tint: Color = .evFg

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.evSubtle)
            Text(value)
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.evDim)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
