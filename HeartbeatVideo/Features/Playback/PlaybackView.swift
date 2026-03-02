import AVKit
import SwiftUI

struct PlaybackView: View {
    @StateObject private var viewModel = PlaybackViewModel()

    var body: some View {
        VStack(spacing: 16) {
            Picker("Session", selection: $viewModel.selectedSessionID) {
                ForEach(viewModel.sessions, id: \.sessionID) { session in
                    Text(session.sessionID).tag(Optional(session.sessionID))
                }
            }
            .pickerStyle(.menu)
            .onChange(of: viewModel.selectedSessionID) { _, _ in
                viewModel.loadSelectedSession()
            }

            VideoPlayer(player: viewModel.player)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .frame(minHeight: 300)

            Text("\(viewModel.displayedBPM) BPM")
                .font(.title3.bold())

            Slider(value: $viewModel.scrubTime, in: 0...viewModel.duration)
                .onChange(of: viewModel.scrubTime) { _, newValue in
                    viewModel.seek(to: newValue)
                }

            HStack(spacing: 12) {
                Button("- Frame") {
                    viewModel.stepFrame(forward: false)
                }
                .buttonStyle(.bordered)

                Button("Play") {
                    viewModel.player.play()
                }
                .buttonStyle(.borderedProminent)

                Button("Pause") {
                    viewModel.player.pause()
                }
                .buttonStyle(.bordered)

                Button("+ Frame") {
                    viewModel.stepFrame(forward: true)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .task {
            viewModel.loadSessions()
        }
    }
}

#Preview {
    PlaybackView()
}
