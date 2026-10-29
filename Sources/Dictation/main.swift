import AppKit

switch Mode(arguments: Array(CommandLine.arguments.dropFirst())) {
case .app:
    SupportFolder.makePrivate()
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let coordinator = Coordinator()
        let window = MainWindow(coordinator: coordinator)
        app.delegate = window
        coordinator.start()
        withExtendedLifetime((coordinator, window)) { app.run() }
    }
case .selfTest(let options):
    Task { exit(await Headless.selfTest(options)) }
    dispatchMain()
case .bench(let options):
    Task { exit(await Headless.bench(options)) }
    dispatchMain()
case .listInputs:
    exit(Headless.listInputs())
case .renderBar(let directory):
    MainActor.assumeIsolated { exit(RenderBar.run(into: directory)) }
case .renderWindow(let directory):
    exit(MainActor.assumeIsolated { WindowRender.run(to: directory) })
case .importWillowDryRun(let folder):
    exit(WillowImporter.dryRun(folder))
case .usage(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
