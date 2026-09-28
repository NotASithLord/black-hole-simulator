import SwiftUI

struct BlackHoleDeskApp: App {
    @State private var settings = RenderSettings()

    var body: some Scene {
        WindowGroup("Black Hole Desk") {
            ContentView(settings: $settings)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Black Hole") {
                Button("Toggle HUD") { settings.showHUD.toggle() }.keyboardShortcut("h", modifiers: [])
                Button("Wallpaper Mode") { settings.wallpaperMode.toggle() }.keyboardShortcut("w", modifiers: [.command,.shift])
                Divider()
                Button("Reset Camera") { settings.resetCamera.toggle() }.keyboardShortcut("r", modifiers: [])
            }
        }
    }
}

@main
enum EntryPoint {
    static func main() {
        do {
            if CommandLine.arguments.count >= 4 && CommandLine.arguments[1] == "--validate-gpu" {
                try GPUVerification.validate(input: CommandLine.arguments[2], output: CommandLine.arguments[3])
            } else if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--benchmark" {
                try GPUVerification.benchmark(output:CommandLine.arguments[2])
            } else if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--appearance-test" {
                try AppearanceValidation.run(outputDirectory:CommandLine.arguments[2])
            } else if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--thickness-test" {
                try ThicknessValidation.run(outputDirectory:CommandLine.arguments[2])
            } else if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--rotation-test" {
                try RotationValidation.run(outputDirectory:CommandLine.arguments[2])
            } else { BlackHoleDeskApp.main() }
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
        }
    }
}
