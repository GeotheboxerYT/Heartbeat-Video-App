import Charts
import SwiftUI

struct RecordView: View {
    @StateObject private var viewModel = RecordViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Record")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                ZStack(alignment: .topLeading) {
                    CameraPreviewView(session: viewModel.cameraRecorder.captureSession)
                        .frame(maxWidth: .infinity, minHeight: 280)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(viewModel.currentBPM) BPM")
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .italic()
                        Text(viewModel.isBLEConnected ? "Strap Connected" : "Searching for Strap")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .italic()
                            .foregroundStyle(viewModel.isBLEConnected ? .green : .white.opacity(0.85))
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 8)
                    .padding(.top, 10)

                    VStack {
                        HStack {
                            Spacer()
                            Text(viewModel.cameraLabel)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .italic()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.black.opacity(0.22))
                                .clipShape(Capsule())
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 10)

                    LiveHeartRateGraphOverlayView(bpmPoints: viewModel.liveBPMGraphPoints)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(spacing: 10) {
                    Button {
                        if viewModel.isRecording {
                            viewModel.stopRecording()
                        } else {
                            viewModel.startRecording()
                        }
                    } label: {
                        Label(viewModel.isRecording ? "Stop" : "Record", systemImage: viewModel.isRecording ? "stop.fill" : "record.circle.fill")
                            .font(.system(size: 16, weight: .black, design: .rounded))
                            .italic()
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canStartRecording && !viewModel.isRecording)

                    Button("Flip Camera") {
                        viewModel.toggleCamera()
                    }
                    .font(.system(size: 14, weight: .bold, design: .rounded).italic())
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isRecording)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                if viewModel.pvtComparisonEnabled {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("PVT Comparison Flow")
                            .font(.headline)

                        HStack(spacing: 10) {
                            Button("Pre-PVT") {
                                viewModel.beginPrePVT()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!viewModel.canRunPrePVT)

                            Button("Post-PVT") {
                                viewModel.beginPostPVT()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!viewModel.canRunPostPVT)
                        }

                        Text("Pre: \(viewModel.preSummaryText)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Post: \(viewModel.postSummaryText)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if viewModel.shouldShowPVTComparison {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Pre vs Post PVT")
                            .font(.headline)

                        pvtChartCard(title: "Before Recording", points: viewModel.prePVTChartPoints, color: .blue)
                        pvtChartCard(title: "After Recording", points: viewModel.postPVTChartPoints, color: .orange)
                    }
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await viewModel.prepare()
        }
        .fullScreenCover(isPresented: $viewModel.isComparisonPVTPresented) {
            RecordPVTSessionView(
                durationSeconds: viewModel.comparisonPVTDurationSeconds,
                title: viewModel.activeComparisonPVTPhase == .pre ? "Pre-PVT" : "Post-PVT",
                onCancel: {
                    viewModel.cancelComparisonPVT()
                },
                onComplete: { result in
                    viewModel.completeComparisonPVT(with: result)
                }
            )
        }
    }

    @ViewBuilder
    private func pvtChartCard(title: String, points: [RecordViewModel.PVTChartPoint], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.bold())

            if points.isEmpty {
                Text("No data")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Trial", point.trial),
                        y: .value("Reaction (ms)", point.reactionMS)
                    )
                    .foregroundStyle(color)
                }
                .frame(height: 130)
            }
        }
        .padding(10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    RecordView()
}
