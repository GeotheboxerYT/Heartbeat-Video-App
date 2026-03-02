import AVKit
import Charts
import SwiftUI

struct PlaybackView: View {
    @StateObject private var viewModel = PlaybackViewModel()
    @AppStorage(AppSettings.Keys.chartScrubMode) private var chartScrubMode = "normal"

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Review")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Picker("Session", selection: $viewModel.selectedSessionID) {
                    ForEach(viewModel.sessions, id: \.sessionID) { session in
                        Text(session.sessionID).tag(Optional(session.sessionID))
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: viewModel.selectedSessionID) { _, _ in
                    viewModel.loadSelectedSession()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Session Summary")
                        .font(.headline)

                    HStack {
                        Text("Duration")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(viewModel.summaryDurationLabel)
                            .fontWeight(.semibold)
                    }
                    .font(.footnote)

                    HStack {
                        Text("HR Samples")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(viewModel.summarySampleCountLabel)
                            .fontWeight(.semibold)
                    }
                    .font(.footnote)

                    Divider()

                    Text(viewModel.trainingTypeTitle)
                        .font(.subheadline.bold())
                    Text(viewModel.trainingTypeDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                ZStack(alignment: .bottom) {
                    VideoPlayer(player: viewModel.player)
                        .frame(maxWidth: .infinity, minHeight: 300)

                    if !viewModel.chartSamples.isEmpty {
                        Chart {
                            ForEach(viewModel.chartSamples, id: \.self) { sample in
                                LineMark(
                                    x: .value("Time", sample.t),
                                    y: .value("BPM", sample.bpm)
                                )
                                .foregroundStyle(.red)
                            }

                            RuleMark(x: .value("Current Time", viewModel.scrubTime))
                                .foregroundStyle(.white)
                                .lineStyle(StrokeStyle(lineWidth: 2))
                        }
                        .chartYScale(domain: 60...202)
                        .chartXScale(domain: 0...viewModel.duration)
                        .chartYAxis(.hidden)
                        .chartXAxis(.hidden)
                        .frame(height: 120)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .background(Color.black.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .chartOverlay { proxy in
                            GeometryReader { geometry in
                                Rectangle()
                                    .fill(.clear)
                                    .contentShape(Rectangle())
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { value in
                                                guard let plotFrame = proxy.plotFrame else { return }
                                                let plotArea = geometry[plotFrame]
                                                let xPosition = value.location.x - plotArea.origin.x
                                                guard let time: Double = proxy.value(atX: xPosition) else { return }
                                                let clamped = min(max(0, time), viewModel.duration)
                                                if chartScrubMode == "smooth" {
                                                    viewModel.commitScrub(to: clamped)
                                                } else {
                                                    viewModel.previewScrub(to: clamped)
                                                }
                                            }
                                            .onEnded { value in
                                                guard let plotFrame = proxy.plotFrame else { return }
                                                let plotArea = geometry[plotFrame]
                                                let xPosition = value.location.x - plotArea.origin.x
                                                guard let time: Double = proxy.value(atX: xPosition) else { return }
                                                let clamped = min(max(0, time), viewModel.duration)
                                                viewModel.commitScrub(to: clamped)
                                            }
                                    )
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(spacing: 8) {
                    HStack {
                        Text("\(viewModel.displayedBPM) BPM")
                            .font(.title3.bold())
                        Spacer()
                        Text(viewModel.timeLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !viewModel.chartSamples.isEmpty {
                        HStack(spacing: 8) {
                            statPill(title: "Min", value: "\(viewModel.minBPM)")
                            statPill(title: "Avg", value: "\(viewModel.avgBPM)")
                            statPill(title: "Max", value: "\(viewModel.maxBPM)")
                        }
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Button("-5s") {
                            viewModel.jump(seconds: -5)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        Button {
                            viewModel.togglePlayback()
                        } label: {
                            Image(systemName: viewModel.player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("+5s") {
                            viewModel.jump(seconds: 5)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }

                    HStack(spacing: 10) {
                        Button("- Frame") {
                            viewModel.stepFrame(forward: false)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)

                        Button("+ Frame") {
                            viewModel.stepFrame(forward: true)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            viewModel.loadSessions()
        }
        .onAppear {
            viewModel.loadSessions()
        }
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    PlaybackView()
}
