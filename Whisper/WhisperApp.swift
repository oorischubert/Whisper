//
//  WhisperApp.swift
//  Whisper
//
//  Created by Oori Schubert on 9/7/25.
//

import SwiftUI
import AppKit

@main
struct WhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings {
            PreferencesView()
        }
    }
}
