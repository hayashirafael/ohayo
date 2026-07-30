import XCTest
@testable import Ohayo

final class SingleInstanceLockTests: XCTestCase {
    private func tempLockPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-lock-\(UUID().uuidString)/instance.lock").path
    }

    func testPrimeiraInstanciaAdquireOLock() {
        let path = tempLockPath()
        let lock = SingleInstanceLock()
        defer { lock.release(); try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(lock.acquire(path: path))
    }

    func testSegundaInstanciaNaoAdquireEnquantoAPrimeiraVive() {
        let path = tempLockPath()
        let primeira = SingleInstanceLock()
        let segunda = SingleInstanceLock()
        defer { primeira.release(); try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(primeira.acquire(path: path))
        XCTAssertFalse(segunda.acquire(path: path))
    }

    func testLockLiberadoPodeSerAdquiridoDeNovo() {
        let path = tempLockPath()
        let primeira = SingleInstanceLock()
        let segunda = SingleInstanceLock()
        defer { segunda.release(); try? FileManager.default.removeItem(atPath: path) }
        XCTAssertTrue(primeira.acquire(path: path))
        primeira.release()
        XCTAssertTrue(segunda.acquire(path: path))
    }

    func testFalhaDeIOFalhaFechadoParaNaoPermitirDisparosDuplicados() {
        let lock = SingleInstanceLock()
        XCTAssertFalse(lock.acquire(path: "/dev/null/ohayo-instance.lock"))
    }

    func testProducaoEDesenvolvimentoPodemCoexistir() {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-profile-lock-\(UUID().uuidString)")
        let production = SingleInstanceLock(profile: .production, home: home)
        let development = SingleInstanceLock(profile: .development, home: home)
        defer {
            production.release()
            development.release()
            try? FileManager.default.removeItem(at: home)
        }

        XCTAssertTrue(production.acquire())
        XCTAssertTrue(development.acquire())
    }

    func testMesmoPerfilDeProducaoRecusaSegundaInstancia() {
        assertSecondInstanceIsRefused(profile: .production)
    }

    func testMesmoPerfilDeDesenvolvimentoRecusaSegundaInstancia() {
        assertSecondInstanceIsRefused(profile: .development)
    }

    private func assertSecondInstanceIsRefused(
        profile: AppRuntimeProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ohayo-profile-lock-\(UUID().uuidString)")
        let first = SingleInstanceLock(profile: profile, home: home)
        let second = SingleInstanceLock(profile: profile, home: home)
        defer {
            first.release()
            second.release()
            try? FileManager.default.removeItem(at: home)
        }

        XCTAssertTrue(first.acquire(), file: file, line: line)
        XCTAssertFalse(second.acquire(), file: file, line: line)
    }
}
