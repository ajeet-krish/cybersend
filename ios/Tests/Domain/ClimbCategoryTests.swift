import Testing
@testable import CyberSendDomain

// Climb categories (UI overhaul): a fixed list of descriptive tags, stored comma separated in
// declaration order so the bytes stay deterministic for exports and diffable in the database.

@Suite("Climb categories")
struct ClimbCategoryTests {
    @Test("the fixed list carries the tags the editor offers")
    func fixedList() {
        #expect(climbCategories == ClimbCategory.allCases)
        #expect(climbCategories.contains(.slab))
        #expect(climbCategories.contains(.dyno))
        #expect(climbCategories.contains(.crimpy))
        #expect(climbCategories.contains(.overhang))
        #expect(climbCategories.contains(.campus))
        #expect(climbCategories.contains(.comp))
        #expect(ClimbCategory.slab.title == "Slab")
        #expect(ClimbCategory.comp.title == "Comp")
    }

    @Test("no categories encode to nil, not an empty string")
    func emptyEncodesToNil() {
        #expect(encodeClimbCategories([]) == nil)
    }

    @Test("encoding follows declaration order regardless of pick order")
    func encodingIsDeclarationOrdered() {
        #expect(encodeClimbCategories([.crimpy, .slab]) == "slab,crimpy")
        #expect(encodeClimbCategories([.endurance, .slab, .dyno]) == "slab,dyno,endurance")
    }

    @Test("a round trip preserves the set")
    func roundTrip() {
        let picked: [ClimbCategory] = [.overhang, .slab, .comp]
        let stored = encodeClimbCategories(picked)
        #expect(stored == "slab,overhang,comp")
        #expect(parseClimbCategories(stored) == [.slab, .overhang, .comp])
        #expect(parseClimbCategories(nil) == [])
        #expect(parseClimbCategories("") == [])
    }

    @Test("parsing ignores unknown tokens, whitespace, case, and duplicates")
    func parsingIsTolerant() {
        // A row written by a newer build may carry a token this build does not know, and the
        // column is hand editable, so parsing never fails.
        #expect(parseClimbCategories("slab, moonboard, SLAB, dyno") == [.slab, .dyno])
        #expect(parseClimbCategories("  crimpy  ") == [.crimpy])
        #expect(parseClimbCategories("moonboard") == [])
    }
}
