import Foundation
import Testing
@testable import TerminalHost

@Suite("Output read in one go goes on as few pieces as keep its order")
struct OutputBatchTests {
    let one = UUID(), two = UUID()

    @Test func piecesOfOneTerminalBecomeOne() {
        var batch = OutputBatch()
        #expect(batch.add(Data("ab".utf8), for: one) == nil)
        #expect(batch.add(Data("cd".utf8), for: one) == nil)
        let out = batch.take()
        #expect(out?.0 == one)
        #expect(out?.1 == Data("abcd".utf8))
        #expect(batch.isEmpty)
        #expect(batch.take() == nil)
    }

    @Test func anotherTerminalSendsWhatCameBeforeFirst() {
        var batch = OutputBatch()
        _ = batch.add(Data("a".utf8), for: one)
        let first = batch.add(Data("b".utf8), for: two)
        #expect(first?.0 == one)
        #expect(first?.1 == Data("a".utf8))
        #expect(batch.take()?.1 == Data("b".utf8))
    }

    @Test func noPieceGrowsPastTheLimit() {
        var batch = OutputBatch(limit: 4)
        #expect(batch.add(Data("abc".utf8), for: one) == nil)
        let full = batch.add(Data("de".utf8), for: one)
        #expect(full?.1 == Data("abc".utf8))
        #expect(batch.take()?.1 == Data("de".utf8))
    }

    @Test func aLonePieceGoesAsItIs() {
        var batch = OutputBatch()
        #expect(batch.add(Data(), for: one) == nil)
        #expect(batch.isEmpty)
        _ = batch.add(Data("x".utf8), for: one)
        #expect(batch.take()?.1 == Data("x".utf8))
    }
}
