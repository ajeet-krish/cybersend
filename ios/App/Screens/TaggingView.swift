import CyberSendDomain
import CyberSendFeatures
import SwiftUI
import UIKit

// Hold tagging screen (M3, US-18 to US-20): the interactive canvas over the climb's
// wall photo with immediate commits through TaggingStore (docs/decisions.md "canvas is
// UIScrollView plus CAShapeLayer"): a tap places a hold, the role bar assigns Start,
// Intermediate, Top, or Unassigned to the selection, Undo and Redo roll back edits, and
// long press on a hold opens the delete confirmation. Every edit writes through the
// store right away, so Done just dismisses and Cancel costs nothing; the bounded undo
// stack covers mistakes (US-19.2). The Holds list sheet gives VoiceOver full CRUD over
// role, position, and delete, and the canvas itself is a single accessibility element
// ("Wall photo with N tagged holds").

struct TaggingView: View {
    let climbId: String
    let services: AppServices

    @Environment(\.dismiss) private var dismiss
    @StateObject private var tagging: TaggingStore
    @StateObject private var photoStore: PhotoStore

    @State private var canvasImage: CGImage?
    @State private var selectedHoldId: String?
    @State private var confirmDeleteHoldId: String?
    @State private var showHoldsList = false

    init(climbId: String, services: AppServices) {
        self.climbId = climbId
        self.services = services
        _tagging = StateObject(wrappedValue: TaggingStore(repos: services.repos))
        _photoStore = StateObject(wrappedValue: PhotoStore(
            repos: services.repos,
            storage: services.media.storage
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let message = tagging.lastErrorMessage ?? photoStore.lastErrorMessage {
                ErrorNote(message)
                    .accessibilityIdentifier("tagging.error")
                    .padding(.horizontal, Theme.screenPadding)
                    .padding(.top, 8)
            }
            canvasArea
            controlBar
        }
        .background(Theme.screenBackground.ignoresSafeArea())
        .navigationTitle("Tag holds")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tagging.screen")
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                undoButton
                redoButton
                doneButton
            }
        }
        .onAppear(perform: load)
        .onChange(of: tagging.holds) { _ in
            reconcileSelection()
        }
        .sheet(isPresented: $showHoldsList) {
            TaggingHoldsListSheet(
                holds: tagging.holds,
                selectedHoldId: selectedHoldId,
                onSelect: { id in
                    selectedHoldId = id
                    showHoldsList = false
                },
                onSetRole: { id, role in
                    try? tagging.setRole(id: id, role: role)
                },
                onDelete: { id in
                    showHoldsList = false
                    confirmDeleteHoldId = id
                }
            )
        }
        .alert("Delete this hold?", isPresented: deleteConfirmBinding) {
            Button("Delete hold", role: .destructive) {
                if let id = confirmDeleteHoldId {
                    try? tagging.deleteHold(id: id)
                }
                confirmDeleteHoldId = nil
            }
            .accessibilityIdentifier("tagging.delete.confirm")
            Button("Cancel", role: .cancel) {
                confirmDeleteHoldId = nil
            }
        } message: {
            Text("The hold is removed from this climb. Undo can bring it back.")
        }
    }

    // MARK: - Canvas area

    @ViewBuilder
    private var canvasArea: some View {
        if let photo = photoStore.photo, let image = canvasImage {
            ZStack(alignment: .bottom) {
                TaggingCanvasView(
                    image: image,
                    holds: tagging.holds,
                    selectedHoldId: selectedHoldId,
                    isReadOnly: false,
                    showsFPSMeter: showsFPSMeter,
                    onPlaceHold: { point in
                        placeHold(at: point)
                    },
                    onSelectHold: { id in
                        selectedHoldId = id
                    },
                    onMoveHold: { id, point in
                        try? tagging.moveHold(id: id, xNorm: point.x, yNorm: point.y)
                    },
                    onRequestDeleteHold: { id in
                        selectedHoldId = id
                        confirmDeleteHoldId = id
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if tagging.holds.isEmpty {
                    Text("Tap the photo to place your first hold")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .accessibilityIdentifier("tagging.empty-hint")
                        .allowsHitTesting(false)
                        .padding(.bottom, 16)
                }
            }
            .accessibilityElement(children: .contain)
            .overlay(alignment: .topTrailing) {
                Text(TaggingText.dimensions(width: photo.width, height: photo.height))
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.cardBackground, in: Capsule())
                    .accessibilityIdentifier("tagging.photo.dimensions")
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
        } else if photoStore.photo != nil {
            ProgressView("Loading photo")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("tagging.loading")
        } else {
            EmptyState(
                systemImage: "camera",
                title: "No wall photo",
                message: "Add a wall photo on the climb editor, then tag its holds here."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("tagging.no-photo")
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                roleButton(.start, title: "Start", identifier: "tagging.role.start")
                roleButton(.intermediate, title: "Inter", identifier: "tagging.role.intermediate")
                roleButton(.top, title: "Top", identifier: "tagging.role.top")
                roleButton(nil, title: "None", identifier: "tagging.role.unassigned")
            }
            HStack(spacing: 8) {
                Button {
                    showHoldsList = true
                } label: {
                    Label("Holds (\(tagging.holds.count))", systemImage: "list.number")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("tagging.holds.list")
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.vertical, 10)
        .background(Theme.cardBackground)
    }

    @ViewBuilder
    private func roleButton(_ role: HoldRole?, title: String, identifier: String) -> some View {
        let selected = isSelectedRole(role)
        Group {
            if selected {
                Button {
                    assignRole(role)
                } label: {
                    Text(title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    assignRole(role)
                } label: {
                    Text(title)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .controlSize(.large)
        .disabled(selectedHoldId == nil)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var undoButton: some View {
        Button {
            try? tagging.undo()
        } label: {
            Image(systemName: "arrow.uturn.backward")
        }
        .disabled(!tagging.canUndo)
        .accessibilityIdentifier("tagging.undo")
        .accessibilityLabel("Undo")
    }

    private var redoButton: some View {
        Button {
            try? tagging.redo()
        } label: {
            Image(systemName: "arrow.uturn.forward")
        }
        .disabled(!tagging.canRedo)
        .accessibilityIdentifier("tagging.redo")
        .accessibilityLabel("Redo")
    }

    private var doneButton: some View {
        Button("Done") {
            dismiss()
        }
        .accessibilityIdentifier("tagging.done")
    }

    // MARK: - State helpers

    private var selectedHold: Hold? {
        tagging.holds.first(where: { $0.id == selectedHoldId })
    }

    private func isSelectedRole(_ role: HoldRole?) -> Bool {
        selectedHold?.role == role && selectedHoldId != nil
    }

    private var deleteConfirmBinding: Binding<Bool> {
        Binding(
            get: { confirmDeleteHoldId != nil },
            set: { if !$0 { confirmDeleteHoldId = nil } }
        )
    }

    /// The DEVELOPMENT only FPS HUD (CanvasFPSMeter.swift): the CADisplayLink meter runs
    /// in dogfooding with "-CYBERSEND_FPS_HUD" and automatically under the 100 hold seed
    /// "-CYBERSEND_UI_TEST_SEED_HOLDS 100". Internal and Release compile it out.
    private var showsFPSMeter: Bool {
        #if DEVELOPMENT
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains(canvasFPSMeterArgument)
            || arguments.contains(uiTestSeedHoldsArgument)
        #else
        return false
        #endif
    }

    // MARK: - Actions

    private func load() {
        tagging.load(climbId: climbId)
        photoStore.load(climbId: climbId)
        loadCanvasImage()
    }

    private func loadCanvasImage() {
        guard
            let photo = photoStore.photo,
            let url = try? services.media.storage.url(relativeURI: photo.uri)
        else {
            canvasImage = nil
            return
        }
        WorkingImageCache.load(url: url) { image in
            canvasImage = image
        }
    }

    private func placeHold(at point: CGPoint) {
        guard let hold = try? tagging.addHold(xNorm: Double(point.x), yNorm: Double(point.y)) else { return }
        selectedHoldId = hold.id
    }

    private func assignRole(_ role: HoldRole?) {
        guard let id = selectedHoldId else { return }
        try? tagging.setRole(id: id, role: role)
    }

    /// Selection never outlives its hold: undo, redo, and delete can remove the selected
    /// hold, and the role bar must not act on a stale id.
    private func reconcileSelection() {
        if let id = selectedHoldId, !tagging.holds.contains(where: { $0.id == id }) {
            selectedHoldId = nil
        }
    }
}

// MARK: - Shared text

/// Stable tagging strings: dimensions for the UI test coordinate math and hold row
/// titles and positions for the accessibility list.
enum TaggingText {
    static func dimensions(width: Int, height: Int) -> String {
        "\(width) by \(height) pixels"
    }

    static func position(_ hold: Hold) -> String {
        String(format: "x %.3f, y %.3f", hold.xNorm, hold.yNorm)
    }

    static func holdTitle(index: Int, hold: Hold) -> String {
        "Hold \(index + 1): \(roleTitle(hold))"
    }

    static func roleTitle(_ hold: Hold) -> String {
        switch hold.role {
        case .start: return "start hold"
        case .intermediate: return "intermediate hold"
        case .top: return "top hold"
        case nil: return "unassigned hold"
        }
    }
}

// MARK: - Holds list sheet

/// The VoiceOver friendly holds list (US-18 accessibility): every hold with its role and
/// position, a role menu for full CRUD without gesture precision, and a delete action
/// behind the screen's confirmation.
struct TaggingHoldsListSheet: View {
    let holds: [Hold]
    let selectedHoldId: String?
    let onSelect: (String) -> Void
    let onSetRole: (String, HoldRole?) -> Void
    let onDelete: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Screen {
                if holds.isEmpty {
                    Card {
                        EmptyState(
                            systemImage: "list.number",
                            title: "No holds yet",
                            message: "Tap the photo to place your first hold."
                        )
                    }
                    .accessibilityIdentifier("tagging.holds.empty")
                } else {
                    Card {
                        ForEach(Array(holds.enumerated()), id: \.element.id) { index, hold in
                            row(index: index, hold: hold)
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tagging.holds.card")
                }
            }
            .accessibilityIdentifier("tagging.holds.sheet")
            .navigationTitle("Holds")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("tagging.holds.done")
                }
            }
        }
    }

    private func row(index: Int, hold: Hold) -> some View {
        HStack(spacing: 10) {
            Button {
                onSelect(hold.id)
            } label: {
                Text(TaggingText.holdTitle(index: index, hold: hold))
                    .font(.subheadline)
                    .foregroundStyle(Theme.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tagging.hold.\(index).select")
            .accessibilityLabel(TaggingText.holdTitle(index: index, hold: hold))
            .accessibilityAddTraits(hold.id == selectedHoldId ? [.isSelected] : [])

            Text(TaggingText.position(hold))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
                .accessibilityIdentifier("tagging.hold.\(index).position")

            roleMenu(index: index, hold: hold)
            Button {
                onDelete(hold.id)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(Theme.warning)
            }
            .accessibilityIdentifier("tagging.hold.\(index).delete")
            .accessibilityLabel("Delete hold \(index + 1)")
        }
        .padding(.vertical, 2)
    }

    private func roleMenu(index: Int, hold: Hold) -> some View {
        Menu {
            Button("Start") { onSetRole(hold.id, .start) }
            Button("Intermediate") { onSetRole(hold.id, .intermediate) }
            Button("Top") { onSetRole(hold.id, .top) }
            Button("Unassigned") { onSetRole(hold.id, nil) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("tagging.hold.\(index).role-menu")
        .accessibilityLabel("Role for \(TaggingText.roleTitle(hold))")
    }
}
