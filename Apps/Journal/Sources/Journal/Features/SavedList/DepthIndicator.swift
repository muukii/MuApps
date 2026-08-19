import SwiftUI

struct DepthIndicator: View {
  
  let depth: Int
  
  var body: some View {
    let height: CGFloat = 8
    let radiusForEnd: CGFloat = height / 2
    VStack {
      HStack(spacing: 1) {
        Group {
          switch depth {
          case 0:
            EmptyView()
          case 1:
            UnevenRoundedRectangle(
              topLeadingRadius: 3,
              bottomLeadingRadius: 3,
              bottomTrailingRadius: 3,
              topTrailingRadius: 3,
              style: .continuous
            )
          case 2...:
            UnevenRoundedRectangle(
              topLeadingRadius: radiusForEnd,
              bottomLeadingRadius: radiusForEnd,
              bottomTrailingRadius: 3,
              topTrailingRadius: 3,
              style: .continuous
            )
            .opacity(0.2)
            if depth > 1 {        
              ForEach(1..<(depth - 1), id: \.self) { _ in
                UnevenRoundedRectangle(
                  topLeadingRadius: 3,
                  bottomLeadingRadius: 3,
                  bottomTrailingRadius: 3,
                  topTrailingRadius: 3,
                  style: .continuous
                )
              }
              .opacity(0.2)
            }
            UnevenRoundedRectangle(
              topLeadingRadius: 3,
              bottomLeadingRadius: 3,
              bottomTrailingRadius: radiusForEnd,
              topTrailingRadius: radiusForEnd,
              style: .continuous
            )
          default:
            EmptyView()
          }
        }
        .frame(width: 16)
      }
      .frame(height: height)    
    }
  }
}

#Preview {
  DepthIndicator(depth: 3)
}
