import SwiftUI

// Lightweight lazy pager that only instantiates the visible page and its immediate neighbours.
// Keeps page state alive while visible; off-screen pages beyond +/-1 are replaced by placeholders.
struct LazyPager<Content: View>: View {
    let pageCount: Int
    @Binding var index: Int
    let content: (Int) -> Content
    // New: Callback for when the pager is visually settled
    var onPageSettled: ((Int) -> Void)? = nil
    // New: Block swipe if locked
    var isSwipeLocked: Bool = false
    
    @GestureState private var dragTranslation: CGFloat = 0
    @State private var isDragging: Bool = false
    // New: Track last settled index to avoid duplicate calls
    @State private var lastSettledIndex: Int? = nil
    // New: Require predominantly horizontal movement to paginate (gives ~10pt vertical slack)
    private let horizontalDominanceSlack: CGFloat = 10
    
    init(pageCount: Int, index: Binding<Int>, onPageSettled: ((Int) -> Void)? = nil, isSwipeLocked: Bool = false, @ViewBuilder content: @escaping (Int) -> Content) {
        self.pageCount = pageCount
        self._index = index
        self.content = content
        self.onPageSettled = onPageSettled
        self.isSwipeLocked = isSwipeLocked
    }
    
    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            HStack(spacing: 0) {
                ForEach(0..<pageCount, id: \.self) { i in
                    Group {
                        if shouldMaterialize(i) {
                            content(i)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: width, height: geo.size.height)
                }
            }
            .offset(x: -CGFloat(index) * width + dragTranslation)
            // Always animate index changes with spring.
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 1.0), value: index)
            // Also animate the snap-back (dragTranslation returning to 0 once dragging ends) even when index is unchanged.
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 1.0), value: dragTranslation == 0 && !isDragging)
            .contentShape(Rectangle())
            .gesture(isSwipeLocked ? nil : dragGesture(pageWidth: width))
            .clipped()
            .accessibilityElement(children: .contain)
            // New: Detect when pager is visually settled
            .onChange(of: dragTranslation) { _, _ in
                checkIfSettled()
            }
            .onChange(of: isDragging) { _, _ in
                checkIfSettled()
            }
            .onChange(of: index) { _, _ in
                checkIfSettled()
            }
        }
    }
    
    private func shouldMaterialize(_ i: Int) -> Bool { abs(i - index) <= 1 }
    
    // Determine if a drag is predominantly horizontal (allow some vertical slack)
    private func isHorizontallyDominant(_ translation: CGSize) -> Bool {
        abs(translation.width) > abs(translation.height) + horizontalDominanceSlack
    }
    
    private func dragGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .local)
            // Only allow horizontal-dominant drags to translate the pager; otherwise, snap stays put.
            .updating($dragTranslation) { value, state, _ in
                if isHorizontallyDominant(value.translation) {
                    state = value.translation.width
                } else {
                    state = 0
                }
            }
            .onChanged { value in
                if !isDragging { isDragging = true }
                // No-op otherwise: we gate movement in `updating` already.
            }
            .onEnded { value in
                // Mark drag ended BEFORE mutating index so the spring animates the page change.
                isDragging = false
                // If the drag wasn't predominantly horizontal, revert to original page.
                guard isHorizontallyDominant(value.translation) else {
                    return // dragTranslation resets via GestureState; spring will snap back
                }
                let delta = value.translation.width / max(1, pageWidth)
                let proposed = CGFloat(index) - delta
                let newIndex = Int((proposed).rounded())
                index = min(max(newIndex, 0), pageCount - 1)
            }
    }
    
    // New: Check if pager is visually settled and call callback
    private func checkIfSettled() {
        // Only settled if not dragging, dragTranslation is zero, and offset matches index
        if !isDragging && dragTranslation == 0 {
            if lastSettledIndex != index {
                lastSettledIndex = index
                onPageSettled?(index)
            }
        }
    }
}
