import CyberSendDomain
import CyberSendFeatures
import SwiftUI
import UIKit

// Climb editor screen (M2 Task 5, US-10, port of app/climb/[id].tsx): create a climb
// (LogbookRoute.climbDetail with climbId "new") or edit one. Grade is a (scheme, level)
// chip pair, never free text (US-9); the wall angle is nullable and validated 0 to 90
// (US-10.2); archiving keeps attempts and deleting is blocked while attempts exist
// (US-26). M3 Task 3 adds the photo section (camera seam, PhotosPicker import, and the
// Development only synthetic capture, all through the one PhotoStore ingest path) and
// the holds section that links to the tagging route.

struct ClimbEditorView: View {
    let climbId: String
    /// The composition services (photo storage for thumbnails, repositories through the
    /// stores). Captured at init because the environment copy is optional in previews.
    let services: AppServices
    /// "climb" from the Logbook stack, "problem" from the Problems catalog. The row is the
    /// same entity; only the wording the climber reads changes.
    var noun: String = "climb"
    /// Overrides the gym a create writes to. The session editor passes the session's gym so
    /// an inline add lands in the gym the climber is standing in, not the home selection.
    var gymId: String?
    /// Keeps the sheet open after a create, switched to that climb's edit state, so the
    /// photo and holds sections are reachable without closing and reopening.
    var keepsOpenAfterCreate: Bool = false
    /// Called with the stored climb after every successful save, before dismissal.
    var onSaved: ((Climb) -> Void)?

    @EnvironmentObject private var logbook: LogbookStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var store: ClimbEditorStore
    @StateObject private var photoStore: PhotoStore
    @StateObject private var camera: SystemCameraCapture

    @State private var actionError: String?
    @State private var confirmDelete = false
    @State private var showPhotoSourceDialog = false
    @State private var showLibrarySheet = false
    @State private var confirmPhotoDelete = false
    @State private var photoIngestError: String?

    init(
        climbId: String,
        services: AppServices,
        noun: String = "climb",
        gymId: String? = nil,
        keepsOpenAfterCreate: Bool = false,
        onSaved: ((Climb) -> Void)? = nil
    ) {
        self.climbId = climbId
        self.services = services
        self.noun = noun
        self.gymId = gymId
        self.keepsOpenAfterCreate = keepsOpenAfterCreate
        self.onSaved = onSaved
        // "new" is the LogbookRoute creation id (port of the TypeScript climb screen).
        _store = StateObject(wrappedValue: ClimbEditorStore(
            repos: services.repos,
            climbId: climbId == "new" ? nil : climbId
        ))
        _photoStore = StateObject(wrappedValue: PhotoStore(
            repos: services.repos,
            storage: services.media.storage
        ))
        _camera = StateObject(wrappedValue: SystemCameraCapture())
    }

