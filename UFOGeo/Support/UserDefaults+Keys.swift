import Foundation

extension UserDefaults {
    enum Keys {
        static let targetDeviceIP = "TunnelDeviceIP"
        static let primaryTabSelection = "primaryTabSelection"
        static let hasShownInitialPairingPrompt = "hasShownInitialPairingPrompt"
        static let fixedSimulationActive = "fixedSimulationActive"
        static let routeSimulationActive = "routeSimulationActive"
        static let noSimulationBackgroundAt = "noSimulationBackgroundAt"
        static let lastJoystickSpeed = "lastJoystickSpeed"
        static let healthWalkingEnabled = "healthWalkingEnabled"
        static let walkingStepsPerSecond = "walkingStepsPerSecond"
        static let walkingStepResetTarget = "walkingStepResetTarget"
        static let healthStepWriteTarget = "healthStepWriteTarget"
        static let pendingHealthSimulationSteps = "pendingHealthSimulationSteps"
        static let pendingHealthSimulationFraction = "pendingHealthSimulationFraction"
        static let writtenHealthSimulationSteps = "writtenHealthSimulationSteps"
        static let savedHealthSimulationTarget = "savedHealthSimulationTarget"
        static let savedProHealthBatchSize = "savedProHealthBatchSize"
        static let healthSimulationDayIdentifier = "healthSimulationDayIdentifier"
        static let savedSimulationRoutes = "SavedSimulationRoutes"
        static let locationBookmarks = "locationBookmarks"
        static let locationHistoryRecords = "locationHistoryRecords"
        static let lastUpdateCheckDate = "lastUpdateCheckDate"
        // 路線模擬設定
        static let routeCompletionMode = "routeCompletionMode"
        static let routePlanningMode = "routePlanningMode"
        static let routeOrbitRadiusMeters = "routeOrbitRadiusMeters"
    }
}
