import SwiftUI
import AVFoundation

struct FragmentListView: View {
    @Bindable var engine: TimelineEngine
    let player: AVPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Fragments")
                    .font(.headline)
                Spacer()
                Text("\(engine.fragments.count) total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Fragment list
            if engine.fragments.isEmpty {
                VStack {
                    Spacer()
                    Text("No fragments yet")
                        .foregroundStyle(.tertiary)
                    Text("Import a video and detect silence")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(engine.fragments) { fragment in
                            FragmentRowView(
                                fragment: fragment,
                                isSelected: engine.selectedFragmentID == fragment.id,
                                onToggle: {
                                    engine.toggleFragment(fragment.id)
                                },
                                onDelete: {
                                    engine.deleteFragment(fragment.id)
                                },
                                onSelect: {
                                    engine.selectedFragmentID = fragment.id
                                    // Fix #2: fast seek (default tolerances, not frame-accurate)
                                    let time = CMTime(seconds: fragment.sourceStartTime, preferredTimescale: 600)
                                    player?.seek(to: time)
                                    engine.playheadPosition = fragment.sourceStartTime
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

struct FragmentRowView: View {
    let fragment: TimelineFragment
    let isSelected: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Type indicator
            RoundedRectangle(cornerRadius: 3)
                .fill(fragment.type == .speech ? Color.green : Color.red.opacity(0.6))
                .frame(width: 4, height: 36)

            // Inclusion toggle
            Button(action: onToggle) {
                Image(systemName: fragment.isIncluded ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(fragment.isIncluded ? .green : .secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)

            // Fragment info
            VStack(alignment: .leading, spacing: 2) {
                Text(fragment.type == .speech ? "Speech" : "Silence")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(fragment.isIncluded ? .primary : .tertiary)
                    .strikethrough(!fragment.isIncluded, color: .secondary)

                Text("\(formatTime(fragment.sourceStartTime)) - \(formatTime(fragment.sourceEndTime))")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Duration badge
            Text(formatDuration(fragment.sourceDuration))
                .font(.caption)
                .monospacedDigit()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(fragment.type == .silence ? Color.red.opacity(0.15) : Color.green.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Delete button
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.body)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, ms)
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 {
            return String(format: "%.0fms", seconds * 1000)
        } else {
            return String(format: "%.1fs", seconds)
        }
    }
}
