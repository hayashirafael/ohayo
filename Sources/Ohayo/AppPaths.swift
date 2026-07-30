import Foundation

enum AppPaths {
    static func supportDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Ohayo")
    }

    static func instanceLockPath(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        supportDirectory(home: home).appendingPathComponent("instance.lock").path
    }

    static func workspaceDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        supportDirectory(home: home).appendingPathComponent("workspace")
    }

    static func responsesDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Documents/Ohayo")
    }
}
