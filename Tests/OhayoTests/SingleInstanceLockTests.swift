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
}
