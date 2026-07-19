import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authStore: AuthStore

    @State private var selectedTab: AppTab = .record
    @State private var showTourPrompt = false
    @State private var showTourOverlay = false
    @State private var tourStepIndex = 0
    @State private var checkedTourPrompt = false

    private let tourSteps: [TourStep] = [
        TourStep(
            tab: .record,
            title: "Live Metrics",
            message: "Watch BPM and elapsed time while recording.",
            focus: RelativeFocus(x: 0.03, y: 0.03, width: 0.44, height: 0.15),
            callout: RelativePoint(x: 0.75, y: 0.19)
        ),
        TourStep(
            tab: .record,
            title: "Recording Mode",
            message: "Choose Video + HR or HR Only before you press Start.",
            focus: RelativeFocus(x: 0.16, y: 0.14, width: 0.68, height: 0.11),
            callout: RelativePoint(x: 0.50, y: 0.31)
        ),
        TourStep(
            tab: .record,
            title: "Record Controls",
            message: "Use Start/Stop and Flip camera from here.",
            focus: RelativeFocus(x: 0.04, y: 0.79, width: 0.92, height: 0.14),
            callout: RelativePoint(x: 0.50, y: 0.64)
        ),
        TourStep(
            tab: .record,
            title: "Heart-Rate Source",
            message: "Pick Bluetooth or Apple Health source here.",
            focus: RelativeFocus(x: 0.64, y: 0.66, width: 0.32, height: 0.20),
            callout: RelativePoint(x: 0.34, y: 0.72)
        ),
        TourStep(
            tab: .review,
            title: "Session Library",
            message: "Filter by date, refresh, and choose a workout session.",
            focus: RelativeFocus(x: 0.03, y: 0.08, width: 0.94, height: 0.30),
            callout: RelativePoint(x: 0.50, y: 0.47)
        ),
        TourStep(
            tab: .review,
            title: "Video + Chart",
            message: "Review heart-rate changes directly over your playback.",
            focus: RelativeFocus(x: 0.03, y: 0.36, width: 0.94, height: 0.35),
            callout: RelativePoint(x: 0.50, y: 0.17)
        ),
        TourStep(
            tab: .review,
            title: "Playback Controls",
            message: "Jump time and step frame-by-frame for precise review.",
            focus: RelativeFocus(x: 0.03, y: 0.72, width: 0.94, height: 0.20),
            callout: RelativePoint(x: 0.50, y: 0.58)
        ),
        TourStep(
            tab: .extras,
            title: "Extras",
            message: "PVT, Sleep, and PvP are grouped here to keep the app organized.",
            focus: RelativeFocus(x: 0.04, y: 0.08, width: 0.92, height: 0.11),
            callout: RelativePoint(x: 0.50, y: 0.33)
        ),
        TourStep(
            tab: .extras,
            title: "Psychomotor Vigilancee Task (PVT)",
            message: "Use PVT before and after workouts to compare readiness and alertness.",
            focus: RelativeFocus(x: 0.04, y: 0.20, width: 0.92, height: 0.60),
            callout: RelativePoint(x: 0.50, y: 0.13)
        ),
        TourStep(
            tab: .settings,
            title: "Settings",
            message: "Manage API, account, and storage in one place.",
            focus: RelativeFocus(x: 0.03, y: 0.09, width: 0.94, height: 0.82),
            callout: RelativePoint(x: 0.50, y: 0.16)
        ),
        TourStep(
            tab: .record,
            title: "Tabs",
            message: "Use tabs to switch between Record, Review, Extras, and Settings.",
            focus: RelativeFocus(x: 0.02, y: 0.91, width: 0.96, height: 0.08),
            callout: RelativePoint(x: 0.50, y: 0.75)
        ),
    ]

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            GeometryReader { geometry in
                TabView(selection: $selectedTab) {
                    RecordView()
                        .tabItem {
                            Label("Record", systemImage: "record.circle")
                        }
                        .tag(AppTab.record)

                    PlaybackView()
                        .tabItem {
                            Label("Review", systemImage: "waveform.path.ecg.rectangle")
                        }
                        .tag(AppTab.review)

                    ExtrasView()
                        .tabItem {
                            Label("Extras", systemImage: "square.grid.2x2")
                        }
                        .tag(AppTab.extras)

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .tag(AppTab.settings)
                }
                .environment(\.layoutViewportSize, geometry.size)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .allowsHitTesting(!showTourOverlay)

            if showTourOverlay {
                tourOverlay
            }
        }
        .onAppear {
            showTourPromptIfNeeded()
        }
        .onChange(of: selectedTab) { oldTab, newTab in
            if oldTab == .review && newTab != .review {
                NotificationCenter.default.post(name: .pauseReviewPlayback, object: nil)
            }
        }
        .onChange(of: authStore.currentUserEmail) { _, _ in
            resetTourStateForCurrentAccount()
        }
        .alert("Take a quick app tour?", isPresented: $showTourPrompt) {
            Button("Not Now", role: .cancel) {
                markTourPromptAsShown()
            }
            Button("Start Tour") {
                markTourPromptAsShown()
                startTour()
            }
        } message: {
            Text("We will quickly walk through each tab and what it does.")
        }
        .ignoresSafeArea(.keyboard)
    }

    private var currentTourStep: TourStep {
        tourSteps[min(max(tourStepIndex, 0), tourSteps.count - 1)]
    }

    private var tourOverlay: some View {
        GeometryReader { geometry in
            let focusRect = currentTourStep.focus.rect(in: geometry.size)
            let calloutWidth = min(292, geometry.size.width - 24)
            let calloutHeightEstimate: CGFloat = 190
            let rawCalloutX = geometry.size.width * currentTourStep.callout.x
            let rawCalloutY = geometry.size.height * currentTourStep.callout.y
            let calloutX = min(
                max(rawCalloutX, calloutWidth / 2 + 10),
                geometry.size.width - calloutWidth / 2 - 10
            )
            let calloutY = min(
                max(rawCalloutY, calloutHeightEstimate / 2 + geometry.safeAreaInsets.top + 8),
                geometry.size.height - calloutHeightEstimate / 2 - geometry.safeAreaInsets.bottom - 8
            )

            ZStack {
                spotlightOverlay(for: focusRect)

                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.yellow, lineWidth: 3)
                    .frame(width: focusRect.width, height: focusRect.height)
                    .position(x: focusRect.midX, y: focusRect.midY)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Quick Tour")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(tourStepIndex + 1)/\(tourSteps.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(currentTourStep.title)
                        .font(.subheadline.bold())
                    Text(currentTourStep.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Skip") {
                            showTourOverlay = false
                        }
                        .buttonStyle(.bordered)

                        Spacer()

                        Button(tourStepIndex == tourSteps.count - 1 ? "Done" : "Next") {
                            advanceTour()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(12)
                .frame(width: calloutWidth, alignment: .leading)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .position(x: calloutX, y: calloutY)
            }
        }
    }

    private func showTourPromptIfNeeded() {
        guard !checkedTourPrompt else { return }
        checkedTourPrompt = true

        guard let email = authStore.currentUserEmail else { return }
        let key = tourPromptStorageKey(for: email)
        guard UserDefaults.standard.bool(forKey: key) == false else { return }
        showTourPrompt = true
    }

    private func startTour() {
        tourStepIndex = 0
        selectedTab = tourSteps[0].tab
        showTourOverlay = true
    }

    private func advanceTour() {
        guard tourStepIndex < tourSteps.count - 1 else {
            showTourOverlay = false
            return
        }
        tourStepIndex += 1
        selectedTab = tourSteps[tourStepIndex].tab
    }

    private func markTourPromptAsShown() {
        guard let email = authStore.currentUserEmail else { return }
        UserDefaults.standard.set(true, forKey: tourPromptStorageKey(for: email))
    }

    private func tourPromptStorageKey(for email: String) -> String {
        "onboarding.tour.prompted.\(email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func spotlightOverlay(for focusRect: CGRect) -> some View {
        Color.black.opacity(0.36)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .frame(
                        width: max(focusRect.width + 8, 56),
                        height: max(focusRect.height + 8, 44)
                    )
                    .position(x: focusRect.midX, y: focusRect.midY)
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .ignoresSafeArea()
    }

    private func resetTourStateForCurrentAccount() {
        checkedTourPrompt = false
        showTourPrompt = false
        showTourOverlay = false
        tourStepIndex = 0
        showTourPromptIfNeeded()
    }
}

