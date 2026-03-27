//
//  RenderCoordinator.swift
//  universa
//
//  Created on December 23, 2025.
//

import Foundation

/// Global coordinator for managing concurrent rendering tasks across all simulations
final class RenderCoordinator {
    static let shared = RenderCoordinator()
    
    /// Semaphore to limit concurrent render updates
    /// Value of 2 allows 2 simulations to render simultaneously
    /// Adjust based on device performance profiling
    let renderSemaphore = DispatchSemaphore(value: 1)
    
    private init() {}
}
