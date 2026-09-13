import Testing
@testable import WhiskrKit

@Suite("Title bar")
struct TitleBarTests {
    @Test("a double-click on the bars follows Desktop & Dock's setting, zooming when it was never set")
    func doubleClick() {
        #expect(TitleBarDoubleClick(action: nil, miniaturize: false) == .zoom)
        #expect(TitleBarDoubleClick(action: "Fill", miniaturize: false) == .zoom)
        #expect(TitleBarDoubleClick(action: "Maximize", miniaturize: false) == .zoom)
        #expect(TitleBarDoubleClick(action: "Minimize", miniaturize: false) == .minimize)
        #expect(TitleBarDoubleClick(action: "None", miniaturize: true) == .nothing)
        // The older switch, used only while the newer setting is absent.
        #expect(TitleBarDoubleClick(action: nil, miniaturize: true) == .minimize)
        #expect(TitleBarDoubleClick(action: "Maximize", miniaturize: true) == .zoom)
    }
}
