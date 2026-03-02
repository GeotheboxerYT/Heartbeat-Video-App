import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            TabView {
                RecordView()
                    .tabItem {
                        Label("Record", systemImage: "record.circle")
                    }

                PlaybackView()
                    .tabItem {
                        Label("Review", systemImage: "waveform.path.ecg.rectangle")
                    }

                PVTView()
                    .tabItem {
                        Label("PVT", systemImage: "timer")
                    }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape")
                    }
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
                .ignoresSafeArea(edges: .top)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 1)
                .ignoresSafeArea(edges: .bottom)
        }
    }
}

#Preview {
    ContentView()
}
