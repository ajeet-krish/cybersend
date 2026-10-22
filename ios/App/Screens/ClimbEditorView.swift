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
                    .themedField()
                    .autocapitalization(.words)
                    .accessibilityIdentifier("climb.name")
            }

            // One details group: everything that describes where and on what the problem
            // is, including the gym, so a problem can be created in or moved to any gym.
            SectionTitle("Details")
            Card {
                detailRow("Gym") {
                    if store.gyms.isEmpty {
                        Text("No gyms yet")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryText)
                    } else {
                        Picker("Gym", selection: $store.gymId) {
                            ForEach(store.gyms) { gym in
                                Text(gym.name).tag(gym.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(Theme.accentSolid)
                        // A menu label otherwise yields its width to the Spacer and wraps a
                        // two word gym name; the intrinsic menu width keeps it on one line.
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityIdentifier("climb.gym")
                    }
                }
                divider
                // Grade stays a menu rather than a chip strip: the scheme list and the V
                // scale level range are long enough that a horizontal strip pushed the
                // level the climber wanted off screen, and a menu is one tap either way.
                detailRow("Grade scheme") {
                    Picker("Grade scheme", selection: Binding(
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
                divider
                detailRow("Level") {
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
                divider
                detailRow("Wall angle") {
                    TextField("Optional, 0 to 90", text: $store.angleText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("climb.angle")
                }
                divider
                detailRow("Colour circuit") {
                    TextField("Optional", text: $store.colorCircuit)
                        .autocapitalization(.words)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("climb.color")
                }
            }

            SectionTitle("Notes")
            Card {
                TextField(
                    "For example: keep the hips close on the top out",
                    text: $store.notes,
                    axis: .vertical
                )
                .lineLimit(2...6)
                .themedField()
                .accessibilityIdentifier("climb.notes")
            }

            SectionTitle("Climb category")
            Card {
                categoryGrid
            }

            // Photo and holds show on the create screen too: picking a photo on a problem
            // that does not exist yet creates it first, then ingests, so the climber can
            // shoot the wall without a separate save.
            photoSection
            holdsSection

            if !store.isNew {
                SectionTitle("Manage")
                Card {
                    // Side by side: two destructive-ish actions stacked cost a full row
                    // each and the attempt count already lives in the problem history.
                    HStack(spacing: 12) {
                        SecondaryButton(store.climb?.isArchived == true ? "Unarchive" : "Archive") {
                            toggleArchive()
                        }
                        .accessibilityIdentifier("climb.archive")
                        Button("Delete", role: .destructive) {
                            confirmDelete = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.separator.opacity(0.25))
                        .foregroundStyle(Theme.danger)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityIdentifier("climb.delete")
                    }
                }
            }

            PrimaryButton(store.isNew ? "Add \(noun)" : "Save changes") {
                save()
            }
            .accessibilityIdentifier("climb.save")
        }
        .accessibilityIdentifier("climb.screen")
        .navigationTitle(store.isNew ? "New \(noun)" : noun.capitalized)
        .onAppear {
            store.ensureGymSelection(fallback: gymId ?? logbook.selectedGymId)
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

    // MARK: - Details and categories

    /// One label plus control row inside the details card, so every field lines up.
    private func detailRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 8)
            content()
        }
    }

    private var divider: some View {
        Divider()
            .overlay(Theme.separator)
    }

    /// The category tags as toggle buttons. Adaptive columns keep the grid two or three
    /// across on a phone without hard coding a count per width.
    private var categoryGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(climbCategories, id: \.self) { category in
                categoryButton(category)
            }
        }
    }

    private func categoryButton(_ category: ClimbCategory) -> some View {
        let selected = store.isSelected(category)
        return Button {
            store.toggleCategory(category)
        } label: {
            Text(category.title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? Theme.accentSolid : Theme.separator.opacity(0.25))
                .foregroundStyle(selected ? Theme.onAccent : Theme.primaryText)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("climb.category.\(category.rawValue)")
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
            // One affordance, not an empty state plus a duplicate button: the whole card
            // opens the photo source dialog.
            Button {
                showPhotoSourceDialog = true
            } label: {
                Card {
                    EmptyState(
                        systemImage: "camera",
                        title: "Add wall photo",
                        message: "Photograph the wall to place and tag holds on it."
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        // Tagging lives here and only here: the photo section used to carry a second Tag
        // holds link, and the card repeated the count that the button detail already says.
        SectionTitle("Holds")
        NavigationLink(value: LogbookRoute.tagging(climbId: climbId)) {
            Card {
                Row(
                    title: "Tag holds",
                    detail: store.isNew ? "Save first" : (store.holdCount == 0 ? "None tagged" : holdCountText),
                    systemImage: "hand.tap"
                )
                // The Row ends in a Spacer, so without a content shape the empty middle of
                // the row is not hittable and a tap in the center of the link does nothing.
                .contentShape(Rectangle())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.isNew)
        .accessibilityIdentifier("climb.holds.manage")
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
                    // A photo on a not yet saved problem creates it first: there is no row
                    // to hang the photo on otherwise.
                    let targetId = try ensureStoredClimb()
                    try await photoStore.addPhoto(bytes: bytes, source: source, climbId: targetId)
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

    /// The climb id to attach media to, creating the climb first when the screen is still in
    /// create mode. Returns the stored row's id and flips the editor into edit mode, so the
    /// photo and holds sections continue to work in place.
    private func ensureStoredClimb() throws -> String {
        if !store.isNew, let climb = store.climb {
            return climb.id
        }
        let stored = try store.save(fallbackGymId: gymId ?? logbook.selectedGymId)
        actionError = nil
        onSaved?(stored)
        logbook.refresh()
        store.reloadAfterCreate(climbId: stored.id)
        return stored.id
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
            let stored = try store.save(fallbackGymId: gymId ?? logbook.selectedGymId)
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
