import SwiftUI

/// 浮動搖桿視圖 - 封裝搖桿、手勢和視覺反饋
struct FloatingJoystickView: View {
    let manager: JoystickManager
    let size: CGFloat
    let layout: AdaptiveLayoutMetrics
    let isSimulating: Bool
    let joystickDirectionLocked: Bool
    let isEnabled: Bool
    
    let onDragChanged: () -> Void
    let onDragEnded: () -> Bool
    let onDoubleTap: () -> Void
    let onLockedTap: () -> Void
    
    var body: some View {
        JoystickComponentView(
            manager: manager,
            size: size,
            knobScale: 0.38,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
        .allowsHitTesting(isEnabled)
        .frame(width: size, height: size)
        .opacity(isEnabled ? (isSimulating ? 1 : 0.65) : 0.42)
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    if joystickDirectionLocked {
                        onDoubleTap()
                    }
                }
        )
        .overlay {
            if !isEnabled {
                Button(action: onLockedTap) {
                    VStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18, weight: .bold))
                        Text("PRO")
                            .font(.caption2.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.black.opacity(0.68), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("浮動搖桿，Pro 功能，尚未解鎖")
                .accessibilityHint("點擊查看 Pro 功能說明")
            } else if joystickDirectionLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .position(manager.position)
                    .allowsHitTesting(false)
                    .accessibilityLabel("方向已鎖定，點擊兩下解除")
            }
        }
        .padding(8)
        .background(.regularMaterial, in: Circle())
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .padding(.trailing, layout.horizontalPadding)
        .padding(.bottom, layout.joystickBottomInset(isSimulationActive: isSimulating))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityLabel(isEnabled ? "浮動搖桿" : "浮動搖桿，Pro 功能")
        .zIndex(45)
    }
}
