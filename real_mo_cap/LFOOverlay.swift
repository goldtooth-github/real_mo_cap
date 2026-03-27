import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Publishes the frame of the LFO overlay so parents can ignore taps in this area
struct LFOOverlayFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .null
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .null { value = next }
    }
}

// Publishes whether an LFO overlay note field is currently being edited
//struct LFOEditingActiveKey: PreferenceKey {
//    static var defaultValue: Bool = false
//    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
//}

// Helper to dismiss keyboard globally
private func dismissKeyboardGlobal() {
    #if canImport(UIKit)
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    #endif
}

// Preference to measure overlay height reliably
//private struct OverlayHeightKey: PreferenceKey {
//    static var defaultValue: CGFloat = 0
//    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }//
//}
/*
// Reusable overlay for showing LFO (CC) value histories as sparklines
public struct LFOOverlayView: View {
    // Inject settings actions from environment
    @EnvironmentObject var settingsIO: SettingsIOActions
    let labels: [String]
    let histories: [[CGFloat]]
    let colors: [Color]
    let topMargin: CGFloat
    // Optional double-tap callback with tapped index
    let onDoubleTap: ((Int) -> Void)?
    // New: configurable threshold fraction (of screen height) for compact mode
    let compactThresholdFraction: CGFloat
    // Maximum total samples for all overlays
    private let lfoMaxSamples: Int = 50
    // Measured height of this overlay's content
    @State private var overlayHeight: CGFloat = 0
    public init(labels: [String], histories: [[CGFloat]], colors: [Color], topMargin: CGFloat = 16, onDoubleTap: ((Int) -> Void)? = nil, compactThresholdFraction: CGFloat = 0.15) {
        self.labels = labels
        self.histories = histories
        self.colors = colors
        self.topMargin = topMargin
        self.onDoubleTap = onDoubleTap
        self.compactThresholdFraction = compactThresholdFraction
    }
    public var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("LFO Outputs")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    HStack(spacing: 12) {
                        Button(action: {
                            if let cb = settingsIO.requestImport { cb() } else { settingsIO.importFile() }
                        }) {
                            Image(systemName: "folder").foregroundColor(.white)
                        }
                        Button(action: {
                            if let cb = settingsIO.requestExport { cb() } else { settingsIO.exportFile() }
                        }) {
                            Image(systemName: "square.and.arrow.down").foregroundColor(.white)
                        }
                        Button(action: {
                            if let cb = settingsIO.requestReset { cb() } else { settingsIO.reset() }
                        }) {
                            Image(systemName: "arrow.counterclockwise").foregroundColor(.white)
                        }
                    }
                }
                HStack(spacing: 8) {
                    ForEach(histories.indices, id: \.self) { i in
                        VStack(spacing: 4) {
                            SparklineView(values: histories[i], stroke: colors[i], resolution: 50)
                                .frame(width: 60, height: 40)
                            Text(labels[i])
                                .font(.caption)
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                    }
                }
                .padding(8)
            }
            .padding(8)
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Measure actual overlay height
            .background(
                GeometryReader { inner in
                    Color.clear.preference(key: OverlayHeightKey.self, value: inner.size.height)
                }
            )
            .onPreferenceChange(OverlayHeightKey.self) { overlayHeight = $0 }
        }
        .frame(maxHeight: 100)
        .padding(.top, topMargin)
        // Publish the overlay frame in parent's coordinate space named "simulationRoot"
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LFOOverlayFrameKey.self,
                    value: proxy.frame(in: .named("simulationRoot"))
                )
            }
        )
    }
}*/

public struct SparklineView: View {
    let values: [CGFloat]
    let stroke: Color
    let resolution: Int
    public init(values: [CGFloat], stroke: Color, resolution: Int = 64) {
        self.values = values
        self.stroke = stroke
        self.resolution = resolution
    }
    private func downsample(_ values: [CGFloat], to resolution: Int) -> [CGFloat] {
        guard values.count > resolution, resolution > 1 else { return values }
        let step = Double(values.count - 1) / Double(resolution - 1)
        return (0..<resolution).map { i in
            let idx = Int(round(Double(i) * step))
            return values[min(idx, values.count - 1)]
        }
    }
    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let dsValues = downsample(values, to: resolution)
            let n = max(dsValues.count, 2)
            let step = w / CGFloat(max(n - 1, 1))
            Path { path in
                for (i, v) in dsValues.enumerated() {
                    let x = CGFloat(i) * step
                    let y = h - (v * h)
                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(stroke, lineWidth: 2)
        }
    }
}

// MARK: - Memory-stable ring history overlay retaining legacy visual style
struct LFORingOverlayView: View { // removed public to avoid exposing internal RingHistory in public API
   
