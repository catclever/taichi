import SwiftUI

struct YinYangIcon: View {
    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: size/2, y: size/2)
            
            ZStack {
                // Right half (white)
                Path { path in
                    path.addArc(center: center, radius: size/2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
                }
                .fill(Color.white)
                
                // Left half (black/dark)
                Path { path in
                    path.addArc(center: center, radius: size/2, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
                }
                .fill(Color.black.opacity(0.8))
                
                // Top inner circle (black base)
                Circle()
                    .fill(Color.black.opacity(0.8))
                    .frame(width: size/2, height: size/2)
                    .offset(y: -size/4)
                
                // Bottom inner circle (white base)
                Circle()
                    .fill(Color.white)
                    .frame(width: size/2, height: size/2)
                    .offset(y: size/4)
                
                // Top dot (white)
                Circle()
                    .fill(Color.white)
                    .frame(width: size/6, height: size/6)
                    .offset(y: -size/4)
                
                // Bottom dot (black)
                Circle()
                    .fill(Color.black.opacity(0.8))
                    .frame(width: size/6, height: size/6)
                    .offset(y: size/4)
            }
        }
    }
}
