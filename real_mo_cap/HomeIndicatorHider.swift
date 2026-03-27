// filepath: /Users/nick/Desktop/lifeform/dumbmachine/universa/universa/HomeIndicatorHider.swift
#if os(iOS)
import SwiftUI
import UIKit

/// A compatibility helper to control the iOS home indicator visibility on all supported iOS versions.
/// Unlike SwiftUI's `.homeIndicatorAutoHidden(_:)` (iOS 16+), this works back to iOS 11 by
/// embedding an invisible UIViewController that overrides `prefersHomeIndicatorAutoHidden`.
struct HomeIndicatorHider: UIViewControllerRepresentable {
    /// When true, the home indicator will be hidden (auto-hidden) if possible.
    var hidden: Bool

    func makeUIViewController(context: Context) -> Controller {
        let vc = Controller()
        vc.hidden = hidden
        return vc
    }

    func updateUIViewController(_ uiViewController: Controller, context: Context) {
        uiViewController.hidden = hidden
    }

    final class Controller: UIViewController {
        var hidden: Bool = false {
            didSet {
                guard oldValue != hidden else { return }
                if #available(iOS 11.0, *) {
                    requestUpdates()
                    // If we just hid, nudge the system again shortly after to cut perceived delay
                    if hidden {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.requestUpdatesIfStillHidden() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.requestUpdatesIfStillHidden() }
                    }
                }
            }
        }
        override var prefersHomeIndicatorAutoHidden: Bool { hidden }
        override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { hidden ? [.bottom] : [] }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
        }
        @available(iOS 11.0, *)
        private func requestUpdates() {
            setNeedsUpdateOfHomeIndicatorAutoHidden()
            setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
        }
        @available(iOS 11.0, *)
        private func requestUpdatesIfStillHidden() {
            guard hidden else { return }
            requestUpdates()
        }
    }
}
#endif