    @EnvironmentObject var settingsIO: SettingsIOActions
    let labels: [String]
    let histories: [RingHistory]
    let colors: [Color]
    // Optional per-slot MIDI meta
    let channels: [Int]?
    let ccNumbers: [Int]?
    // Optional editable notes per slot
    let notes: [Binding<String>]? // binds to MIDIParams.coordinateName
    let topMargin: CGFloat
   let onDoubleTap: ((Int) -> Void)?
    // Track which note TextField is focused (editing)
   // @FocusState private var focusedNoteIndex: Int?
    // New: configurable threshold fraction
    let compactThresholdFraction: CGFloat
    // Measured height of this overlay's content
   // @State private var overlayHeight: CGFloat = 0
    init(labels: [String], histories: [RingHistory], colors: [Color], channels: [Int]? = nil, ccNumbers: [Int]? = nil, notes: [Binding<String>]? = nil, topMargin: CGFloat = 16, onDoubleTap: ((Int) -> Void)? = nil, compactThresholdFraction: CGFloat = 0.15) {
        self.labels = labels
        self.histories = histories
        self.colors = colors
        self.channels = channels
        self.ccNumbers = ccNumbers
        self.notes = notes
        self.topMargin = topMargin
        self.onDoubleTap = onDoubleTap
        self.compactThresholdFraction = compactThresholdFraction
    }
    public var body: some View {
        GeometryReader { geo in
            
            let screenLongSide: CGFloat = {
                #if canImport(UIKit)
                let b = UIScreen.main.bounds
                return max(b.width, b.height)
                #else
                return max(geo.size.width, geo.size.height)
                #endif
            }()
           // let isCompact = overlayHeight > 0 ? (overlayHeight <= screenLongSide * compactThresholdFraction) : false
            let total = max(labels.count, 1)
            let spacing: CGFloat = 12
            let paddingH: CGFloat = 16
            let available = max(geo.size.width - paddingH, 50)
            let itemW = max<CGFloat>(0, (available - CGFloat(max(total - 1, 0)) * spacing) / CGFloat(total))
            
            
            
            
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Text("LFO Outputs")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    HStack(spacing: 12) {
                        Button(action: {
                            if let cb = settingsIO.requestImport { cb() } else { settingsIO.importFile() }
                        }) {
                            Image(systemName: "folder").foregroundColor(.white)
                        }
                        Button(action: {
                            if let cb = settingsIO.requestExport { cb() } else { settingsIO.exportFile() }
                        }) {
                            Image(systemName: "square.and.arrow.down").foregroundColor(.white)
                        }
                        Button(action: {
                            if let cb = settingsIO.requestReset { cb() } else { settingsIO.reset() }
                        }) {
                            Image(systemName: "arrow.counterclockwise").foregroundColor(.white)
                        }
                    }
                }
                HStack(spacing: 8) {
                    let total = max(labels.count, 1)
                    let spacing: CGFloat = 12
                    let paddingH: CGFloat = 16
                    let available = max(geo.size.width - paddingH, 50)
                    let itemW = max(0, (available - CGFloat(max(total - 1, 0)) * spacing) / CGFloat(total))
                    ForEach(0..<total, id: \ .self) { i in
                        let color = i < colors.count ? colors[i] : Color.cyan
                        let label = i < labels.count ? labels[i] : ""
                        let history = i < histories.count ? histories[i] : nil
                        let channelText: String? = (channels != nil && ccNumbers != nil && i < channels!.count && i < ccNumbers!.count) ? "CH \(channels![i])   CC \(ccNumbers![i])" : nil
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .center, spacing: 8) {
                                Circle()
                                    .fill(color)
                                    .frame(width: 14, height: 14)
                                Text(label)
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.9))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            RingHistorySparkline(history: history, stroke: color)
                                .frame(width: itemW, height: 40)
                                
                            if let channelText = channelText {
                                Text(channelText)
                                    .font(.caption2)
                                    .foregroundColor(.gray.opacity(0.7))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(width: itemW, height: 60, alignment: .leading) // Ensure full slot area
                          .contentShape(Rectangle()) // Make the whole area tappable
                          .onTapGesture(count: 2) { onDoubleTap?(i) }
                       
                    }
                }
                .padding(8)
            }
            .padding(8)
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Measure actual overlay height
          //  .onPreferenceChange(OverlayHeightKey.self) { overlayHeight = $0 }
        }
        .frame(maxHeight: 100)
        .padding(.top, topMargin)
        // Publish the overlay frame in parent's coordinate space named "simulationRoot"
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LFOOverlayFrameKey.self,
                    value: proxy.frame(in: .named("simulationRoot"))
                )
            }
        )
    }
}

private struct RingHistorySparkline: View {
    @ObservedObject var history: RingHistory
    let stroke: Color
    init(history: RingHistory?, stroke: Color) {
        self.history = history ?? RingHistory(capacity: 1)
        self.stroke = stroke
    }
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let n = max(history.count, 2)
          let step = w / CGFloat(max(n - 1, 1))
           ZStack(alignment: .center) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.5))
                    p.addLine(to: CGPoint(x: w, y: h * 0.5))
                }.stroke(Color.white.opacity(0.15), lineWidth: 1)
                Path { p in
                    var didMove = false
                   history.forEachOrdered { i, v in
                        let clamped = min(max(v, 0), 1)
                        let x = CGFloat(i) * step
                    let y = (1 - clamped) * h
                        if !didMove { p.move(to: CGPoint(x: x, y: y)); didMove = true } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                    if history.count == 0 { // fallback line
                        p.move(to: CGPoint(x: 0, y: h * 0.5))
                        p.addLine(to: CGPoint(x: w, y: h * 0.5))
                    }
                }
                .stroke(stroke, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
