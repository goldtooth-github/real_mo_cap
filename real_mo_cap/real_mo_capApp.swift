//
//  real_mo_capApp.swift
//  real_mo_cap
//
//  Created by Nick Packer on 20/07/2025.
//

import SwiftUI

//class Focuspocus: ObservableObject {@Published var isMainWindowActive: Bool = true}

@main
struct real_mo_capApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var powerModeMonitor = PowerModeMonitor()
   // @StateObject private var focuspocus = Focuspocus() // Injected focus state
    @StateObject private var settingsIO = SettingsIOActions() // Shared settings I/O for entire app
    
    // Static tokens / state retained for app lifetime
    //private static var nsWindowMainObserver: NSObjectProtocol? = nil
   // private static var nsWindowResignMainObserver: NSObjectProtocol? = nil
   // private static var appDidBecomeActiveObserver: NSObjectProtocol? = nil
    //private static var appWillResignActiveObserver: NSObjectProtocol? = nil
    //private static var appWillEnterForegroundObserver: NSObjectProtocol? = nil
   // private static var appDidEnterBackgroundObserver: NSObjectProtocol? = nil
   // private static var pollTimer: Timer? = nil
   // private static var lastKeyWindowHash: Int? = nil
   // private static var lastAppActive: Bool? = nil
   // private static var lifecycleInstalled = false
    
    init() {
        // Early instrumentation (should always print once if init executes)
        // Removed: PrewarmCenter.shared.run()
    }
 
    var body: some Scene {
        WindowGroup {
            RootLaunchView()
                .environmentObject(powerModeMonitor)
              //  .environmentObject(focuspocus) // Inject focus state
                .environmentObject(settingsIO) // Provide settings actions globally (sheets inherit)
                .onChange(of: scenePhase) { _, newPhase in
                    // Removed: Retry keyboard warm as soon as scenes become active/foregrounded
                    // switch newPhase {
                    // case .active, .inactive: PrewarmCenter.shared.run()
                    // case .background: break
                    // @unknown default: break
                    // }
                }
               // .limitWindowSizeIfMac() // <-- Apply window size limit only on Mac
        }
    }
}

private struct RootLaunchView: View {
    @State private var showSplash = true
    var body: some View {
        ZStack {
            ContentView()
            if showSplash {
                VStack(spacing: 12) {
                    
                    Text("Dumb Machine")
                        .font(.system(size: 18, weight: .regular))
                        .kerning(0.5)
                    
                    Image("lifeff")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 120, height: 120)
                    
                    Text("LifeForm Oscillator")
                        .font(.system(size: 36, weight: .bold))
                        .kerning(1)
                    
                    Text("Experimental LFO's + Simulated lifeforms")
                        .multilineTextAlignment(.center)
                        .font(.system(size: 12, weight: .regular))
                        .kerning(1)
                        .padding(30)
                    
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .ignoresSafeArea()
                .transition(.opacity)
                // Removed: KeyboardPrewarmView() // SwiftUI-compatible keyboard prewarm
            }
        }
        .onAppear {
            // Warm all lazy subsystems (CoreMIDI, clock, tick router, haptics)
            // during the 4s splash so controls respond instantly on first touch.
            PrewarmCenter.shared.run()
           DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
               self.showSplash = false
            }
        }
    }
}
