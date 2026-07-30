import Foundation

enum AppPaths {
    static func supportDirectory(
        profile: AppRuntimeProfile = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(
            "Library/Application Support/\(profile.supportDirectoryName)"
        )
    }

    static func instanceLockPath(
        profile: AppRuntimeProfile = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        supportDirectory(profile: profile, home: home)
            .appendingPathComponent("instance.lock").path
    }

    static func workspaceDirectory(
        profile: AppRuntimeProfile = .current,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL {
        supportDirectory(profile: profile, home: home)
            .appendingPathComponent("workspace")
    }

    static func responsesDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Documents/Ohayo")
    }
}
