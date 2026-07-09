import SwiftUI
import Cocoa

struct ScrollCatcherView: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollNSView {
        let view = ScrollNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollNSView, context: Context) {}
}

// =========================================================================================
// [BUG FIX: ScrollCatcherView Intercepting Clicks]
// Problem:
// When the number of monitored windows exceeds the maximum visible count (7), a `ScrollCatcherView`
// is instantiated as an `NSViewRepresentable` to capture scroll wheel events for the circular carousel.
// However, by default, an `NSView` intercepts all mouse events (like `mouseDown`) in its bounds 
// (which cover the entire orb), preventing SwiftUI's `onTapGesture` on the sibling application icons
// from receiving clicks. This caused the UI to appear completely "frozen" (unresponsive to clicks).
//
// Method/Logic:
// 1. Overrode `hitTest(_:)` in `ScrollNSView` to return `nil`. This makes the view completely
//    transparent to hit testing, allowing all mouse clicks to fall through to the SwiftUI icons beneath.
// 2. Since returning `nil` in `hitTest` also prevents AppKit from sending `scrollWheel` events
//    to this view, a global/local event monitor (`NSEvent.addLocalMonitorForEvents`) was added to
//    listen for `.scrollWheel`.
// 3. Inside the event monitor, we manually verify if the cursor's coordinates are within the
//    `bounds` of `ScrollNSView` before intercepting and consuming the scroll delta.
//
// Caveats for future development:
// - Do NOT change `hitTest(_:)` to return `self` again without providing a robust way to 
//   forward `mouseDown`/`mouseUp` events through SwiftUI's `NSHostingView`.
// - Ensure the `monitor` is properly cleaned up in `viewDidMoveToWindow` when `window == nil`.
//
// [Bug Fix Document]
// 问题：加入类似 VS Code 这种多窗口应用后，一旦窗口数超过 7 个，整个“监控应用”界面的所有图标都无法点击，表现为卡死。
// 原因：窗口数超过限制后，界面加载了 `ScrollCatcherView` (原生的 NSView) 用于翻页。但在 SwiftUI 与 AppKit 混编时，覆盖在图标上方/下方的原生视图会因为原生的 Hit Testing 拦截掉所有点击事件，导致图标的 `.onTapGesture` 失效。
// 修复逻辑：
// 1. 将 `ScrollNSView` 的 `hitTest` 重写并强制返回 `nil`，使其对点击事件完全穿透。
// 2. 为了弥补无法接收 `scrollWheel` 的问题，改用 `NSEvent.addLocalMonitorForEvents` 监听全局滚轮，配合 `bounds.contains` 判断鼠标是否在视图区域内，从而完美实现既能滚动翻页、又不遮挡点击的效果。
// 注意事项：后续若有类似悬浮层需求，请遵循同样的 AppKit Hit-Test 穿透原则，不要让不可见的原生 NSView 吞掉点击事件。
// =========================================================================================
class ScrollNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self = self, let window = self.window, event.window == window else { return event }
                let locationInView = self.convert(event.locationInWindow, from: nil)
                if self.bounds.contains(locationInView) {
                    if event.deltaY != 0 {
                        self.onScroll?(event.deltaY)
                        return nil
                    } else if event.deltaX != 0 {
                        self.onScroll?(event.deltaX)
                        return nil
                    }
                }
                return event
            }
        } else if window == nil && monitor != nil {
            NSEvent.removeMonitor(monitor!)
            monitor = nil
        }
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Return nil so this view never intercepts mouse clicks, 
        // allowing SwiftUI's onTapGesture to work on sibling views.
        return nil
    }
}
