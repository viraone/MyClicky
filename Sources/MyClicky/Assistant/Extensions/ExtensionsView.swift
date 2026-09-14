import AppKit
import SwiftUI

/// The Extensions tab: what's installed (switch on/off, remove, open the
/// folder, run an action by hand), the code theme picker, and the
/// marketplace — a searchable list fetched from the catalog repo, each
/// row a one-click install.
struct ExtensionsView: View {
    @ObservedObject var state: AssistantState
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var marketplace: ExtensionMarketplace
    @State private var installURL = ""
    @State private var confirmingRemoval: LoadedExtension?
    @State private var actionParams: [String: String] = [:]
    @State private var expandedAction: String?

    init(state: AssistantState) {
        self.state = state
        self.manager = state.extensions
        self.marketplace = state.marketplace
    }

    private let mono = Font.system(size: 12, design: .monospaced)
    private let monoBold = Font.system(size: 12, weight: .semibold, design: .monospaced)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                installedCard
                themeCard
                marketplaceCard
            }
            .padding(.bottom, 8)
        }
        .task { if marketplace.entries.isEmpty { await marketplace.refresh() } }
        .alert(item: $confirmingRemoval) { ext in
            Alert(title: Text("Remove \(ext.name)?"),
                  message: Text("Its folder moves to the Trash. Anything it contributed — verbs, themes, tools — goes with it."),
                  primaryButton: .destructive(Text("Remove")) {
                      do { try manager.uninstall(ext) } catch { manager.lastMessage = error.localizedDescription }
                  },
                  secondaryButton: .cancel())
        }
    }

    // MARK: Installed

    private var installedCard: some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(state.accent)
                Text("Installed").font(monoBold).foregroundStyle(.white.opacity(0.85))
                Text("\(manager.installed.filter(\.isActive).count) on · \(manager.installed.count) total")
                    .font(mono).foregroundStyle(.white.opacity(0.4))
                Spacer()
                iconButton("folder", help: "Open the Extensions folder in Finder — drop a folder here to install it") { manager.revealRoot() }
                iconButton("arrow.clockwise", help: "Re-read every extension from disk (no relaunch needed)") { manager.reload() }
            }
            if let message = manager.lastMessage {
                HStack(spacing: 6) {
                    Text(message).font(mono).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
                    Spacer()
                    Button { manager.lastMessage = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.4))
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }
            if manager.installed.isEmpty {
                Text("No extensions yet. Install one from the marketplace below, paste a git URL, or drop an extension folder on this tab.")
                    .font(mono).foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(manager.installed) { ext in
                installedRow(ext)
            }
            HStack(spacing: 8) {
                TextField("git URL (https://github.com/you/peeky-ext.git)", text: $installURL)
                    .textFieldStyle(.plain)
                    .font(mono)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
                    .onSubmit { installFromURL() }
                Button("Install") { installFromURL() }
                    .buttonStyle(.plain)
                    .font(monoBold)
                    .foregroundStyle(installURL.isEmpty || manager.busy != nil ? .white.opacity(0.3) : AssistantPhase.done.color)
                    .disabled(installURL.isEmpty || manager.busy != nil)
            }
            if let busy = manager.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(busy).font(mono).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
        }
    }

    private func installedRow(_ ext: LoadedExtension) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { ext.enabled }, set: { manager.setEnabled($0, id: ext.id) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .disabled(ext.manifest == nil)
                    .help(ext.enabled ? "Switch off (keeps the files)" : "Switch on")
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(ext.name).font(monoBold).foregroundStyle(.white.opacity(ext.isActive ? 0.9 : 0.5))
                        Text(ext.version).font(mono).foregroundStyle(.white.opacity(0.35))
                        if let author = ext.manifest?.author {
                            Text("by \(author)").font(mono).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                        }
                    }
                    if let error = ext.error {
                        Text(error).font(mono).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    } else if let description = ext.manifest?.description, !description.isEmpty {
                        Text(description).font(mono).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
                    }
                    if !ext.summary.isEmpty {
                        Text(ext.summary).font(mono).foregroundStyle(state.accent.opacity(0.8))
                    }
                }
                Spacer(minLength: 4)
                if let homepage = ext.manifest?.homepage, let url = URL(string: homepage) {
                    iconButton("link", help: homepage) { NSWorkspace.shared.open(url) }
                }
                iconButton("folder", help: "Show in Finder") { manager.reveal(ext) }
                iconButton("trash", help: "Remove (moves to Trash)") { confirmingRemoval = ext }
            }
            if ext.isActive, let actions = ext.manifest?.contributes?.actions, !actions.isEmpty {
                actionsList(ext, actions)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
    }

    /// Each verb with a ▶ to run it now — the way to try an action without
    /// saying it, and to see what the phone's `EXT <verb>` will do.
    private func actionsList(_ ext: LoadedExtension, _ actions: [ExtensionManifest.Action]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(actions, id: \.verb) { action in
                let key = "\(ext.id)/\(action.verb)"
                let params = action.params ?? []
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Button {
                            if params.isEmpty {
                                state.onRunExtensionAction?(action.verb, [:])
                            } else {
                                expandedAction = expandedAction == key ? nil : key
                            }
                        } label: {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(AssistantPhase.done.color)
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .help(params.isEmpty ? "Run \(action.verb) now" : "Fill in its parameters and run")
                        Text(action.verb).font(monoBold).foregroundStyle(.white.opacity(0.8))
                        Text(action.description).font(mono).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                        if action.irreversible == true {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                                .help("Marked irreversible — Peeky asks before running it from a voice command")
                        }
                        Spacer()
                    }
                    if expandedAction == key {
                        ForEach(params, id: \.name) { param in
                            HStack(spacing: 6) {
                                Text(param.name).font(mono).foregroundStyle(.white.opacity(0.6)).frame(width: 90, alignment: .trailing)
                                TextField(param.description ?? param.name,
                                          text: Binding(get: { actionParams["\(key)#\(param.name)"] ?? "" },
                                                        set: { actionParams["\(key)#\(param.name)"] = $0 }))
                                    .textFieldStyle(.plain).font(mono).padding(4)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.3)))
                            }
                        }
                        HStack {
                            Spacer()
                            Button("Run \(action.verb)") {
                                var values: [String: String] = [:]
                                for p in params { values[p.name] = actionParams["\(key)#\(p.name)"] ?? "" }
                                state.onRunExtensionAction?(action.verb, values)
                                expandedAction = nil
                            }
                            .buttonStyle(.plain).font(monoBold).foregroundStyle(AssistantPhase.done.color)
                        }
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    // MARK: Theme

    private var themeCard: some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "paintpalette.fill").foregroundStyle(state.accent)
                Text("Code theme").font(monoBold).foregroundStyle(.white.opacity(0.85))
                Spacer()
                Picker("", selection: Binding(get: { manager.themeID ?? "" },
                                               set: { manager.themeID = $0.isEmpty ? nil : $0 })) {
                    Text("Dark Modern (built in)").tag("")
                    ForEach(manager.registry.themes, id: \.item.id) { owned in
                        Text("\(owned.item.name) · \(owned.extensionID)").tag(owned.item.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .font(mono)
                .frame(maxWidth: 260)
            }
            themePreview
        }
    }

    private var themePreview: some View {
        let theme = SyntaxHighlighter.theme
        let samples: [(SyntaxHighlighter.Token, String)] = [
            (.keyword, "func"), (.function, "greet"), (.punctuation, "("), (.variable, "name"), (.punctuation, ":"),
            (.type, "String"), (.punctuation, ") {"), (.control, "return"), (.string, "\"hi \\(name)\""),
            (.comment, "// \(theme.name)"), (.number, "42"),
        ]
        return HStack(spacing: 5) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Text(sample.1).foregroundStyle(Color(nsColor: theme.color(sample.0)))
            }
            Spacer()
        }
        .font(mono)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: theme.background)))
        .id(state.codeThemeGeneration)
    }

    // MARK: Marketplace

    private var marketplaceCard: some View {
        card {
            HStack(spacing: 8) {
                Image(systemName: "storefront.fill").foregroundStyle(state.accent)
                Text("Marketplace").font(monoBold).foregroundStyle(.white.opacity(0.85))
                if let fetched = marketplace.fetchedAt {
                    Text("\(marketplace.entries.count) listed · \(Self.clock.string(from: fetched))")
                        .font(mono).foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
                if marketplace.loading { ProgressView().controlSize(.mini) }
                iconButton("link", help: marketplace.catalogURL.absoluteString) { NSWorkspace.shared.open(marketplace.catalogURL) }
                iconButton("arrow.clockwise", help: "Refresh the catalog") { Task { await marketplace.refresh() } }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.4))
                TextField("Search themes, languages, actions…", text: $marketplace.query)
                    .textFieldStyle(.plain).font(mono)
                if !marketplace.query.isEmpty {
                    Button { marketplace.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.3)))
            if let error = marketplace.error {
                Text("Couldn't load the catalog: \(error)")
                    .font(mono).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if marketplace.filtered.isEmpty, !marketplace.loading {
                Text(marketplace.entries.isEmpty ? "The catalog is empty." : "Nothing matches “\(marketplace.query)”.")
                    .font(mono).foregroundStyle(.white.opacity(0.45))
            }
            ForEach(marketplace.filtered) { entry in
                marketplaceRow(entry)
            }
        }
    }

    private func marketplaceRow(_ entry: MarketplaceEntry) -> some View {
        let installed = manager.installed.first { $0.id == entry.id }
        let isUpdate = ExtensionMarketplace.isUpdate(entry, installed: installed)
        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.name).font(monoBold).foregroundStyle(.white.opacity(0.9))
                    Text(entry.version).font(mono).foregroundStyle(.white.opacity(0.35))
                    if let author = entry.author {
                        Text("by \(author)").font(mono).foregroundStyle(.white.opacity(0.35)).lineLimit(1)
                    }
                }
                if let description = entry.description {
                    Text(description).font(mono).foregroundStyle(.white.opacity(0.55)).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let tags = entry.tags, !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Text(tag).font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            if let homepage = entry.homepage, let url = URL(string: homepage) {
                iconButton("link", help: homepage) { NSWorkspace.shared.open(url) }
            }
            if installed != nil, !isUpdate {
                Label("Installed", systemImage: "checkmark")
                    .font(mono).foregroundStyle(.white.opacity(0.4))
            } else {
                Button(isUpdate ? "Update" : "Install") {
                    Task {
                        do {
                            if let installed, isUpdate { try manager.uninstall(installed) }
                            _ = try await manager.install(gitURL: entry.repo, ref: entry.ref)
                        } catch {
                            manager.lastMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.plain)
                .font(monoBold)
                .foregroundStyle(manager.busy == nil ? AssistantPhase.done.color : .white.opacity(0.3))
                .disabled(manager.busy != nil)
                .help("git clone \(entry.repo)")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
    }

    // MARK: Bits

    private func installFromURL() {
        let url = installURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        Task {
            do {
                _ = try await manager.install(gitURL: url)
                installURL = ""
            } catch {
                manager.lastMessage = error.localizedDescription
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
            )
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
}
