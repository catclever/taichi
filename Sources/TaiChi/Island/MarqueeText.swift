import SwiftUI


struct MarqueeText: View {
    let text: String
    let font: Font
    let foregroundColor: Color
    let velocity: Double // points per second (e.g. 30)
    
    var body: some View {
        MarqueeTextInner(text: text, font: font, foregroundColor: foregroundColor, velocity: velocity)
            .id(text)
    }
}

struct MarqueeTextInner: View {
    let text: String
    let font: Font
    let foregroundColor: Color
    let velocity: Double

    @State private var offset: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var isAnimating: Bool = false
    
    var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .hidden()
            .background(
                GeometryReader { containerGeo in
                    Color.clear.preference(key: ContainerWidthPreferenceKey.self, value: containerGeo.size.width)
                }
            )
            .overlay(
                Text(text)
                    .font(font)
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        GeometryReader { textGeo in
                            Color.clear.preference(key: TextWidthPreferenceKey.self, value: textGeo.size.width)
                        }
                    )
                    .offset(x: offset)
                    .frame(
                        width: containerWidth > 0 ? containerWidth : nil, 
                        alignment: (textWidth > containerWidth + 0.5) ? .leading : .center
                    )
                    .clipped(),
                alignment: .center
            )
            .onPreferenceChange(ContainerWidthPreferenceKey.self) { newWidth in
                containerWidth = newWidth
                updateAnimation()
            }
            .onPreferenceChange(TextWidthPreferenceKey.self) { newWidth in
                textWidth = newWidth
                updateAnimation()
            }
    }
    
    @State private var animationTask: Task<Void, Never>? = nil
    
    private func updateAnimation() {
        if textWidth > containerWidth + 0.5 && containerWidth > 0 {
            if !isAnimating {
                isAnimating = true
                let distance = textWidth - containerWidth + 20 // padding
                let duration = distance / velocity
                
                animationTask?.cancel()
                animationTask = Task {
                    while !Task.isCancelled {
                        await MainActor.run {
                            withAnimation(nil) {
                                offset = 0
                            }
                        }
                        
                        // 开始前等待 1.5 秒
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        if Task.isCancelled { break }
                        
                        await MainActor.run {
                            withAnimation(.linear(duration: duration)) {
                                offset = -distance
                            }
                        }
                        
                        // 等待滚动完成，加上 3 秒的结尾停留时间
                        try? await Task.sleep(nanoseconds: UInt64((duration + 3.0) * 1_000_000_000))
                    }
                }
            }
        } else {
            isAnimating = false
            animationTask?.cancel()
            withAnimation(nil) {
                offset = 0
            }
        }
    }
}

struct TextWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContainerWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


