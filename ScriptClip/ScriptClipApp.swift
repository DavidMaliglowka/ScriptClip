//
//  ScriptClipApp.swift
//  ScriptClip
//
//  Created by David Maliglowka on 4/18/25.
//

import SwiftUI

@main
struct ScriptClipApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Apply frame modifiers here if needed for the window
                // .frame(minWidth: 700, minHeight: 450) // Example
        }
        // --- ADD COMMANDS HERE ---
        .commands {
             CommandMenu("Edit") {
                 // We need a way to trigger delete from here.
                 // This requires passing a message or using NotificationCenter,
                 // as the App struct doesn't directly own the ContentView state.

                 // --- Option 1: NotificationCenter (Simpler for now) ---
                 Button("Delete Selection") {
                      NotificationCenter.default.post(name: .deleteSelectionNotification, object: nil)
                 }
                 .keyboardShortcut(.delete, modifiers: [])
                 // We'll disable this via canPerformAction later if needed,
                 // or handle it within ContentView if no selection exists.

                 Divider()
                 Button("Copy") { /* TODO */ NotificationCenter.default.post(name: .copySelectionNotification, object: nil) }
                    .keyboardShortcut("c", modifiers: .command)
                 Button("Paste") { /* TODO */ NotificationCenter.default.post(name: .pasteSelectionNotification, object: nil) }
                    .keyboardShortcut("v", modifiers: .command)
             }
        }
    }
}

// --- ADD NOTIFICATION NAMES ---
extension Notification.Name {
    static let deleteSelectionNotification = Notification.Name("com.david.ScriptClip.deleteSelection")
    static let copySelectionNotification = Notification.Name("com.david.ScriptClip.copySelection")
    static let pasteSelectionNotification = Notification.Name("com.david.ScriptClip.pasteSelection")
    // Add more as needed
}
