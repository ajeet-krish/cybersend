import PhotosUI
import SwiftUI

// Library import (M3, US-17): PhotosPicker in a sheet returns image bytes and nothing
// else. PhotosPicker runs out of process, so no photo library usage string exists and no
// permission surface is reachable. A load failure shows a plain error and produces zero
// writes: no bytes leave this sheet, so the ingest pipeline never starts.

struct PhotoImportSheet: View {
    /// Hands the picked image bytes to the caller; the caller runs them through the
    /// store (add or replace), the single path to any file write.
    let onImport: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Screen {
                if let errorMessage {
                    ErrorNote(errorMessage)
                        .accessibilityIdentifier("photo.import.error")
                }
                PhotosPicker(selection: $selection, matching: .images) {
                    Label("Select a photo", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("photo.import.picker")
                Text("The photo is copied into this app and never uploaded.")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("photo.import.note")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.screenBackground.ignoresSafeArea())
            .navigationTitle("Choose from library")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("photo.import.cancel")
                }
            }
        }
        .onChange(of: selection) { item in
            load(item)
        }
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        errorMessage = nil
        Task {
            do {
                guard let bytes = try await item.loadTransferable(type: Data.self), !bytes.isEmpty else {
                    errorMessage = "That photo could not be loaded. Try another one."
                    return
                }
                onImport(bytes)
                dismiss()
            } catch {
                // Plain error, zero writes: the failure path hands no bytes upward, so
                // the climb editor never calls the store and no file lands on disk.
                errorMessage = "That photo could not be loaded. Try another one."
            }
        }
    }
}
