//
//  PowerModeMonitor.swift
//  universa
//
//  Created by Nick Packer on 26/09/2025.
//

// PowerModeMonitor.swift
import Foundation
import Combine

class PowerModeMonitor: ObservableObject {
    @Published var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var cancellable: AnyCancellable?
    private var lowPowerModeHandler: ((Bool) -> Void)?

    init() {
        cancellable = NotificationCenter.default
            .publisher(for: .NSProcessInfoPowerStateDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let enabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                self?.isLowPowerMode = enabled
                self?.lowPowerModeHandler?(enabled)
            }
    }
    
    func setLowPowerModeHandler(_ handler: @escaping (Bool) -> Void) {
        self.lowPowerModeHandler = handler
        handler(isLowPowerMode) // Ensure initial state is sent
    }
}
