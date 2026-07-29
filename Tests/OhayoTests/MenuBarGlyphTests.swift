import XCTest
@testable import Ohayo

final class MenuBarGlyphTests: XCTestCase {
    func testFimDeJanelaAtivaIgnoraRetryECooldown() {
        let now = Date(timeIntervalSince1970: 1_783_000_000)
        let scheduledID = UUID()
        let retryID = UUID()
        let cooldownID = UUID()
        let scheduledEnd = now.addingTimeInterval(300)
        let account = URL(fileURLWithPath: "/tmp/menu-bar-account")
        let snapshot = RenewalSnapshot(byTask: [
            scheduledID: RenewalSnapshot.Entry(
                taskID: scheduledID,
                account: account,
                phase: .scheduled(scheduledEnd)
            ),
            retryID: RenewalSnapshot.Entry(
                taskID: retryID,
                account: account.appendingPathComponent("retry"),
                phase: .retry(
                    now.addingTimeInterval(60),
                    attempt: 1,
                    bootstrapOrigin: true
                )
            ),
            cooldownID: RenewalSnapshot.Entry(
                taskID: cooldownID,
                account: account.appendingPathComponent("cooldown"),
                phase: .cooldown(
                    now.addingTimeInterval(120),
                    bootstrapOrigin: true
                )
            ),
        ])

        XCTAssertEqual(
            MenuBarLabelLogic.soonestActiveWindowEnd(
                in: snapshot,
                after: now
            ),
            scheduledEnd
        )
    }

    // Mesma semântica do símbolo antigo: problema > janela ativa > ocioso.
    func testProblemaTemPrioridadeSobreJanelaAtiva() {
        XCTAssertEqual(MenuBarGlyph.State(hasProblem: true, hasActiveWindow: true), .problem)
        XCTAssertEqual(MenuBarGlyph.State(hasProblem: true, hasActiveWindow: false), .problem)
    }

    func testJanelaAtivaSemProblemaEhActive() {
        XCTAssertEqual(MenuBarGlyph.State(hasProblem: false, hasActiveWindow: true), .active)
    }

    func testSemJanelaESemProblemaEhIdle() {
        XCTAssertEqual(MenuBarGlyph.State(hasProblem: false, hasActiveWindow: false), .idle)
    }

    // Template image é o que faz a barra tingir o glifo conforme o tema.
    func testImagensSaoTemplateNoTamanhoDaBarra() {
        for state in MenuBarGlyph.State.allCases {
            let image = MenuBarGlyph.image(for: state)
            XCTAssertTrue(image.isTemplate, "\(state) deveria ser template")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
        }
    }

    func testVariantesDesenhamGlifosDistintos() {
        let tiffs = MenuBarGlyph.State.allCases.map { MenuBarGlyph.image(for: $0).tiffRepresentation }
        for data in tiffs { XCTAssertNotNil(data) }
        XCTAssertNotEqual(tiffs[0], tiffs[1])
        XCTAssertNotEqual(tiffs[0], tiffs[2])
        XCTAssertNotEqual(tiffs[1], tiffs[2])
    }
}
