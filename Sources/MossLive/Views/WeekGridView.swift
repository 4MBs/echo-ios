import SwiftUI

/// The week, drawn to scale: a time axis down the left, one column per school
/// day, and every lesson where it actually falls in the day.
///
/// A block is filled when there is a recording behind it and outlined when
/// there is not, so the week reads at a glance as what was captured and what
/// was missed. That is the one thing a timetable app cannot show and the only
/// reason this screen exists.
struct WeekGridView: View {
    let layout: WeekLayout
    let api: BackendAPI
    /// Nil on a wide screen (all five days); an index on a narrow one.
    let singleDay: Int?
    let onRecord: (LessonBlock) -> Void

    /// Points per minute. A 45-minute lesson comes out at 54pt, which is
    /// enough for a subject, a room and a badge.
    private static let scale: CGFloat = 1.2
    private static let axisWidth: CGFloat = 46
    private static let columnGap: CGFloat = 5

    private var calendar: Calendar { Calendar.current }

    private var visibleDays: [DayLayout] {
        guard let singleDay, layout.days.indices.contains(singleDay) else { return layout.days }
        return [layout.days[singleDay]]
    }

    private var gridHeight: CGFloat {
        CGFloat(layout.endMinute - layout.startMinute) * Self.scale
    }

    private var hourMarks: [Int] {
        stride(from: (layout.startMinute / 60) * 60, through: layout.endMinute, by: 60)
            .filter { $0 >= layout.startMinute }
    }

    var body: some View {
        VStack(spacing: 0) {
            dayHeaders
            Divider()
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourLines
                    HStack(alignment: .top, spacing: Self.columnGap) {
                        timeAxis
                        ForEach(visibleDays) { day in
                            dayColumn(day)
                        }
                    }
                    nowLine
                }
                .frame(height: gridHeight)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
        }
    }

    // MARK: Headers

    private var dayHeaders: some View {
        HStack(alignment: .bottom, spacing: Self.columnGap) {
            Text(monthLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: Self.axisWidth, alignment: .leading)
            ForEach(visibleDays) { day in
                let today = calendar.isDateInToday(day.date)
                VStack(spacing: 2) {
                    Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(day.date.formatted(.dateTime.day()))
                        .font(.headline)
                        .foregroundStyle(today ? Color.white : .primary)
                        .frame(width: 28, height: 28)
                        .background {
                            if today {
                                Circle().fill(Color.red)
                            }
                        }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private var monthLabel: String {
        guard let first = layout.days.first?.date else { return "" }
        return first.formatted(.dateTime.month(.abbreviated))
    }

    // MARK: The grid

    private var timeAxis: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(hourMarks, id: \.self) { minute in
                Text(String(format: "%02d:00", minute / 60))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .offset(y: CGFloat(minute - layout.startMinute) * Self.scale - 6)
            }
        }
        .frame(width: Self.axisWidth, height: gridHeight, alignment: .topLeading)
    }

    private var hourLines: some View {
        ZStack(alignment: .topLeading) {
            ForEach(hourMarks, id: \.self) { minute in
                Rectangle()
                    .fill(Color(.separator).opacity(0.6))
                    .frame(height: 0.5)
                    .offset(y: CGFloat(minute - layout.startMinute) * Self.scale)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.leading, Self.axisWidth + Self.columnGap)
    }

    /// Its own view on its own clock, so the minute hand cannot invalidate the
    /// grid behind it.
    private var nowLine: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let minute = SchoolClock.minutes(of: context.date, calendar: calendar)
            let showing = visibleDays.contains { calendar.isDateInToday($0.date) }
            if showing, minute >= layout.startMinute, minute <= layout.endMinute {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.red)
                        .frame(height: 1.5)
                    Circle()
                        .fill(Color.red)
                        .frame(width: 7, height: 7)
                        .offset(x: -3)
                }
                .padding(.leading, Self.axisWidth + Self.columnGap)
                .offset(y: CGFloat(minute - layout.startMinute) * Self.scale)
            }
        }
    }

    private func dayColumn(_ day: DayLayout) -> some View {
        GeometryReader { geometry in
            if let holiday = day.holiday, day.isEmpty {
                holidaySlab(holiday)
            } else {
                ForEach(day.blocks) { block in
                    blockView(block, day: day)
                        .frame(
                            width: max(20, geometry.size.width * block.width - 2),
                            height: blockHeight(block)
                        )
                        .offset(
                            x: geometry.size.width * block.offset,
                            y: CGFloat(block.start - layout.startMinute) * Self.scale
                        )
                }
            }
        }
        .frame(height: gridHeight)
    }

    private func blockHeight(_ block: LessonBlock) -> CGFloat {
        max(26, CGFloat(block.end - block.start) * Self.scale - 2)
    }

    private func holidaySlab(_ name: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "beach.umbrella")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// A block leads somewhere only when there is something there: the lesson
    /// it recorded, or — for the lesson happening right now — a recording that
    /// has not been made yet.
    @ViewBuilder
    private func blockView(_ block: LessonBlock, day: DayLayout) -> some View {
        let current = isCurrent(block, on: day)
        if let recording = block.recording {
            NavigationLink {
                LessonDetailView(api: api, info: recording)
            } label: {
                LessonBlockView(block: block, isCurrent: current)
            }
            .buttonStyle(.card)
        } else if current, !block.cancelled {
            Button {
                onRecord(block)
            } label: {
                LessonBlockView(block: block, isCurrent: true)
            }
            .buttonStyle(.card)
        } else {
            LessonBlockView(block: block, isCurrent: false)
        }
    }

    private func isCurrent(_ block: LessonBlock, on day: DayLayout) -> Bool {
        guard calendar.isDateInToday(day.date) else { return false }
        let now = SchoolClock.minutes(of: .now, calendar: calendar)
        return now >= block.start && now < block.end
    }
}

