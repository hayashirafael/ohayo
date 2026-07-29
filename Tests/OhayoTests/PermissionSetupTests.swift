import UserNotifications
import XCTest
@testable import Ohayo

final class PermissionSetupTests: XCTestCase {
    func testUnbundledNotificationClientDoesNotResolveNotificationCenter() async {
        var centerResolutionCount = 0
        let client = SystemNotificationPermissionClient(
            isBundled: false,
            center: {
                centerResolutionCount += 1
                return .current()
            })

        let status = await client.status()
        let requestStatus = await client.request()

        XCTAssertEqual(status, .unavailable)
        XCTAssertEqual(requestStatus, .unavailable)
        XCTAssertEqual(centerResolutionCount, 0)
    }

    func testNotificationRequestAvailability() {
        XCTAssertFalse(PermissionAccessStatus.allowed.allowsRequest)
        XCTAssertFalse(PermissionAccessStatus.unavailable.allowsRequest)
        XCTAssertTrue(PermissionAccessStatus.notConfigured.allowsRequest)
        XCTAssertFalse(PermissionAccessStatus.denied.allowsRequest)
        XCTAssertTrue(PermissionAccessStatus.failed("temporary").allowsRequest)
    }

    func testNotificationAuthorizationMapping() {
        XCTAssertEqual(SystemNotificationPermissionClient.map(.notDetermined), .notConfigured)
        XCTAssertEqual(SystemNotificationPermissionClient.map(.denied), .denied)
        XCTAssertEqual(SystemNotificationPermissionClient.map(.authorized), .allowed)
        XCTAssertEqual(SystemNotificationPermissionClient.map(.provisional), .allowed)
#if !os(macOS)
        XCTAssertEqual(SystemNotificationPermissionClient.map(.ephemeral), .allowed)
#endif
    }

    func testNotificationDeliveryPolicyOnlyAllowsAuthorizedStates() {
        XCTAssertTrue(SystemNotifier.canDeliver(authorizationStatus: .authorized))
        XCTAssertTrue(SystemNotifier.canDeliver(authorizationStatus: .provisional))
        XCTAssertFalse(SystemNotifier.canDeliver(authorizationStatus: .notDetermined))
        XCTAssertFalse(SystemNotifier.canDeliver(authorizationStatus: .denied))
    }

    func testTerminalAutomationSuccessIsAllowed() async {
        let client = SystemTerminalAutomationClient { _ in .success(()) }
        let status = await client.test()
        XCTAssertEqual(status, .allowed)
    }

    func testTerminalAutomationDenialIsDenied() async {
        let client = SystemTerminalAutomationClient { _ in
            .failure(.appleEventNotPermitted)
        }
        let status = await client.test()
        XCTAssertEqual(status, .denied)
    }

    func testTerminalAutomationOtherFailureIsReported() async {
        let client = SystemTerminalAutomationClient { _ in
            .failure(.executionFailed("Terminal unavailable"))
        }
        let status = await client.test()
        XCTAssertEqual(status, .failed("Terminal unavailable"))
    }

    func testTerminalProbeIsReadOnly() {
        XCTAssertEqual(
            SystemTerminalAutomationClient.probeScript,
            "tell application \"Terminal\" to get name"
        )
    }

