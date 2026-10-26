import DictationCore
import SwiftUI

struct HistoryPage: View {
    let services: WindowServices
    @State private var confirmingDelete = false

    var body: some View {
        let count = services.history.entries.count
        let willow = services.willow
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageTitle("History")
                CheckRow(title: "Keep history", help: "Each dictation's text, app and time stay on this Mac. Audio is never saved.",
                         isOn: services.preferences.binding(\.keepHistory))
                    .padding(.bottom, 32)
                SectionHeader(title: "\(HomePage.count(count)) on this Mac", detail: "Deleting them can't be undone.")
                Button("Delete All History…", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(DarkButtonStyle(kind: .destructive))
                    .disabled(count == 0)
                if willow.isAvailable {
                    SectionHeader(title: "Willow", detail: willowDetail).padding(.top, 34)
                    if willow.phase == .importing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Import from Willow") { willow.run() }.buttonStyle(DarkButtonStyle())
                    }
                }
            }
            .page()
        }
        .confirmationDialog("Delete all history?", isPresented: $confirmingDelete) {
            Button("Delete All History", role: .destructive) { services.history.deleteAll() }
        } message: {
            Text("This removes \(HomePage.count(count)) from this Mac. It can't be undone.")
        }
    }

    private var willowDetail: String {
        if case .finished(let message) = services.willow.phase { return message }
        return "Copies your Willow dictations and settings. Importing again adds nothing twice."
    }
}
