import SwiftUI

struct JournalView: View {
    @EnvironmentObject private var authStore: AuthStore
    @StateObject private var viewModel = JournalViewModel()

    var body: some View {
        VStack(spacing: 10) {
            header

            if viewModel.entries.isEmpty {
                emptyState
            } else {
                entriesList
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .onAppear {
            viewModel.setUserEmail(authStore.currentUserEmail)
        }
        .onChange(of: authStore.currentUserEmail) { _, newEmail in
            viewModel.setUserEmail(newEmail)
        }
        .sheet(isPresented: $viewModel.isEditorPresented) {
            JournalEntryEditorView(viewModel: viewModel)
        }
        .alert("Journal Save Error", isPresented: saveErrorPresented) {
            Button("OK", role: .cancel) {
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error.")
        }
    }

    private var header: some View {
        HStack {
            Text("Journal")
                .font(.system(size: 30, weight: .black, design: .rounded))

            Spacer()

            Button {
                viewModel.startNewEntry()
            } label: {
                Label("New", systemImage: "square.and.pencil")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No entries yet.")
                .font(.headline)
            Text("Log what you trained, what you ate, how much you slept, what happened during your day, and any extra notes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Create First Entry") {
                viewModel.startNewEntry()
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var entriesList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(viewModel.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(viewModel.displayDate(for: entry))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                viewModel.delete(entry)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }

                        Text(viewModel.headline(for: entry))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        let detail = viewModel.detailLine(for: entry)
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture {
                        viewModel.startEditing(entry)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var saveErrorPresented: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { newValue in
                if !newValue {
                    viewModel.errorMessage = nil
                }
            }
        )
    }
}

private struct JournalEntryEditorView: View {
    @ObservedObject var viewModel: JournalViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let autoFillMessage = viewModel.autoFillMessage {
                        Text(autoFillMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Button("Refresh Auto-Fill From Today") {
                        viewModel.refreshAutoFillForToday()
                    }
                    .buttonStyle(.bordered)
                }

                Section("Training") {
                    entryEditor(
                        text: Binding(
                            get: { viewModel.draft.trainingNotes },
                            set: { viewModel.draft.trainingNotes = $0 }
                        ),
                        placeholder: "Workout details, drills, sets, intensity..."
                    )
                }

                Section("Nutrition") {
                    entryEditor(
                        text: Binding(
                            get: { viewModel.draft.nutritionNotes },
                            set: { viewModel.draft.nutritionNotes = $0 }
                        ),
                        placeholder: "Meals, hydration, supplements..."
                    )
                }

                Section("Sleep") {
                    TextField(
                        "Hours slept",
                        text: Binding(
                            get: { viewModel.draft.sleepHoursText },
                            set: { viewModel.draft.sleepHoursText = $0 }
                        )
                    )
                    .keyboardType(.decimalPad)

                    entryEditor(
                        text: Binding(
                            get: { viewModel.draft.sleepNotes },
                            set: { viewModel.draft.sleepNotes = $0 }
                        ),
                        placeholder: "Sleep quality, wake-ups, naps..."
                    )
                }

                Section("Day") {
                    entryEditor(
                        text: Binding(
                            get: { viewModel.draft.dayNotes },
                            set: { viewModel.draft.dayNotes = $0 }
                        ),
                        placeholder: "Work stress, schedule, life events..."
                    )
                }

                Section("Other") {
                    entryEditor(
                        text: Binding(
                            get: { viewModel.draft.extraNotes },
                            set: { viewModel.draft.extraNotes = $0 }
                        ),
                        placeholder: "Anything else worth tracking..."
                    )
                }
            }
            .navigationTitle("Journal Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelEditing()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.saveDraft()
                    }
                }
            }
        }
    }

    private func entryEditor(text: Binding<String>, placeholder: String) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(placeholder)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
            }
            TextEditor(text: text)
                .frame(minHeight: 90)
        }
    }
}

#Preview {
    JournalView()
        .environmentObject(AuthStore())
}
