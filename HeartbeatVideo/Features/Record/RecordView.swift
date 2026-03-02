import SwiftUI

struct RecordView: View {
    @StateObject private var viewModel = RecordViewModel()

    var body: some View {
        VStack(spacing: 16) {
            CameraPreviewView(session: viewModel.cameraRecorder.captureSession)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(viewModel.currentBPM) BPM")
                            .font(.title2.bold())
                        Text(viewModel.isBLEConnected ? "Strap Connected" : "Searching for Strap")
                            .font(.caption)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(10)
                }

            HStack(spacing: 16) {
                Button("Start") {
                    viewModel.startRecording()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRecording)

                Button("Stop") {
                    viewModel.stopRecording()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.isRecording)
            }

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
            }
        }
        .padding()
        .task {
            await viewModel.prepare()
        }
    }
}

#Preview {
    RecordView()
}
