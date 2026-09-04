import SwiftUI
struct SimulationProgressView: View {
    @ObservedObject var modeManager: JoystickModeManager
    @ObservedObject var healthCoordinator: HealthWalkingCoordinator
    let route: SimulationRoute
    @Binding var speed: Double
    let onStop: () -> Void

    private var previousIndex: Int { max(modeManager.currentRouteIndex - 1, 0) }
    private var nextIndex: Int { min(modeManager.currentRouteIndex + 1, route.points.count - 1) }

    private var modeSummary: String {
        let planning = modeManager.routePlanningMode == .orbitEachWaypoint
            ? "跳點繞圈(\(modeManager.orbitRadiusMeters)m)"
            : "直線路徑"
        let completion = modeManager.completionMode.title
        return "\(planning) · \(completion)"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.name)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text("第 \(modeManager.currentRouteIndex + 1) / \(route.points.count) 點 · \(statusText)")
                        .font(.caption)
                        .foregroundStyle(modeManager.isPaused ? .orange : .secondary)
                    Text(modeSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ProgressView(value: modeManager.simulationProgress)
                .tint(.blue)

            HStack {
                Label("累計 \(healthCoordinator.pendingSteps)", systemImage: "figure.walk")
                Spacer()
                Text("剩餘 \(healthCoordinator.remainingSteps) 步")
            }
            .font(.caption.monospacedDigit())

            HStack(spacing: 10) {
                Button {
                    modeManager.jumpToPoint(index: previousIndex)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(modeManager.currentRouteIndex == 0)

                Button {
                    if modeManager.isPaused {
                        modeManager.resumePathSimulation(speed: speed)
                    } else {
                        modeManager.pausePathSimulation()
                    }
                } label: {
                    Image(systemName: modeManager.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(modeManager.isRouteCompleted)

                Button {
                    modeManager.jumpToPoint(index: nextIndex)
                } label: {
                    Image(systemName: "forward.end.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(modeManager.currentRouteIndex >= route.points.count - 1)

                Button(role: .destructive, action: onStop) {
                    Image(systemName: "stop.fill")
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var statusText: String {
        if modeManager.isRouteCompleted { return "已達終點" }
        return modeManager.isPaused ? "已暫停" : "模擬中"
    }
}