struct LayoutViewportSizeKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

extension EnvironmentValues {
    var layoutViewportSize: CGSize {
        get { self[LayoutViewportSizeKey.self] }
        set { self[LayoutViewportSizeKey.self] = newValue }
    }
}

private enum AppTab: Int, CaseIterable {
    case record = 0
    case review = 1
    case extras = 2
    case settings = 3
}

private struct RelativePoint {
    let x: CGFloat
    let y: CGFloat
}

private struct RelativeFocus {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    func rect(in size: CGSize) -> CGRect {
        CGRect(
            x: size.width * x,
            y: size.height * y,
            width: size.width * width,
            height: size.height * height
        )
    }
}

private struct TourStep {
    let tab: AppTab
    let title: String
    let message: String
    let focus: RelativeFocus
    let callout: RelativePoint
}

private enum ExtraFeature: String, CaseIterable, Identifiable {
    case pvt
    case sleep
    case pvp
    case journal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pvt:
            return "PVT"
        case .sleep:
            return "Sleep"
        case .pvp:
            return "PvP"
        case .journal:
            return "Journal"
        }
    }
}

private struct ExtrasView: View {
    @State private var selectedFeature: ExtraFeature = .pvt

    var body: some View {
        VStack(spacing: 10) {
            Picker("Feature", selection: $selectedFeature) {
                ForEach(ExtraFeature.allCases) { feature in
                    Text(feature.title).tag(feature)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)

            Group {
                switch selectedFeature {
                case .pvt:
                    PVTView()
                case .sleep:
                    SleepView()
                case .pvp:
                    PvPView()
                case .journal:
                    JournalView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthStore())
}
