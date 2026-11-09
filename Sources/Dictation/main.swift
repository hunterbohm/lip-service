import AppKit
import DictationCore

// A write to a child that already exited fails with EPIPE instead of ending the app.
signal(SIGPIPE, SIG_IGN)

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
case .ttsCheck(let options):
    Task { exit(await Headless.ttsCheck(options)) }
    dispatchMain()
case .micStart(let options):
    Task { @MainActor in exit(await Headless.micStart(options)) }
    dispatchMain()
case .renderBar(let directory):
    MainActor.assumeIsolated { exit(RenderBar.run(into: directory)) }
case .renderWindow(let directory):
    exit(MainActor.assumeIsolated { WindowRender.run(to: directory) })
case .agentBench(let options):
    Task { @MainActor in exit(await AgentBench.run(options)) }
    dispatchMain()
case .t3Connect(let home, let code):
    Task { @MainActor in
        do {
            let client = try T3Client(destination: T3Destination(home: home), secrets: Keychain())
            try await client.signIn(pairingCode: code)
            print("connected to \(client.origin) until \(client.token?.expires.description ?? "?")")
            exit(0)
        } catch {
            print("failed: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
case .t3Bridge(let home):
    Task { exit(await T3Bridge.run(home: home)) }
    dispatchMain()
case .setup(let command):
    Task { @MainActor in exit(await Headless.setup(command)) }
    dispatchMain()
case .talkTest(let options):
    Task { @MainActor in exit(await TalkTest.run(options)) }
    dispatchMain()
case .handOffTest(let options):
    Task { @MainActor in exit(await HandOffTest.run(options)) }
    dispatchMain()
case .importWillowDryRun(let folder):
    exit(WillowImporter.dryRun(folder))
case .installFormatter(let archive):
    do {
        SupportFolder.makePrivate()
        try SmartFormatter.install(archive)
        print("installed \(SmartFormatter.pinnedFolder.path)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
case .usage(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
