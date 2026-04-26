# TaiChi Desk: 极客窗口管理引擎 (V2.0 沉浸版)

## 1. 视觉架构 (Visual Architecture)
* **形态**：微沉浸式能量球 (Rising Orb)。圆心略高于屏幕底边，展现约 240° 的圆体（约占整体 75%），兼顾美感与充足的点击面积。
* **质感**：
    * **核心 (Core)**：Siri 风格流体能量体，无固定边界，通过高斯模糊实现阴阳融合。
    * **底座 (Base)**：系统级 `ultraThinMaterial` 毛玻璃，带有极浅的内发光描边。
* **动态**：内部能量团采用双重异步动画（整体自转 + 能量团呼吸缩放），模拟生命律动。

## 2. 空间布局与维度映射
基于 240° 的可见弧度，通过纯数学算法将其**绝对均分为三个 80° 扇区**，逻辑如下：

* **核心区 (Radius < 45pt)**：隐藏窗口暂存区 (Hidden Stash) —— 全局隐藏窗口维度。
* **右扇区 (0° - 80°) **：预设路径 (Preset Paths) —— 快捷入口。
* **中扇区 (80° - 160°)**：调度中心 (Mission Control) —— 呼出系统当前桌面概览。
* **左扇区 (160° - 240°)**：访达窗口 (Finder Windows) —— 读取当前开启的 Finder 路径。

## 3. 核心算法实现 (Swift)

### A. 极坐标标准化判定 (Angle Normalization)
利用角度偏移量算法，将点击坐标相对于圆心的角度映射到一个标准的 0-240° 空间内，实现完美的 3 等分盲操判定，彻底无视屏幕边缘物理裁剪的干扰。

```swift
// 定义四个维度状态
enum HubDimension: String {
    case missionControl = "调度中心"
    case hiddenWindows  = "隐藏窗口"
    case finderWindows  = "访达窗口"
    case presetPaths    = "预设路径"
}

func resolveDimension(at location: CGPoint, hubSize: CGFloat) -> HubDimension {
    // 1. 圆心位于完整 UI 组件的中心点
    let center = CGPoint(x: hubSize / 2, y: hubSize / 2) 
    let dx = location.x - center.x
    // 反转 Y 轴，让向上方向为正
    let dy = center.y - location.y 
    
    // 2. 命中核心区
    let distance = sqrt(dx*dx + dy*dy)
    if distance < 45 { 
        return .hiddenWindows 
    } 
    
    // 3. 计算基础角度并标准化
    let startAngle = -30.0 // 假设向两边各多露出 30度，总可见跨度 240度
    let sectorSize = 240.0 / 3.0 // 80度均分
    
    var angle = atan2(dy, dx) * 180 / .pi - startAngle
    while angle < 0 { angle += 360 }
    
    // 4. 无比清爽的判定逻辑
    if angle < sectorSize { 
        return .presetPaths 
    }
    if angle < sectorSize * 2 { 
        return .missionControl 
    }
    if angle < sectorSize * 3 { 
        return .finderWindows 
    }
    
    // 大于 240° 的部分被屏幕物理裁剪，默认保底
    return .hiddenWindows 
}
```

### B. 流体能量核心绘制 (Fluid Core UI)
利用 SwiftUI 的 `ZStack` 层叠与 `blur` 滤镜，伪造出没有明确边界的能量流转视觉。

```swift
import SwiftUI

struct FluidCoreView: View {
    @State private var autoRotation: Double = 0
    @State private var breathingScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // 能量团 A (阳)
            Circle()
                .fill(Color.cyan.opacity(0.5))
                .blur(radius: 20)
                .offset(x: -15, y: -15)
                .scaleEffect(breathingScale)
            
            // 能量团 B (阴)
            Circle()
                .fill(Color.purple.opacity(0.4))
                .blur(radius: 20)
                .offset(x: 15, y: 15)
                .scaleEffect(2.0 - breathingScale)
        }
        .rotationEffect(.degrees(autoRotation))
        .mask(Circle()) // 约束在圆内，防止模糊溢出过多
        .onAppear {
            withAnimation(.linear(duration: 8.0).repeatForever(autoreverses: false)) {
                autoRotation = 360
            }
            withAnimation(.easeInOut(duration: 3.5).repeatForever(autoreverses: true)) {
                breathingScale = 1.3
            }
        }
    }
}
```

## 4. 极致盲操与交互特性

* **物理墙效应 (Fitts's Law)**：由于左右扇区（访达/预设路径）完美延伸至屏幕底角，鼠标只需快速甩至左下角或右下角尽头并点击，即可百分之百精准触发对应维度，无需任何视觉对焦。
* **深砸回源**：将鼠标用力砸向屏幕最底部的中心并点击，即可稳定触发圆心区域的“隐藏窗口”，形成极强的肌肉记忆。
* **滚轮震荡**：在任何非核心扇区滚动鼠标滚轮，将实时循环切换当前维度的窗口列表，后续可结合 `CoreHaptics` (如果是触控板) 或 UI 上的轻微形变，提供转轴拨动的物理反馈。