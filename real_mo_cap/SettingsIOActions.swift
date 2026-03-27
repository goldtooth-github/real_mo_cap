import Foundation
import SwiftUI

// Environment object that exposes settings I/O actions (Load/Save/Reset)
final class SettingsIOActions: ObservableObject {
    var requestImport: (() -> Void)?
    var requestExport: (() -> Void)?
    var requestReset: (() -> Void)?
    func importFile() { requestImport?() }
    func exportFile() { requestExport?() }
    func reset() { requestReset?() }
}
