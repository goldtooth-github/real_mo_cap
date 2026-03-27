import SwiftUI

struct AnimationCompletionObserverModifier<Value>: AnimatableModifier where Value: VectorArithmetic & Comparable {
    var targetValue: Value
    var completion: () -> Void

    // AnimatableData is the value being animated
    var animatableData: Value {
        didSet {
            notifyCompletionIfFinished()
        }
    }

    init(observedValue: Value, completion: @escaping () -> Void) {
        self.completion = completion
        self.animatableData = observedValue
        self.targetValue = observedValue
    }

    func body(content: Content) -> some View {
        content
    }

    private func notifyCompletionIfFinished() {
        if animatableData == targetValue {
            DispatchQueue.main.async {
                completion()
            }
        }
    }
}

extension View {
    func onAnimationCompleted<Value: VectorArithmetic & Comparable>(for value: Value, completion: @escaping () -> Void) -> some View {
        self.modifier(AnimationCompletionObserverModifier(observedValue: value, completion: completion))
    }
}