/// One lesson in the grid.
struct LessonBlockView: View {
    let block: LessonBlock
    let isCurrent: Bool

    private var style: SubjectStyle { subjectStyle(for: block.subject) }
    private var isRecorded: Bool { block.recording != nil }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(style.color.opacity(block.cancelled ? 0.3 : isRecorded ? 1 : 0.5))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(block.title)
                        .font(.caption.weight(isRecorded ? .medium : .regular))
                        .strikethrough(block.cancelled)
                        .lineLimit(1)
                    if isRecorded {
                        Image(systemName: "waveform")
                            .font(.caption2)
                    }
                    if block.recording?.hasSummary == true {
                        Image(systemName: "sparkles")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                if let meta {
                    Text(meta)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background, in: shape)
        .overlay {
            shape.strokeBorder(border, style: StrokeStyle(lineWidth: 1, dash: block.cancelled ? [3, 2] : []))
        }
        .overlay(alignment: .bottomLeading) {
            if isCurrent, !isRecorded, !block.cancelled {
                Text("Aufnahme starten")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 3)
            }
        }
        .clipShape(shape)
        .opacity(block.cancelled ? 0.55 : 1)
        .foregroundStyle(block.cancelled ? Color.secondary : Color.primary)
    }

    private var background: AnyShapeStyle {
        if block.cancelled { return AnyShapeStyle(Color.clear) }
        if isRecorded { return AnyShapeStyle(style.color.opacity(0.16)) }
        return AnyShapeStyle(Color(.secondarySystemGroupedBackground))
    }

    private var border: AnyShapeStyle {
        if block.cancelled { return AnyShapeStyle(Color(.separator)) }
        if isCurrent { return AnyShapeStyle(Color.accentColor.opacity(0.8)) }
        if isRecorded { return AnyShapeStyle(style.color.opacity(0.35)) }
        return AnyShapeStyle(Color(.separator).opacity(0.8))
    }

    /// Room and teacher, plus the two words that change what the block means.
    private var meta: String? {
        var parts: [String] = []
        if block.cancelled { parts.append("entfällt") }
        if block.substitution { parts.append("Vertretung") }
        if let room = block.room { parts.append(room) }
        if let teacher = block.teacher { parts.append(teacher) }
        if !block.isScheduled, parts.isEmpty { parts.append("Aufnahme") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
