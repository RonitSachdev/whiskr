import Testing
import simd
@testable import MeadowScene

/// Several bindings in one `static let` once came out shifted; each of these must be what it says.
@Test func staticTablesHoldWhatTheySay() {
    #expect(VillageDrawer.globeLit == linear(0xffd66b))
    #expect(VillageDrawer.globeDark == linear(0xd9d9d4))
    #expect(VillageDrawer.globeRed == linear(0xef6a5f))
    #expect(Flora.stones[1].shape.count == Flora.stone(1).shape.count)
    #expect(Flora.lupins[0].shape.count == Flora.lupin(0).shape.count)
    #expect(Flora.mushrooms[1].shape.count == Flora.mushroom(1).shape.count)
}
