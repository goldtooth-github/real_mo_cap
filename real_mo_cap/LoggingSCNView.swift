import SceneKit
import UIKit

// SCNView subclass that logs UIKit / Focus engine events when enabled via DebugToggles
final class LoggingSCNView: SCNView {
    private var didRequestInitialFocus = false
    
    override var canBecomeFocused: Bool { true }
    override var canBecomeFirstResponder: Bool { true }
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if DebugToggles.enableFocusLogging {
            print("[Focus] SCNView moved to window: \(String(describing: window)) class=\(type(of: self))")
        }
        requestInitialFocusIfNeeded()
    }
    
    private func requestInitialFocusIfNeeded() {
        guard DebugToggles.enableFocusLogging, !didRequestInitialFocus else { return }
        didRequestInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if DebugToggles.enableFocusLogging { print("[Focus] requesting initial focus update") }
            self.setNeedsFocusUpdate()
            self.updateFocusIfNeeded()
            _ = self.becomeFirstResponder()
        }
    }
    
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        guard DebugToggles.enableFocusLogging else { return }
        let next = context.nextFocusedItem.map { String(describing: $0) } ?? "nil"
        let prev = context.previouslyFocusedItem.map { String(describing: $0) } ?? "nil"
        print("[Focus] didUpdateFocus prev=\(prev) -> next=\(next)")
    }
    
    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if DebugToggles.enableFocusLogging { print("[Focus] becomeFirstResponder -> \(r)") }
        return r
    }
    
    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if DebugToggles.enableFocusLogging { print("[Focus] resignFirstResponder -> \(r)") }
        return r
    }
    
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if DebugToggles.enableFocusLogging {
            let keys = presses.compactMap { $0.key?.charactersIgnoringModifiers }.joined(separator: ",")
            print("[Focus] pressesBegan keys=\(keys)")
        }
        super.pressesBegan(presses, with: event)
    }
}