    func testDeniedPermissionsLinkToTheMatchingSystemSettingsPane() {
        XCTAssertEqual(
            PermissionSettingsDestination.notifications.url.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
        XCTAssertEqual(
            PermissionSettingsDestination.terminalAutomation.url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        )
    }

    @MainActor
    func testLoginItemManagerForwardsInjectedOperations() {
        var enabled = false
        let manager = ClosureLoginItemManager(
            isSupported: true,
            getEnabled: { enabled },
            setEnabled: { enabled = $0 }
        )

        XCTAssertTrue(manager.isSupported)
        XCTAssertFalse(manager.isEnabled)
        manager.setEnabled(true)
        XCTAssertTrue(manager.isEnabled)
    }

    @MainActor
    func testModelRefreshDoesNotRequestPermissions() async {
        let notifications = NotificationFake(.notConfigured)
        let terminal = TerminalFake(.allowed)
        let login = ClosureLoginItemManager(
            isSupported: true, getEnabled: { false }, setEnabled: { _ in })
        let model = PermissionSetupModel(
            notifications: notifications, terminal: terminal, loginItem: login)

        await model.refresh()

        XCTAssertEqual(model.notificationStatus, .notConfigured)
        XCTAssertEqual(model.terminalStatus, .notConfigured)
        let requestCount = await notifications.requestCount
        let testCount = await terminal.testCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(testCount, 0)
    }

    @MainActor
    func testNotificationActionRequestsAndRefreshesStatus() async {
        let notifications = NotificationFake(.notConfigured)
        let model = PermissionSetupModel(
            notifications: notifications,
            terminal: TerminalFake(.notConfigured),
            loginItem: ClosureLoginItemManager(
                isSupported: false, getEnabled: { false }, setEnabled: { _ in }))

        await model.requestNotifications()

        XCTAssertEqual(model.notificationStatus, .allowed)
        let requestCount = await notifications.requestCount
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testDeniedNotificationDoesNotRequestAgain() async {
        let notifications = NotificationFake(.denied)
        let model = PermissionSetupModel(
            notifications: notifications,
            terminal: TerminalFake(.notConfigured),
            loginItem: ClosureLoginItemManager(
                isSupported: false, getEnabled: { false }, setEnabled: { _ in }))

        await model.refresh()
        await model.requestNotifications()

        XCTAssertEqual(model.notificationStatus, .denied)
        let requestCount = await notifications.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testTerminalActionOnlyRunsWhenExplicitlyCalled() async {
        let terminal = TerminalFake(.denied)
        let model = PermissionSetupModel(
            notifications: NotificationFake(.notConfigured),
            terminal: terminal,
            loginItem: ClosureLoginItemManager(
                isSupported: false, getEnabled: { false }, setEnabled: { _ in }))

        let initialTestCount = await terminal.testCount
        XCTAssertEqual(initialTestCount, 0)
        await model.testTerminal()

        XCTAssertEqual(model.terminalStatus, .denied)
        let testCount = await terminal.testCount
        XCTAssertEqual(testCount, 1)
    }

    @MainActor
    func testDeniedTerminalDoesNotTryAutomationAgain() async {
        let terminal = TerminalFake(.denied)
        let model = PermissionSetupModel(
            notifications: NotificationFake(.notConfigured),
            terminal: terminal,
            loginItem: ClosureLoginItemManager(
                isSupported: false, getEnabled: { false }, setEnabled: { _ in }))

        await model.testTerminal()
        await model.testTerminal()

        XCTAssertEqual(model.terminalStatus, .denied)
        let testCount = await terminal.testCount
        XCTAssertEqual(testCount, 1)
    }

    @MainActor
    func testModelOpensSystemSettingsThroughInjectedClient() {
        let settings = SettingsFake()
        let model = PermissionSetupModel(
            notifications: NotificationFake(.denied),
            terminal: TerminalFake(.denied),
            loginItem: ClosureLoginItemManager(
                isSupported: false, getEnabled: { false }, setEnabled: { _ in }),
            settings: settings)

        model.openSettings(.notifications)
        model.openSettings(.terminalAutomation)

        XCTAssertEqual(settings.opened, [.notifications, .terminalAutomation])
    }
}

private actor NotificationFake: NotificationPermissionClient {
    var current: PermissionAccessStatus
    private(set) var requestCount = 0

    init(_ current: PermissionAccessStatus) { self.current = current }
    func status() async -> PermissionAccessStatus { current }
    func request() async -> PermissionAccessStatus {
        requestCount += 1
        current = .allowed
        return current
    }
}

private actor TerminalFake: TerminalAutomationClient {
    let result: PermissionAccessStatus
    private(set) var testCount = 0

    init(_ result: PermissionAccessStatus) { self.result = result }
    func test() async -> PermissionAccessStatus {
        testCount += 1
        return result
    }
}

private final class SettingsFake: PermissionSettingsOpening {
    private(set) var opened: [PermissionSettingsDestination] = []
    func open(_ destination: PermissionSettingsDestination) {
        opened.append(destination)
    }
}
