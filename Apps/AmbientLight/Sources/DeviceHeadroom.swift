import SwiftUI

struct DeviceHeadroomKey: EnvironmentKey {
  static let defaultValue: Float = 1
}

extension EnvironmentValues {
  var deviceHeadroom: Float {
    get { self[DeviceHeadroomKey.self] }
    set { self[DeviceHeadroomKey.self] = newValue }
  }
}

struct DeviceHeadroomReader<Content: View>: View {
  let content: Content
  @State private var deviceHeadroom: Float = DeviceHeadroomKey.defaultValue

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .environment(\.deviceHeadroom, deviceHeadroom)
      .background {
        DeviceHeadroomReporter(deviceHeadroom: $deviceHeadroom)
          .frame(width: 0, height: 0)
      }
  }
}

private struct DeviceHeadroomReporter: UIViewRepresentable {
  @Binding var deviceHeadroom: Float

  func makeUIView(context: Context) -> HeadroomView {
    let view = HeadroomView()
    view.onHeadroomChange = updateHeadroom(_:)
    return view
  }

  func updateUIView(_ uiView: HeadroomView, context: Context) {
    uiView.onHeadroomChange = updateHeadroom(_:)
    uiView.updateHeadroom()
  }

  private func updateHeadroom(_ value: Float) {
    guard abs(deviceHeadroom - value) > 0.005 else { return }

    Task { @MainActor in
      deviceHeadroom = value
    }
  }
}

private final class HeadroomView: UIView {
  var onHeadroomChange: ((Float) -> Void)?
  private var samplingTask: Task<Void, Never>?

  override func didMoveToWindow() {
    super.didMoveToWindow()

    samplingTask?.cancel()
    samplingTask = nil

    guard window != nil else { return }

    updateHeadroom()

    // currentEDRHeadroom can change while EDR content is onscreen and has no
    // dedicated change notification. Sampling slowly keeps shaders aligned
    // with the live limit without tying observation to the render frame rate.
    samplingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .seconds(1))
        } catch {
          return
        }

        guard let self, self.window != nil else { return }
        self.updateHeadroom()
      }
    }
  }

  func updateHeadroom() {
    let screen = window?.windowScene?.screen
    let currentHeadroom = Float(
      screen?.currentEDRHeadroom ?? CGFloat(DeviceHeadroomKey.defaultValue)
    )
    onHeadroomChange?(max(currentHeadroom, DeviceHeadroomKey.defaultValue))
  }
}
