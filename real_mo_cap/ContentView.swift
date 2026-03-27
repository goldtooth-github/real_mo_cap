//
//  ContentView.swift
//  universa
//
//  Created by Nick Packer on 20/07/2025.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var settingsIO = SettingsIOActions()
    var body: some View {
        LifeformsPageView()
            .environmentObject(settingsIO)
            .background(Color.black)
    }
}

#Preview {
    ContentView()
}
