import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct BlankPageView: View {
    let number: Int
    var body: some View {
        VStack {
            Spacer()
            Text("Blank Page \(number)")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Spacer()
        }
    }
}

struct PageControl: View {
    let currentPage: Int
    let pageCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    var body: some View {
        HStack {
            Button(action: {
                print("Left arrow tapped")
                onPrevious()
            }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 20, weight: .bold))
                    // Use fixed, high-contrast colors so arrows remain readable regardless of color scheme
                    .foregroundStyle(currentPage == 0 ? Color.white.opacity(0.35) : Color.white)
                    .padding(10)
            }
            .disabled(currentPage == 0)
            .padding(.trailing, 66) // Increased space further between left arrow and dots
            HStack(spacing: 8) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Circle()
                        // Use fixed colors for dots to avoid dark-mode dependent changes
                        .fill(i == currentPage ? Color.white : Color.white.opacity(0.3))
                        .frame(width: 8, height: 8)
                }
            }
            Button(action: {
                print("Right arrow tapped")
                onNext()
            }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .bold))
                    // Use fixed, high-contrast colors so arrows remain readable regardless of color scheme
                    .foregroundStyle(currentPage == pageCount - 1 ? Color.white.opacity(0.35) : Color.white)
                    .padding(10)
            }
            .disabled(currentPage == pageCount - 1)
            .padding(.leading, 66) // Increased space further between right arrow and dots
        }
        .contentShape(Rectangle())
        .padding(.vertical, 8)
        .padding(.bottom, 24)
        .background(Color.clear)
        // Subtle shadow to improve contrast over light backgrounds
        .shadow(color: Color.black.opacity(0.6), radius: 2, x: 0, y: 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page navigation")
        .accessibilityValue("Page \(currentPage + 1) of \(pageCount)")
        .zIndex(10)
    }
}

struct LifeformsPageView: View {
    // Start on first page
    @State private var selection: Int = 0
    @State private var previousSelection: Int = 0
    @State private var settledSelection: Int = 0 // Track the visually settled page
    
    // 10 different motion capture file pairs (loopStart/loopEnd: nil = use defaults)
    private let mocapFiles: [(asf: String, amc: String, loopStart: Int?, loopEnd: Int?)] = [
        ("09",  "09_03",   nil, nil),
        ("02",  "02_03",   nil, nil),
        ("05",  "05_14",   nil, nil),
        ("60",  "60_07",   nil, nil),
        ("85",  "85_14",   nil, nil),
        ("118", "118_14",  nil, nil),
        ("128", "128_10",  nil, nil),
        ("133", "133_01",  nil, nil),
        ("137", "137_29",  nil, nil),
        ("143", "143_34",  nil, nil),
    ]
    
    private var pageCount: Int { mocapFiles.count }
    
    // Track initial appear to avoid double-activation
    @State private var didActivateInitial = false
    @State private var pausedStates: [Bool] = Array(repeating: false, count: 10)
    // New: reflect control panel visibility so we can toggle system UI
    @State private var controlPanelVisible: Bool = true
    @State private var isDisplayLockPressed: Bool = false
    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        let mainView = ZStack(alignment: .bottom) {
            LazyPager(pageCount: pageCount, index: $selection, onPageSettled: { settledIndex in
                settledSelection = settledIndex
                activate(settledIndex)
            }, isSwipeLocked: isDisplayLockPressed) { i in
                page(i)
            }
            .zIndex(0)
            // Listen to control panel visibility from child views
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                activate(selection)
                settledSelection = selection
            }
            .onPreferenceChange(ControlPanelVisibilityPreferenceKey.self) { visible in
                controlPanelVisible = visible
            }
            // Previously we toggled safe areas based on control panel visibility, which caused
            // visible outer padding to change on iPhone. Keep this constant to avoid layout shift.
            .ignoresSafeArea(.container, edges: .all)
            #if canImport(UIKit)
            // Hide status bar when panel is hidden; restore when visible
            .statusBarHidden(!controlPanelVisible)
            #endif

            if controlPanelVisible {
                PageControl(currentPage: selection, pageCount: pageCount, onPrevious: {
                    if selection > 0 {
                        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 1.0)) {
                            selection -= 1
                        }
                    }
                }, onNext: {
                    if selection < pageCount - 1 {
                        withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 1.0)) {
                            selection += 1
                        }
                    }
                })
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: controlPanelVisible)
                    .zIndex(10)
            }
        }
        .onChange(of: selection) { oldVal, newVal in
            guard oldVal != newVal else { return }
            deactivate(oldVal)
            previousSelection = newVal
        }
        .onAppear {
            previousSelection = selection
            settledSelection = selection
            if !didActivateInitial {
                DispatchQueue.main.async { activate(selection); didActivateInitial = true }
            }
        }
        #if os(iOS)
        mainView
            .background(HomeIndicatorHider(hidden: !controlPanelVisible))
        #else
        mainView
        #endif
    }

    @ViewBuilder
    private func page(_ i: Int) -> some View {
        if settledSelection == i, i < mocapFiles.count {
            let files = mocapFiles[i]
            AMCASFViewerLifeformViewAsync(
                isActive: true,
                isPaused: $pausedStates[i],
                isDisplayLockPressed: $isDisplayLockPressed,
                asfName: files.asf,
                amcName: files.amc,
                loopStartFrame: files.loopStart,
                loopEndFrame: files.loopEnd
            )
        } else {
            Color.clear
        }
    }

    private func activate(_ i: Int) { print("Activate page \(i)") }
    private func deactivate(_ i: Int) { print("Deactivate page \(i)") }
}

#Preview {
    LifeformsPageView()
}
