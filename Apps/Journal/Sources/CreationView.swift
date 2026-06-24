import MuColor
import SwiftUI
import ScrollEdgeEffect

struct CreationView: View {

  @State var isSettingsPresented: Bool = false
  @Namespace private var namespace

  var body: some View {

    NavigationStack {
      ZStack {
        Rectangle()
          .fill(.background)
          .ignoresSafeArea(edges: .all)
        VStack {
          DateView()
          SecondaryContainer {           
            FloatingCardContainer {
              VStack {
                TextCapture(placeholder: "Write your thoughts...")
                
                Button { 
                  
                } label: { 
                  Image(systemName: "arrow.up")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .padding(2)
                    .padding(.vertical, 5)
                    .contentShape(Circle())
                }
                .buttonStyle(.glassProminent)                
                .frame(maxWidth: .infinity, alignment: .trailing)
                
              }
            }
          }
          .aspectRatio(.init(width: 1, height: 1.1414), contentMode: .fit)
          .padding(32)
        }
      }
      .toolbar(content: {
        ToolbarItem(placement: .navigationBarTrailing) {
          NavigationLink.init { 
            ListView()
              .navigationTransition(.zoom(sourceID: "list", in: namespace))
          } label: { 
            Image(systemName: "calendar")
          }
          .matchedTransitionSource(id: "list", in: namespace)
        }
        
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: {
            isSettingsPresented.toggle()
          }) {
            Image(systemName: "gearshape")
          }
          .matchedTransitionSource(id: "settings", in: namespace)
        }
      })
//      .toolbarTitleDisplayMode(.inlineLarge)
//      .navigationTitle("Creation")
    }
    .sheet(isPresented: $isSettingsPresented) {
      SettingsScreen()
        .navigationTransition(.zoom(sourceID: "settings", in: namespace))
    }
    .appNavigationBarStyle()

  }

}

struct DateView: View {
  let date: Date
  let locale: Locale

  init(date: Date = .now, locale: Locale = .current) {
    self.date = date
    self.locale = locale
  }

  var body: some View {
    Text(formattedDate)
      .font(.system(size: 20, weight: .semibold))
      .foregroundStyle(.secondary)
      .accessibilityLabel(accessibilityDate)
  }

  private var formattedDate: String {
    // Example: "Mon · Jun 22"
    let weekday = date.formatted(.dateTime.weekday(.abbreviated).locale(locale))
    let month = date.formatted(.dateTime.month(.abbreviated).locale(locale))
    let day = date.formatted(.dateTime.day().locale(locale))
    return "\(weekday) · \(month) \(day)"
  }

  private var accessibilityDate: String {
    // More verbose for VoiceOver
    date.formatted(.dateTime.weekday(.wide).month(.wide).day().locale(locale))
  }
}

struct TextCapture: View {
  
  @State private var text: String
  @FocusState private var isFocused: Bool

  private let placeholder: String
  
  init(placeholder: String) {
    self.placeholder = placeholder
    self._text = State(initialValue: "")
  }
  
  var body: some View {
    ZStack(alignment: .topLeading) {
      Group {
        if text.isEmpty {
          Text(placeholder)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .allowsHitTesting(false)
        }
        
        TextEditor(text: $text)
          .foregroundStyle(.primary)
          .focused($isFocused)
          .scrollContentBackground(.hidden)
          .padding(16)
//          .scrollEdgeEffect()
      }
      .font(.system(size: 32))
      .fontWeight(.bold)
    }
  }
}

struct FloatingCardContainer<Content: View>: View {
  
  private let content: Content

  @State private var isAnimated: Bool = false
  
  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ZStack {
      content
    }
    .padding(16)
    .background {
      RoundedRectangle(cornerRadius: 16)
        .fill(.background)
    }
//    .animation(
//      .easeInOut(duration: 2)
//      .repeatForever(),
//      body: { content in
//        content.rotationEffect(.degrees(isAnimated ? -1 : 1))
//      }
//    )
//    .animation(
//      .easeInOut(duration: 3)
//      .repeatForever(),
//      body: { content in
//        content
//          .offset(y: isAnimated ? -2 : 2)
//          .scaleEffect(isAnimated ? 1.05 : 1)
//      }
//    )  
//    .onAppear {
//      isAnimated = true
//    }
  }
}
