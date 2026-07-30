import Foundation

/// Garante uma única instância por perfil via `flock` num arquivo de lock.
/// Produção e desenvolvimento usam arquivos distintos; o kernel libera o lock
/// sozinho quando o processo morre (mesmo com kill -9).
final class SingleInstanceLock {
    private var fd: Int32 = -1
    private let profilePath: String

    init(
        profile: AppRuntimeProfile = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        profilePath = AppPaths.instanceLockPath(profile: profile, home: home)
    }

    static var defaultPath: String {
        AppPaths.instanceLockPath()
    }

    /// `true` somente quando este processo obteve o lock. Outra instância ou
    /// falha de I/O retornam `false`: disparar tarefas duas vezes é mais perigoso
    /// do que impedir o launch e pedir que o usuário corrija o ambiente.
    func acquire(path: String? = nil) -> Bool {
        let path = path ?? profilePath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let handle = open(path, O_CREAT | O_RDWR, 0o644)
        guard handle >= 0 else { return false }
        guard flock(handle, LOCK_EX | LOCK_NB) == 0 else {
            close(handle)
            return false
        }
        fd = handle // mantém o descritor aberto pela vida do processo
        return true
    }

    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}
