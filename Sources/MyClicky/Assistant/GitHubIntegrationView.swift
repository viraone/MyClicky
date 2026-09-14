import SwiftUI

struct GitHubIntegrationView: View {
    @ObservedObject var model: GitHubIntegrationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(model.expanded ? 90 : 0))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 14, height: 18)
                }
                .buttonStyle(.plain)

                Image(systemName: "network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.78, blue: 1))
                Text("GitHub")
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text(summary)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if model.loading || model.signingIn || model.switchingBranch != nil {
                    ProgressView().controlSize(.mini)
                }
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .disabled(model.loading || model.signingIn || model.switchingBranch != nil)
                .help("Refresh Git, GitHub authentication, issues, and pull requests")
            }

            if model.expanded {
                expandedContent
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private var summary: String {
        if model.loading, model.snapshot == nil { return "Refreshing…" }
        if let error = model.error { return error }
        guard let snapshot = model.snapshot else { return "Not loaded" }
        let state = snapshot.workingTree
        let dirty = state.isClean ? "clean" : "\(state.staged)S \(state.unstaged)U \(state.untracked)?"
        return "\(snapshot.repository?.slug ?? snapshot.remoteURL ?? "local Git") · \(state.branch) · \(dirty)"
    }

    @ViewBuilder
    private var expandedContent: some View {
        if let error = model.error, model.snapshot == nil {
            statusLine(error, icon: "exclamationmark.triangle.fill", color: .orange)
        } else if let snapshot = model.snapshot {
            repositorySection(snapshot)
            branchSection(snapshot)
            cliSection(snapshot)
            if case .signedIn = snapshot.cli, snapshot.repository != nil {
                listSection("Open issues", items: snapshot.issues, empty: "No open issues.")
                listSection("Open pull requests", items: snapshot.pullRequests, empty: "No open pull requests.")
                if let error = snapshot.githubError {
                    statusLine(error, icon: "wifi.exclamationmark", color: .orange)
                }
            }
            if let error = model.error {
                statusLine(error, icon: "exclamationmark.triangle.fill", color: .orange)
            }
        } else {
            statusLine("Loading Git and GitHub state…", icon: "arrow.clockwise", color: .white.opacity(0.55))
        }
    }

    private func repositorySection(_ snapshot: GitHubProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let repository = snapshot.repository {
                detailRow("Repository", value: repository.slug)
                detailRow("Origin", value: repository.remoteURL)
            } else if let remote = snapshot.remoteURL {
                detailRow("Origin", value: remote)
                statusLine("This origin is not a GitHub repository.", icon: "exclamationmark.triangle.fill", color: .orange)
            } else {
                statusLine("This Git repository has no origin remote.", icon: "externaldrive.badge.questionmark", color: .orange)
            }
            let tree = snapshot.workingTree
            detailRow("Worktree", value: tree.isClean
                      ? "Clean"
                      : "\(tree.staged) staged · \(tree.unstaged) unstaged · \(tree.untracked) untracked")
            detailRow("Tracking", value: "↑\(tree.ahead) ahead · ↓\(tree.behind) behind")
        }
    }

    private func branchSection(_ snapshot: GitHubProjectSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            let localCount = snapshot.branches.filter { $0.kind == .local }.count
            let remoteCount = snapshot.branches.filter { $0.kind == .remote }.count
            detailRow("Branches", value: "\(localCount) local · \(remoteCount) remote")
            HStack(spacing: 8) {
                Text("Branch")
                    .foregroundStyle(.white.opacity(0.45))
                Text(snapshot.workingTree.branch)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Menu {
                    let local = snapshot.branches.filter { $0.kind == .local }
                    let remote = snapshot.branches.filter { $0.kind == .remote }
                    Section("Local") {
                        ForEach(local) { branch in
                            Button(branch.name) { model.switchBranch(branch) }
                                .disabled(branch.name == snapshot.workingTree.branch)
                        }
                    }
                    Section("Remote") {
                        ForEach(remote) { branch in
                            Button(branch.name) { model.switchBranch(branch) }
                        }
                    }
                } label: {
                    Text(model.switchingBranch.map { "Switching to \($0)…" } ?? "Switch…")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!snapshot.workingTree.isClean || model.switchingBranch != nil)
            }
            .font(.system(size: 12, design: .monospaced))
            if !snapshot.workingTree.isClean {
                Text("Switching is blocked while the worktree has changes; Peeky never discards or stashes them.")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.orange.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func cliSection(_ snapshot: GitHubProjectSnapshot) -> some View {
        switch snapshot.cli {
        case .missing:
            statusLine("GitHub CLI (gh) is not installed.", icon: "xmark.circle.fill", color: .orange)
        case .unauthenticated(let detail):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                statusLine(detail, icon: "person.crop.circle.badge.exclamationmark", color: .orange)
                Spacer(minLength: 4)
                Button(model.signingIn ? "Signing in…" : "Sign in in browser") { model.signIn() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .disabled(model.signingIn)
            }
        case .signedIn(let login):
            statusLine("Signed in as @\(login)", icon: "checkmark.circle.fill",
                       color: Color(red: 0.4, green: 0.85, blue: 0.62))
        }
    }

    private func listSection(_ title: String, items: [GitHubListItem], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
            if items.isEmpty {
                Text(empty)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ForEach(items.prefix(5)) { item in
                    Button { model.open(item) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(item.state.lowercased())
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.62))
                            Text("#\(item.number)")
                                .fontWeight(.bold)
                                .foregroundStyle(Color(red: 0.55, green: 0.78, blue: 1))
                            Text(item.title)
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("@\(item.author)")
                                .foregroundStyle(.white.opacity(0.4))
                                .lineLimit(1)
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(item.kind == .issue ? "issue" : "pull request") #\(item.number) in your browser")
                }
            }
        }
    }

    private func detailRow(_ name: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 66, alignment: .leading)
            Text(value)
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5, design: .monospaced))
    }

    private func statusLine(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
