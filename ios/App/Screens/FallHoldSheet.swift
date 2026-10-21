import CyberSendDomain
import CyberSendFeatures
import SwiftUI
import UIKit

// Fall hold prompt (US-12.3, US-21, M3 upgrade): lists the climb's REAL holds from
// climb_holds with role and ordinal labels, one tap per row saves, and Skip stays the
// no hold path, so the quick log budget of 4 taps survives (docs/architecture.md M3
// navigation: "FallHoldSheet lists real holds and can show the climb photo canvas; hold
// row tap or Skip stays one tap"). When the climb has a photo, "Show on photo" opens the
// read-only tagging canvas in selection mode: tapping a hold saves fall_on_hold_id in
// still one tap, and Clear (or Skip) saves without a hold. Holds outside the climb's set
// never appear: the list and the canvas both render exactly store.climbHolds[climbId].

struct FallHoldSheet: View {
    let climbTitle: String
    let climbId: String
    let outcome: AttemptOutcome
    let holds: [Hold]
    let services: AppServices
    let onSelect: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var photoStore: PhotoStore
    @State private var canvasImage: CGImage?
    @State private var showOnPhoto = false

    init(
        climbTitle: String,
        climbId: String,
        outcome: AttemptOutcome,
        holds: [Hold],
        services: AppServices,
        onSelect: @escaping (String?) -> Void
    ) {
        self.climbTitle = climbTitle
        self.climbId = climbId
        self.outcome = outcome
        self.holds = holds
        self.services = services
        self.onSelect = onSelect
        _photoStore = StateObject(wrappedValue: PhotoStore(
            repos: services.repos,
            storage: services.media.storage
        ))
    }

    var body: some View {
        NavigationStack {
            Screen {
                SectionTitle("Where did you fall?")
                Card {
                    Text("\(climbTitle): \(DisplayText.outcomeTitle(outcome))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                if holds.isEmpty {
                    Card {
                        EmptyState(
                            systemImage: "hand.tap",
                            title: "No tagged holds yet",
                            message: "Tag holds on the climb photo to record exactly where you fell."
                        )
                    }
                    .accessibilityIdentifier("fall.sheet.empty")
                } else if showOnPhoto, let image = canvasImage {
                    photoCanvas(image: image)
                } else {
                    holdsList
                    if photoStore.photo != nil {
                        SecondaryButton("Show on photo") {
                            showOnPhoto = true
                        }
                        .accessibilityIdentifier("fall.show-on-photo")
                    }
                }
                SecondaryButton("Skip fall hold") {
                    select(nil)
                }
                .accessibilityIdentifier("fall.sheet.skip")
            }
            .accessibilityIdentifier("fall.sheet")
            .navigationTitle("Fall hold")
        }
        .onAppear {
            photoStore.load(climbId: climbId)
            loadCanvasImage()
        }
    }

    // MARK: - Hold rows (one tap saves, the 4 tap budget path)

    private var holdsList: some View {
        Card {
            ForEach(Array(holds.enumerated()), id: \.element.id) { index, hold in
                Button {
                    select(hold.id)
                } label: {
                    Row(title: TaggingText.holdTitle(index: index, hold: hold))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("fall.hold.\(index)")
                .accessibilityLabel(TaggingText.holdTitle(index: index, hold: hold))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fall.holds.card")
    }

    // MARK: - Photo canvas (selection mode, one tap saves)

    private func photoCanvas(image: CGImage) -> some View {
        VStack(spacing: 10) {
            if let photo = photoStore.photo {
                Text(TaggingText.dimensions(width: photo.width, height: photo.height))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityIdentifier("fall.photo.dimensions")
            }
            TaggingCanvasView(
                identifier: "fall.canvas",
                image: image,
                holds: holds,
                selectedHoldId: nil,
                isReadOnly: true,
                showsFPSMeter: false,
                onPlaceHold: { _ in },
                onSelectHold: { id in
                    if let id {
                        select(id)
                    }
                },
                onMoveHold: { _, _ in },
                onRequestDeleteHold: { _ in }
            )
            .frame(maxWidth: .infinity, minHeight: 320, maxHeight: 460)
            SecondaryButton("Clear fall hold") {
                select(nil)
            }
            .accessibilityIdentifier("fall.clear")
        }
    }

    // MARK: - Actions

    private func select(_ holdId: String?) {
        onSelect(holdId)
        dismiss()
    }

    /// The same cached, off main decode the tagging screen uses (WorkingImageCache).
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
}
