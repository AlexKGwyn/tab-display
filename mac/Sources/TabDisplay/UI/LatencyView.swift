import SwiftUI
import Charts

/// Debug window: live per-stage percentiles and a plot of recent frames.
struct LatencyView: View {
    @ObservedObject var model: AppModel
    @State private var rows: [Stats.Row] = []
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    private let stages = ["capture", "encode", "transfer", "decode", "present"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    Text("Stage").gridColumnAlignment(.leading)
                    Text("p50"); Text("p95")
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(model.snapshot.stages, id: \.name) { s in
                    GridRow {
                        Text(s.name).gridColumnAlignment(.leading)
                        Text(ms(s.p50)); Text(ms(s.p95))
                    }.fontWeight(s.name == "total" ? .semibold : .regular)
                }
                GridRow {
                    Text("pen input").gridColumnAlignment(.leading)
                    Text(ms(model.snapshot.penP50)); Text(ms(model.snapshot.penP95))
                }
            }
            .font(.system(.body, design: .monospaced))
            Text("\(Int(model.snapshot.fps)) fps · \(String(format: "%.1f", model.snapshot.mbps)) Mbps · dropped \(model.snapshot.dropped) · keyframes \(model.snapshot.keyframes) · clock rtt \(ms(model.clockRTT))")
                .font(.caption).foregroundStyle(.secondary)

            Chart {
                ForEach(rows, id: \.seq) { r in
                    ForEach(Array(zip(stages, [r.capture, r.encode, r.transfer, r.decode, r.present])), id: \.0) { name, v in
                        if !v.isNaN {
                            AreaMark(x: .value("frame", Int(r.seq)), y: .value("ms", v), stacking: .standard)
                                .foregroundStyle(by: .value("stage", name))
                        }
                    }
                }
            }
            .chartYAxisLabel("ms")
            .frame(minHeight: 260)

            HStack {
                Spacer()
                Button("Export last 60 s as CSV…") { model.exportCSV() }
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 480)
        .onReceive(timer) { _ in rows = model.session?.stats.recent(360).filter { !$0.transfer.isNaN && !$0.present.isNaN } ?? [] }
    }
}
