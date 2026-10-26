import SwiftUI

struct SegmentRowView: View {
    let segment: WorkSegment
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    private var accent: Color { segment.project?.color.color ?? .accentColor }
    private var start: String { TimeField.format(segment.startTime, on: segment.date) }
    private var end: String { TimeField.format(segment.endTime, on: segment.date) }

    var body: some View {
        HStack(spacing: 12) {
            // Project-coloured time range indicator
            Capsule()
                .fill(accent)
                .frame(width: 4, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(start)
                    Text("–")
                        .foregroundStyle(.tertiary)
                    Text(end)
                }
                .font(.body.monospacedDigit())

                HStack(spacing: 6) {
                    if let project = segment.project {
                        Text(project.name)
                            .foregroundStyle(.secondary)
                    }
                    if !segment.note.isEmpty {
                        Text(segment.note)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.caption)
            }

            Spacer()

            Text(TimeFormatting.hours(segment.durationHours))
                .font(.subheadline.monospacedDigit())
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(.fill.quaternary))

            if isHovered {
                HStack(spacing: 2) {
                    Button { onEdit() } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(tr("Edit entry"))
                    .accessibilityLabel(tr("Edit entry"))

                    Button { onDelete() } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help(tr("Delete entry (⌘Z to undo)"))
                    .accessibilityLabel(tr("Delete entry"))
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .rowHighlight(isHovered)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        // Double-click to edit; right-click for keyboard/VoiceOver-reachable actions.
        .onTapGesture(count: 2) { onEdit() }
        .contextMenu {
            Button { onEdit() } label: { Label(tr("Edit Entry"), systemImage: "pencil") }
            Button { onDuplicate() } label: { Label(tr("Duplicate Entry"), systemImage: "plus.square.on.square") }
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label(tr("Delete Entry"), systemImage: "trash") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: tr("Edit Entry")) { onEdit() }
        .accessibilityAction(named: tr("Duplicate Entry")) { onDuplicate() }
        .accessibilityAction(named: tr("Delete Entry")) { onDelete() }
        .accessibilityLabel(tr("Time entry %@ to %@, %@", start, end, TimeFormatting.hours(segment.durationHours))
                            + (segment.project.map { ", \($0.name)" } ?? "")
                            + (segment.note.isEmpty ? "" : ", \(segment.note)"))
    }
}
