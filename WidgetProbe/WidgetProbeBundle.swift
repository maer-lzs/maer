import SwiftUI
import WidgetKit

// Y11c CONTROL PROBE — a bare template-shaped widget extension, TEMPORARY:
// if this appears in a real device's widget gallery while the Mär widgets do
// not, the defect is inside our extension; if it is missing too, the defect is
// at project/signing level. Remove the whole WidgetProbe target after the
// experiment.

@main
struct WidgetProbeBundle: WidgetBundle {
    var body: some Widget {
        WidgetProbe()
    }
}

struct WidgetProbe: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WidgetProbe", provider: ProbeProvider()) { entry in
            Text(verbatim: "Probe \(entry.date.formatted(date: .omitted, time: .shortened))")
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(Text(verbatim: "Mär Probe"))
        .description(Text(verbatim: "Y11c control probe"))
    }
}

struct ProbeEntry: TimelineEntry {
    let date: Date
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry { ProbeEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(ProbeEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        completion(Timeline(entries: [ProbeEntry(date: .now)], policy: .never))
    }
}
