import Foundation
import XCTest
@testable import Ohayo

final class CodexPluginInventoryCacheTests: XCTestCase {
    func testResultadoNilSubstituiInventarioAnteriorPorIndisponivel() {
        var cache = CodexPluginInventoryCache()
        let accountKey = "/tmp/codex-account"
        let staleInventory = Data(
            #"{"installed":[{"name":"plugin-antigo"}]}"#.utf8
        )

        XCTAssertEqual(
            cache.queryState(for: accountKey),
            .notQueried
        )
        cache.replaceQueryResult(
            staleInventory,
            for: accountKey
        )
        XCTAssertEqual(
            cache.queryState(for: accountKey),
            .loaded(staleInventory)
        )

        cache.replaceQueryResult(nil, for: accountKey)

        let unavailable = cache.queryState(for: accountKey)
        XCTAssertEqual(unavailable, .unavailable)
        XCTAssertNil(
            unavailable.inventory,
            "falha nova não pode reutilizar plugins do snapshot anterior"
        )
        XCTAssertTrue(unavailable.preservesPersistedSelection)
    }

    func testInventarioValidoVazioEhCarregadoEAutoritativo() {
        var cache = CodexPluginInventoryCache()
        let accountKey = "/tmp/codex-account"
        let emptyInventory = Data(#"{"installed":[]}"#.utf8)

        cache.replaceQueryResult(
            emptyInventory,
            for: accountKey
        )

        let state = cache.queryState(for: accountKey)
        XCTAssertEqual(state, .loaded(emptyInventory))
        XCTAssertEqual(state.inventory, emptyInventory)
        XCTAssertFalse(state.preservesPersistedSelection)
    }
}
