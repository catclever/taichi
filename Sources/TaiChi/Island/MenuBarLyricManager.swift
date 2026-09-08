import Cocoa
import SwiftUI
import Combine

class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

class PassThroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

@MainActor
class MenuBarLyricManager: NSObject {
    static let shared = MenuBarLyricManager()
    
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    
    private var currentFullLyric: String = ""
    
    private var clipView: NSView?
    private var lyricLabel: NSTextField?
    
    private var popover: NSPopover?
    private var popoverEventMonitor: Any?
    
    private override init() {
        super.init()
        setupObservers()
    }
    
    private func setupObservers() {
        TaiChiSettings.shared.$showMenuBarLyrics
            .receive(on: DispatchQueue.main)
            .sink { [weak self] show in
                if show {
                    self?.createStatusItem()
                } else {
                    self?.removeStatusItem()
                }
            }
            .store(in: &cancellables)
            
        // Timer to sync current lyric
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateLyric()
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    
    private func createStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.autosaveName = "TaiChiMenuBarLyrics" 
            if let button = statusItem?.button {
                button.action = #selector(handleStatusItemClick)
                button.target = self
                button.title = ""
                
                let cv = PassThroughView(frame: button.bounds)
                cv.wantsLayer = true
                cv.layer?.masksToBounds = true
                cv.autoresizingMask = [.width, .height]
                
                let label = PassThroughTextField(labelWithString: "")
                label.font = NSFont.systemFont(ofSize: 13, weight: .regular)
                label.textColor = .labelColor
                label.drawsBackground = false
                label.isBordered = false
                label.isEditable = false
                label.isSelectable = false
                
                cv.addSubview(label)
                button.addSubview(cv)
                
                self.clipView = cv
                self.lyricLabel = label
            }
        }
        updateLyric() // initial
    }
    
    private func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }
    
    private func updateLyric() {
        guard let _ = statusItem else { return }
        
        let mediaState = MediaObserver.shared.state
        if !mediaState.isPlaying && mediaState.title.isEmpty {
            if currentFullLyric != "TaiChi" {
                currentFullLyric = "TaiChi"
                setDisplayText("")
            }
            return
        }
        
        let lyrics = LyricManager.shared.currentLyrics
        var newLyric = ""
        
        if lyrics.isEmpty {
            newLyric = "\(mediaState.title) - \(mediaState.artist)"
        } else {
            let actualTime = mediaState.currentElapsedTime
            let currentIndex = lyrics.lastIndex(where: { $0.time <= actualTime + 0.5 }) ?? 0
            if currentIndex >= 0 && currentIndex < lyrics.count {
                newLyric = lyrics[currentIndex].text
            }
        }
        
        if newLyric != currentFullLyric {
            currentFullLyric = newLyric
            setDisplayText(newLyric)
        }
    }
    
    private func setDisplayText(_ text: String) {
        guard let cv = clipView, let lbl = lyricLabel else { return }
        
        // Cancel active animations
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        lbl.animator().frame.origin.x = lbl.frame.origin.x
        NSAnimationContext.endGrouping()
        lbl.layer?.removeAllAnimations()
        
        let displayStr = text.isEmpty ? " ♪ " : " \(text) "
        lbl.stringValue = displayStr
        lbl.sizeToFit()
        
        // Center vertically
        lbl.frame.origin.y = (cv.bounds.height - lbl.frame.height) / 2
        
        if text.isEmpty || text == "TaiChi" {
            let textWidth = lbl.frame.width
            statusItem?.length = textWidth + 10
            cv.frame.size.width = textWidth + 10
            lbl.frame.origin.x = 5
        } else {
            let fixedWidth: CGFloat = 150
            statusItem?.length = fixedWidth
            cv.frame.size.width = fixedWidth
            
            let textWidth = lbl.frame.width
            if textWidth > fixedWidth {
                lbl.frame.origin.x = 5 // start slightly inset
                let distance = textWidth - fixedWidth + 15 // distance to scroll
                let duration = Double(distance) / 18.0 // 18 points per second (slightly faster) (very smooth, slow read speed)
                
                // Delay the animation slightly so it stays at the beginning for a moment
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    // Check if lyric changed while waiting
                    guard self.currentFullLyric == text else { return }
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = duration
                        context.timingFunction = CAMediaTimingFunction(name: .linear)
                        context.allowsImplicitAnimation = true
                        lbl.animator().frame.origin.x = -distance + 5
                    }, completionHandler: nil)
                }
            } else {
                lbl.frame.origin.x = (fixedWidth - textWidth) / 2
            }
        }
    }
    
    @objc private func handleStatusItemClick() {
        guard let button = statusItem?.button else { return }
        
        if popover == nil {
            let p = NSPopover()
            p.contentSize = NSSize(width: 200, height: 60)
            p.behavior = .transient
            
            let host = NSHostingController(rootView: MenuBarPlayerView())
            p.contentViewController = host
            self.popover = p
            
            popoverEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let strongSelf = self, strongSelf.popover?.isShown == true {
                    strongSelf.popover?.performClose(event)
                }
            }
        }
        
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}

struct MenuBarPlayerView: View {
    @ObservedObject var observer = MediaObserver.shared
    
    var body: some View {
        HStack(spacing: 20) {
            Button(action: { observer.sendTargetedCommand(5) }) { // Prev
                Image(systemName: "backward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            
            Button(action: { observer.sendTargetedCommand(2) }) { // Play/Pause
                Image(systemName: observer.state.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            
            Button(action: { observer.sendTargetedCommand(4) }) { // Next
                Image(systemName: "forward.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 200, height: 60)
    }
}