    var body: some View {
        Screen {
            if let message = actionError ?? store.lastErrorMessage ?? photoStore.lastErrorMessage ?? photoIngestError {
                ErrorNote(message)
                    .accessibilityIdentifier("climb.error")
            }

            SectionTitle("Name")
            Card {
                TextField("For example: Blue V4 slab", text: $store.name)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.words)
                    .accessibilityIdentifier("climb.name")
            }

            // Grade is a menu rather than a chip strip: the scheme list and the V scale
            // level range are long enough that a horizontal strip pushed the level the
            // climber wanted off screen, and a menu is one tap either way.
            SectionTitle("Grade")
            Card {
                HStack {
                    Text("Scheme")
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 12)
                    Picker("Scheme", selection: Binding(
                        get: { store.schemeId },
                        set: { store.selectScheme($0) }
                    )) {
                        ForEach(store.gradeSystems) { system in
                            Text(system.name).tag(system.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accentSolid)
                    .accessibilityIdentifier("climb.scheme")
                }
                Divider()
                    .overlay(Theme.separator)
                HStack {
                    Text("Level")
                        .foregroundStyle(Theme.secondaryText)
                    Spacer(minLength: 12)
                    if let levels = store.selectedLevels {
                        Picker("Level", selection: $store.levelId) {
                            Text("None").tag(String?.none)
                            ForEach(levels) { level in
                                Text(level.label).tag(String?.some(level.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.accentSolid)
                        .accessibilityIdentifier("climb.level")
                    } else {
                        Text("Scheme not found.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("climb.level.missing")
                    }
                }
            }

            SectionTitle("Details")
            Card {
                TextField("Wall angle in degrees (optional, 0 to 90)", text: $store.angleText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .accessibilityIdentifier("climb.angle")
                TextField("Color circuit (optional)", text: $store.colorCircuit)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.words)
                    .accessibilityIdentifier("climb.color")
                TextField(
                    "Problem details (optional): beta, style, what to remember",
                    text: $store.notes,
                    axis: .vertical
                )
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("climb.notes")
            }

            PrimaryButton(store.isNew ? "Add \(noun)" : "Save changes") {
                save()
            }
            .accessibilityIdentifier("climb.save")

            if !store.isNew {
                photoSection
                holdsSection
                SectionTitle("Manage")
                Card {
                    Text(DisplayText.attemptCount(store.attemptCount))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .accessibilityIdentifier("climb.attempts")
                    SecondaryButton(store.climb?.isArchived == true ? "Unarchive \(noun)" : "Archive \(noun)") {
                        toggleArchive()
                    }
                    .accessibilityIdentifier("climb.archive")
                    Button("Delete \(noun)", role: .destructive) {
                        confirmDelete = true
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("climb.delete")
                }
            }
        }
        .accessibilityIdentifier("climb.screen")
        .navigationTitle(store.isNew ? "New \(noun)" : noun.capitalized)
        .onAppear {
            if !store.isNew {
                photoStore.load(climbId: climbId)
                store.refreshHolds()
            }
        }
        .confirmationDialog(
            "Delete this \(noun)?",
            isPresented: $confirmDelete
        ) {
            Button("Delete \(noun)", role: .destructive) {
                deleteClimb()
            }
            .accessibilityIdentifier("climb.delete.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only works when it has no attempts. Otherwise archive it.")
        }
        .confirmationDialog(
            photoStore.photo == nil ? "Add wall photo" : "Replace wall photo",
            isPresented: $showPhotoSourceDialog,
            titleVisibility: .visible
        ) {
            if camera.isAvailable {
                Button("Take photo") {
                    camera.present()
                }
                .accessibilityIdentifier("climb.photo.camera")
            }
            Button("Choose from library") {
                showLibrarySheet = true
            }
            .accessibilityIdentifier("climb.photo.library")
            #if DEVELOPMENT
            Button("Add synthetic photo") {
                ingestSyntheticPhoto()
            }
            .accessibilityIdentifier("climb.photo.synthetic")
            #endif
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Photos are stored on this device and never uploaded.")
        }
        .fullScreenCover(isPresented: $camera.isPresenting) {
            CameraCaptureView(
                onCapture: { bytes in
                    ingest(bytes: bytes, source: .camera)
                },
                onCancel: {
                    camera.dismiss()
                },
                onFail: { message in
                    camera.dismiss()
                    photoIngestError = message
                }
            )
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showLibrarySheet) {
            PhotoImportSheet { bytes in
                ingest(bytes: bytes, source: .library)
            }
        }
        .confirmationDialog(
            "Delete this wall photo?",
            isPresented: $confirmPhotoDelete,
            titleVisibility: .visible
        ) {
            Button("Delete photo", role: .destructive) {
                deletePhoto()
            }
            .accessibilityIdentifier("climb.photo.delete.confirm")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(photoDeleteMessage)
        }
    }

    // MARK: - Photo section (M3)

    @ViewBuilder
    private var photoSection: some View {
        SectionTitle("Photo")
        if let photo = photoStore.photo {
            Card {
                HStack(spacing: 12) {
                    AsyncImage(url: thumbnailURL(of: photo)) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "photo")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(photoSourceTitle(photo.source))
                            .font(.subheadline)
                            .foregroundStyle(Theme.primaryText)
                            .accessibilityIdentifier("climb.photo.source")
                        Text("\(photo.width) by \(photo.height) pixels")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryText)
                            .accessibilityIdentifier("climb.photo.dimensions")
                    }
                    Spacer(minLength: 8)
                }
                if photoStore.replaceWarnsHolds, store.holdCount > 0 {
                    ErrorNote("This climb has \(holdCountText). Their positions were tuned to the old photo, so review them on the new image before tagging again.")
                        .accessibilityIdentifier("climb.photo.replace-warning")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("climb.photo.card")

            NavigationLink(value: LogbookRoute.tagging(climbId: climbId)) {
                Row(title: "Tag holds", systemImage: "hand.tap")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("climb.photo.tag")

            SecondaryButton("Replace photo") {
                showPhotoSourceDialog = true
            }
            .accessibilityIdentifier("climb.photo.replace")

            Button("Delete photo", role: .destructive) {
                confirmPhotoDelete = true
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("climb.photo.delete")
        } else {
            Card {
                EmptyState(
                    systemImage: "camera",
                    title: "Add wall photo",
                    message: "Photograph the wall to place and tag holds on it."
                )
            }
            .accessibilityIdentifier("climb.photo.empty")
            PrimaryButton("Add wall photo") {
                showPhotoSourceDialog = true
            }
            .accessibilityIdentifier("climb.photo.add")
        }
        if cameraDisabled {
            cameraNotice
        }
    }

    /// The denied or restricted disabled state: never a re-prompt loop, only the
    /// Settings deep link (docs/decisions.md M3 photo capture record).
    private var cameraDisabled: Bool {
        camera.isAvailable && (camera.authorization == .denied || camera.authorization == .restricted)
    }

    private var cameraNotice: some View {
        Card {
            Text("Camera access is off. Turn it on in Settings to photograph walls.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier("climb.photo.camera-denied")
            SecondaryButton("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .accessibilityIdentifier("climb.photo.open-settings")
        }
    }

    // MARK: - Holds section (M3)

    @ViewBuilder
    private var holdsSection: some View {
        SectionTitle("Holds")
        Card {
            Text(store.holdCount == 0 ? "No holds yet" : "\(holdCountText) tagged")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier("climb.holds.count")
            if !store.roleBreakdown.isEmpty {
                Text(store.roleBreakdown)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("climb.holds.breakdown")
            }
            NavigationLink(value: LogbookRoute.tagging(climbId: climbId)) {
                Row(title: "Tag holds", detail: holdCountText, systemImage: "hand.tap")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("climb.holds.manage")
        }
        .accessibilityIdentifier("climb.holds.card")
    }

    private var holdCountText: String {
        store.holdCount == 1 ? "1 hold" : "\(store.holdCount) holds"
    }

    private var photoDeleteMessage: String {
        if store.holdCount > 0 {
            return "The photo and its stored copies are removed. This climb has \(holdCountText) whose positions reference the photo, so retag on the next image. This cannot be undone."
        }
        return "The photo and its stored copies are removed. This cannot be undone."
    }

    private func thumbnailURL(of photo: Photo) -> URL? {
        let uri = photo.thumbUri ?? photo.uri
        return try? services.media.storage.url(relativeURI: uri)
    }

    private func photoSourceTitle(_ source: PhotoSource) -> String {
        switch source {
        case .camera: return "Camera photo"
        case .library: return "Library photo"
        }
    }

    // MARK: - Photo actions

    /// Ingests picked or captured bytes through the one PhotoStore path (add for a
    /// climb without a photo, replace over the existing one). Ingest failures surface
    /// as plain messages and write nothing (PhotoIngest rolls back partial files).
    private func ingest(bytes: Data, source: PhotoSource) {
        photoIngestError = nil
        Task {
            do {
                if photoStore.photo == nil {
                    try await photoStore.addPhoto(bytes: bytes, source: source, climbId: climbId)
                } else {
                    try await photoStore.replacePhoto(bytes: bytes, source: source)
                }
                store.refreshHolds()
                logbook.refresh()
            } catch {
                photoIngestError = (error as? DomainValidationError)?.message ?? error.localizedDescription
            }
        }
    }

    /// Development only synthetic capture: a deterministic wall JPEG through the same
    /// ingest path (XCUITest reaches it via the "-CYBERSEND_UI_TEST_SEED" launch family).
    private func ingestSyntheticPhoto() {
        #if DEVELOPMENT
        guard let bytes = SyntheticPhotoSource.wallJPEG() else {
            photoIngestError = "The synthetic photo could not be generated."
            return
        }
        ingest(bytes: bytes, source: .library)
        #endif
    }

    private func deletePhoto() {
        do {
            try photoStore.deletePhoto()
            store.refreshHolds()
            logbook.refresh()
        } catch {
            photoIngestError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    // MARK: - Climb actions

    private func save() {
        do {
            let stored = try store.save(gymId: gymId ?? logbook.selectedGymId)
            actionError = nil
            onSaved?(stored)
            logbook.refresh()
            if store.isNew, keepsOpenAfterCreate {
                store.reloadAfterCreate(climbId: stored.id)
            } else {
                dismiss()
            }
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func toggleArchive() {
        do {
            try store.setArchived(store.climb?.isArchived != true)
            actionError = nil
            logbook.refresh()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }

    private func deleteClimb() {
        do {
            try store.delete()
            actionError = nil
            logbook.refresh()
            dismiss()
        } catch {
            actionError = (error as? DomainValidationError)?.message ?? error.localizedDescription
        }
    }
}
