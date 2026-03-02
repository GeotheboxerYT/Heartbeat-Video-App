import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RecordView()
                .tabItem {
                    Label("Record", systemImage: "record.circle")
                }

            PlaybackView()
                .tabItem {
                    Label("Playback", systemImage: "play.rectangle")
                }
        }
    }
}

#Preview {
    ContentView()
}
