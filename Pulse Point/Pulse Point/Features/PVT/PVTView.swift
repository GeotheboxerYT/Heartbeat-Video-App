import SwiftUI

struct PVTView: View {
    @StateObject private var viewModel = PVTViewModel()

    var body: some View {
        ZStack {
            switch viewModel.phase {
            case .setup:
                setupView
            case .instructions:
                instructionsView
            case .running:
                runningView
            case .result:
                resultView
            }
        }
    }

    private var setupView: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Psychomotor Vigilance Task")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Choose duration")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(viewModel.durationOptions, id: \.self) { seconds in
                        let mins = seconds / 60
                        Button("\(mins) Mins") {
                            viewModel.chooseDuration(seconds)
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .tint(viewModel.selectedDurationSeconds == seconds ? .blue : .gray)
                    }
                }

                Button("Continue") {
                    viewModel.showInstructions()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var instructionsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Instructions")
                    .font(.title2.bold())

                instructionRow(icon: "circle.fill", text: "Only tap the circle.")
                instructionRow(icon: "triangle.fill", text: "Do not tap triangles.")
                instructionRow(icon: "hand.tap.fill", text: "Tapping before shapes appear counts as a false start.")
                instructionRow(icon: "timer", text: "Shapes appear every 3 to 5 seconds.")

                HStack(spacing: 12) {
                    Button("Back") {
                        viewModel.backToSetup()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button("Start Task") {
                        viewModel.startTask()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var runningView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                Text("\(Int(ceil(viewModel.remainingSeconds)))s")
                    .font(.headline)
                    .foregroundStyle(.white)

                if viewModel.isStimulusVisible {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                        ForEach(0..<4, id: \.self) { index in
                            Button {
                                viewModel.tapShape(index: index)
                            } label: {
                                shapeView(isCircle: index == viewModel.correctIndex)
                                    .frame(width: 95, height: 95)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 30)
                }
            }

            if let flash = viewModel.flashColor {
                (flash == .green ? Color.green : Color.red)
                    .opacity(0.5)
                    .ignoresSafeArea()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.tapBackgroundWhileWaiting()
        }
    }

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("PVT Results")
                    .font(.title2.bold())

                if let result = viewModel.result {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Duration: \(result.durationSeconds / 60) mins")
                        Text("Stimuli shown: \(result.totalStimuliShown)")
                        Text("Correct taps: \(result.correctTaps)")
                        Text("Incorrect taps: \(result.incorrectTaps)")
                        Text("False starts: \(result.falseStarts)")
                        Text("Anticipatory taps (<100ms): \(result.anticipatoryTaps)")
                        Text("Misses: \(result.misses)")
                        Text("Lapses (>=500ms + misses): \(result.lapses)")
                        Text("Mean reaction: \(result.meanReactionMS) ms")
                        Text("Median reaction: \(result.medianReactionMS) ms")
                        Text("Fastest reaction: \(result.fastestReactionMS) ms")
                        Text("Slowest reaction: \(result.slowestReactionMS) ms")
                    }
                    .font(.body)
                    .padding(12)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }

                Button("Discard Result") {
                    viewModel.discardResult()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 12)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func instructionRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(text)
        }
    }

    @ViewBuilder
    private func shapeView(isCircle: Bool) -> some View {
        if isCircle {
            Circle()
                .fill(.red)
        } else {
            Triangle()
                .fill(.red)
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    PVTView()
}

// M0unt@1n12!
