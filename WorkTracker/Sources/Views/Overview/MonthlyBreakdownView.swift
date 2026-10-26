import SwiftUI

struct MonthlyBreakdownView: View {
    let months: [MonthSummary]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(tr("Month"))
                    .frame(width: 100, alignment: .leading)
                Spacer()
                Text(tr("Expected"))
                    .frame(width: 72, alignment: .trailing)
                Text(tr("Worked"))
                    .frame(width: 72, alignment: .trailing)
                Text(tr("Balance"))
                    .frame(width: 80, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ForEach(Array(months.enumerated()), id: \.offset) { index, month in
                HStack {
                    Text(month.monthName)
                        .frame(width: 100, alignment: .leading)

                    MeterBar(progress: progress(month), color: progressColor(month), height: 4)

                    Text(TimeFormatting.hours(month.expectedHours))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                    Text(TimeFormatting.hours(month.actualHours))
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                    Text(TimeFormatting.signedHours(month.balance))
                        .monospacedDigit()
                        .foregroundStyle(balanceColor(month))
                        .frame(width: 80, alignment: .trailing)
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(index.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
                .accessibilityElement(children: .combine)
            }
        }
        .cardSurface()
    }

    private func progress(_ month: MonthSummary) -> Double {
        guard month.expectedHours > 0 else { return 0 }
        return month.actualHours / month.expectedHours
    }

    private func progressColor(_ month: MonthSummary) -> Color {
        if month.actualHours == 0 { return .clear }
        if month.actualHours >= month.expectedHours { return .green }
        return .accentColor
    }

    private func balanceColor(_ month: MonthSummary) -> Color {
        if month.actualHours == 0 && month.expectedHours == 0 { return .secondary }
        return month.balance >= 0 ? .green : .red
    }

}
