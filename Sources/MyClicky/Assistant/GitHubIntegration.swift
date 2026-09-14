import AppKit
import Foundation
import OSLog

private let githubLog = Logger(subsystem: "com.myclicky", category: "github")

struct CommandResult: Sendable, Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
}

protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String], currentDirectory: URL) async -> CommandResult
}

struct ProcessCommandRunner: CommandRunning {
    func run(executable: URL, arguments: [String], currentDirectory: URL) async -> CommandResult {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = currentDirectory

            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors

            do {
                try process.run()
            } catch {
                return CommandResult(
                    status: 127,
                    stdout: "",
                    stderr: error.localizedDescription
                )
            }
            let outputTask = Task.detached { output.fileHandleForReading.readDataToEndOfFile() }
            let errorTask = Task.detached { errors.fileHandleForReading.readDataToEndOfFile() }
            process.waitUntilExit()
            let stdout = String(decoding: await outputTask.value, as: UTF8.self)
            let stderr = String(decoding: await errorTask.value, as: UTF8.self)
            return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        }.value
    }
}

struct GitHubRepositoryIdentity: Sendable, Equatable {
    let owner: String
    let name: String
    let remoteURL: String

    var slug: String { "\(owner)/\(name)" }
}

struct GitWorkingTree: Sendable, Equatable {
    let branch: String
    let staged: Int
    let unstaged: Int
    let untracked: Int
    let ahead: Int
    let behind: Int

    var isClean: Bool { staged == 0 && unstaged == 0 && untracked == 0 }
}

struct GitBranch: Sendable, Equatable, Identifiable {
    enum Kind: Sendable { case local, remote }

    let name: String
    let kind: Kind
    var id: String { "\(kind)-\(name)" }
}

struct GitHubListItem: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable { case issue, pullRequest }

    let kind: Kind
    let number: Int
    let title: String
    let state: String
    let author: String
    let url: URL
    var id: String { "\(kind.rawValue)-\(number)" }
}

enum GitHubCLIState: Sendable, Equatable {
    case missing
    case unauthenticated(String)
    case signedIn(String)
}

struct GitHubProjectSnapshot: Sendable, Equatable {
    let repository: GitHubRepositoryIdentity?
    let remoteURL: String?
    let workingTree: GitWorkingTree
    let branches: [GitBranch]
    let cli: GitHubCLIState
    let issues: [GitHubListItem]
    let pullRequests: [GitHubListItem]
    let githubError: String?
}

enum GitHubIntegrationError: LocalizedError, Equatable {
    case invalidProject
    case notRepository(String)
    case projectIsSubdirectory(String)
    case commandFailed(String)
    case invalidBranch
    case dirtyWorktree

    var errorDescription: String? {
        switch self {
        case .invalidProject:
            return "The loaded project folder is no longer available."
        case .notRepository(let detail):
            return detail.isEmpty ? "The loaded project is not a Git repository." : detail
        case .projectIsSubdirectory(let root):
            return "Load the Git repository root to use GitHub controls (\(root))."
        case .commandFailed(let detail):
            return detail
        case .invalidBranch:
            return "That branch is not in the refreshed branch list."
        case .dirtyWorktree:
            return "Branch switching is blocked until staged, unstaged, and untracked changes are handled."
        }
    }
}

struct GitHubIntegrationService: Sendable {
    private let runner: any CommandRunning
    private let git = URL(fileURLWithPath: "/usr/bin/git")
    private let locateGH: @Sendable () -> URL?

    init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
        self.locateGH = { Self.findGitHubCLI() }
    }

    init(runner: any CommandRunning, ghExecutable: URL?) {
        self.runner = runner
        self.locateGH = { ghExecutable }
    }

    func refresh(projectRoot: URL) async throws -> GitHubProjectSnapshot {
        let root = try validatedProjectRoot(projectRoot)
        let topLevel = await runGit(["rev-parse", "--show-toplevel"], at: root)
        guard topLevel.status == 0 else {
            throw GitHubIntegrationError.notRepository(message(from: topLevel))
        }
        let repositoryRoot = URL(fileURLWithPath: topLevel.stdout.trimmed)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard repositoryRoot == root else {
            throw GitHubIntegrationError.projectIsSubdirectory(repositoryRoot.path)
        }

        async let statusResult = runGit(["status", "--porcelain=v1", "--branch"], at: root)
        async let remoteResult = runGit(["remote", "get-url", "origin"], at: root)
        async let localResult = runGit(["for-each-ref", "--format=%(refname:short)", "refs/heads"], at: root)
        async let remoteBranchesResult = runGit(["for-each-ref", "--format=%(refname:short)", "refs/remotes"], at: root)
        let gh = locateGH()
        async let ghVersion = runGitHub(["--version"], executable: gh, at: root)

        let (statusOutput, remoteOutput, localOutput, remoteBranchesOutput, versionOutput) =
            await (statusResult, remoteResult, localResult, remoteBranchesResult, ghVersion)
        guard statusOutput.status == 0 else {
            throw GitHubIntegrationError.commandFailed(message(from: statusOutput))
        }
        let workingTree = try Self.parseStatus(statusOutput.stdout)
        let rawRemote = remoteOutput.status == 0 ? remoteOutput.stdout.trimmed : nil
        let repository = rawRemote.flatMap(Self.parseGitHubRemote)
        let remoteDisplay = rawRemote.flatMap(Self.remoteForDisplay)
        let branches = Self.parseBranches(local: localOutput, remote: remoteBranchesOutput)

        guard versionOutput.status == 0, let gh else {
            return GitHubProjectSnapshot(repository: repository, remoteURL: remoteDisplay,
                                         workingTree: workingTree, branches: branches,
                                         cli: .missing, issues: [], pullRequests: [], githubError: nil)
        }

        let auth = await runner.run(
            executable: gh,
            arguments: ["auth", "status", "--hostname", "github.com", "--json", "hosts"],
            currentDirectory: root
        )
        guard auth.status == 0, let login = Self.parseLogin(auth.stdout) else {
            return GitHubProjectSnapshot(
                repository: repository,
                remoteURL: remoteDisplay,
                workingTree: workingTree,
                branches: branches,
                cli: .unauthenticated(message(from: auth, fallback: "Sign in to GitHub to load issues and pull requests.")),
                issues: [],
                pullRequests: [],
                githubError: nil
            )
        }
        guard let repository else {
            return GitHubProjectSnapshot(repository: nil, remoteURL: remoteDisplay,
                                         workingTree: workingTree, branches: branches,
                                         cli: .signedIn(login), issues: [], pullRequests: [], githubError: nil)
        }

        async let issuesResult = runner.run(
            executable: gh,
            arguments: ["issue", "list", "--repo", repository.slug, "--state", "open", "--limit", "10",
                        "--json", "number,title,state,author,url"],
            currentDirectory: root
        )
        async let pullsResult = runner.run(
            executable: gh,
            arguments: ["pr", "list", "--repo", repository.slug, "--state", "open", "--limit", "10",
                        "--json", "number,title,state,author,url"],
            currentDirectory: root
        )
        let (issueOutput, pullOutput) = await (issuesResult, pullsResult)
        let listError = [issueOutput, pullOutput]
            .filter { $0.status != 0 }
            .map { message(from: $0) }
            .joined(separator: "\n")

        return GitHubProjectSnapshot(
            repository: repository,
            remoteURL: remoteDisplay,
            workingTree: workingTree,
            branches: branches,
            cli: .signedIn(login),
            issues: issueOutput.status == 0 ? Self.parseItems(issueOutput.stdout, kind: .issue) : [],
            pullRequests: pullOutput.status == 0 ? Self.parseItems(pullOutput.stdout, kind: .pullRequest) : [],
            githubError: listError.isEmpty ? nil : listError
        )
    }

    func signIn(projectRoot: URL) async throws {
        let root = try validatedProjectRoot(projectRoot)
        guard let gh = locateGH() else {
            throw GitHubIntegrationError.commandFailed("GitHub CLI (gh) is not installed.")
        }
        let result = await runner.run(
            executable: gh,
            arguments: ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"],
            currentDirectory: root
        )
        guard result.status == 0 else {
            throw GitHubIntegrationError.commandFailed(message(from: result, fallback: "GitHub sign-in did not complete."))
        }
    }

    func switchBranch(_ branch: GitBranch, projectRoot: URL) async throws {
        let root = try validatedProjectRoot(projectRoot)
        let fresh = try await refresh(projectRoot: root)
        guard fresh.workingTree.isClean else { throw GitHubIntegrationError.dirtyWorktree }
        guard fresh.branches.contains(branch), Self.isSafeBranchName(branch.name) else {
            throw GitHubIntegrationError.invalidBranch
        }

        let arguments: [String]
        switch branch.kind {
        case .local:
            arguments = ["switch", "--", branch.name]
        case .remote:
            arguments = ["switch", "--track", "--", branch.name]
        }
        let result = await runGit(arguments, at: root)
        guard result.status == 0 else {
            throw GitHubIntegrationError.commandFailed(message(from: result, fallback: "Git could not switch branches."))
        }
    }

    private func validatedProjectRoot(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard root.isFileURL, FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw GitHubIntegrationError.invalidProject
        }
        return root
    }

    private func runGit(_ arguments: [String], at root: URL) async -> CommandResult {
        await runner.run(executable: git, arguments: arguments, currentDirectory: root)
    }

    private func runGitHub(_ arguments: [String], executable: URL?, at root: URL) async -> CommandResult {
        guard let executable else { return CommandResult(status: 127, stdout: "", stderr: "") }
        return await runner.run(executable: executable, arguments: arguments, currentDirectory: root)
    }

    private func message(from result: CommandResult, fallback: String = "The command failed.") -> String {
        let detail = result.stderr.trimmed.isEmpty ? result.stdout.trimmed : result.stderr.trimmed
        return detail.isEmpty ? fallback : detail
    }

    static func parseStatus(_ output: String) throws -> GitWorkingTree {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.first, header.hasPrefix("## ") else {
            throw GitHubIntegrationError.commandFailed("Git returned an unreadable worktree status.")
        }
        let description = String(header.dropFirst(3))
        let branchPart = description.components(separatedBy: "...").first ?? description
        let branch: String
        if branchPart.hasPrefix("No commits yet on ") {
            branch = String(branchPart.dropFirst("No commits yet on ".count))
        } else if branchPart.hasPrefix("Initial commit on ") {
            branch = String(branchPart.dropFirst("Initial commit on ".count))
        } else {
            branch = branchPart.components(separatedBy: " ").first ?? branchPart
        }
        var ahead = 0
        var behind = 0
        if let range = description.range(of: #"\[(.*?)\]"#, options: .regularExpression) {
            let tracking = String(description[range]).dropFirst().dropLast()
            for item in tracking.split(separator: ",") {
                let parts = item.trimmingCharacters(in: .whitespaces).split(separator: " ")
                guard parts.count == 2, let count = Int(parts[1]) else { continue }
                if parts[0] == "ahead" { ahead = count }
                if parts[0] == "behind" { behind = count }
            }
        }

        var staged = 0
        var unstaged = 0
        var untracked = 0
        for line in lines.dropFirst() where line.count >= 2 {
            let flags = Array(line.prefix(2))
            if flags == ["?", "?"] {
                untracked += 1
            } else {
                if flags[0] != " " { staged += 1 }
                if flags[1] != " " { unstaged += 1 }
            }
        }
        return GitWorkingTree(branch: branch, staged: staged, unstaged: unstaged, untracked: untracked,
                              ahead: ahead, behind: behind)
    }

    static func parseGitHubRemote(_ value: String) -> GitHubRepositoryIdentity? {
        let trimmed = value.trimmed
        let path: String
        if let url = URL(string: trimmed), let host = url.host?.lowercased(),
           host == "github.com" || host == "www.github.com" {
            path = url.path
        } else if trimmed.lowercased().hasPrefix("git@github.com:") {
            path = String(trimmed.dropFirst("git@github.com:".count))
        } else {
            return nil
        }
        let pieces = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.count == 2 else { return nil }
        let owner = String(pieces[0])
        let name = String(pieces[1]).replacingOccurrences(of: #"\.git$"#, with: "", options: .regularExpression)
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        guard let display = remoteForDisplay(trimmed) else { return nil }
        return GitHubRepositoryIdentity(owner: owner, name: name, remoteURL: display)
    }

    static func remoteForDisplay(_ value: String) -> String? {
        let trimmed = value.trimmed
        if var components = URLComponents(string: trimmed), components.host != nil {
            components.user = nil
            components.password = nil
            components.query = nil
            components.fragment = nil
            return components.string
        }
        if let at = trimmed.firstIndex(of: "@"), let colon = trimmed[at...].firstIndex(of: ":") {
            let host = trimmed[trimmed.index(after: at)..<colon]
            let path = trimmed[trimmed.index(after: colon)...]
            guard !host.isEmpty, !path.isEmpty else { return nil }
            return "\(host):\(path)"
        }
        guard !trimmed.isEmpty, !trimmed.contains("?"), !trimmed.contains("#") else { return nil }
        return trimmed
    }

    static func parseLogin(_ output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hosts = object["hosts"] as? [String: Any],
              let accounts = hosts["github.com"] as? [[String: Any]] else { return nil }
        return accounts.first {
            ($0["active"] as? Bool) == true && ($0["state"] as? String) == "success"
        }?["login"] as? String
    }

    static func parseItems(_ output: String, kind: GitHubListItem.Kind) -> [GitHubListItem] {
        guard let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let number = row["number"] as? Int,
                  let title = row["title"] as? String,
                  let state = row["state"] as? String,
                  let urlString = row["url"] as? String,
                  let url = URL(string: urlString),
                  url.scheme == "https", url.host?.lowercased() == "github.com" else { return nil }
            let author = (row["author"] as? [String: Any])?["login"] as? String ?? "unknown"
            return GitHubListItem(kind: kind, number: number, title: title, state: state,
                                  author: author, url: url)
        }
    }

    static func parseBranches(local: CommandResult, remote: CommandResult) -> [GitBranch] {
        var branches = local.status == 0
            ? local.stdout.lines.map { GitBranch(name: $0, kind: .local) }
            : []
        if remote.status == 0 {
            branches += remote.stdout.lines
                .filter { !$0.hasSuffix("/HEAD") }
                .map { GitBranch(name: $0, kind: .remote) }
        }
        return branches.sorted {
            if $0.kind != $1.kind { return $0.kind == .local }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func isSafeBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(".."), !name.contains("@{"),
              !name.hasSuffix("."), !name.hasSuffix("/"), !name.contains("//") else { return false }
        return name.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-._/".unicodeScalars.contains($0)
        }
    }

    private static func findGitHubCLI() -> URL? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL.resolvingSymlinksInPath()
            }
        }
        return nil
    }
}

@MainActor
final class GitHubIntegrationModel: ObservableObject {
    @Published private(set) var snapshot: GitHubProjectSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var signingIn = false
    @Published private(set) var switchingBranch: String?
    @Published private(set) var error: String?
    @Published var expanded = false

    private let service: GitHubIntegrationService
    private let openURL: (URL) -> Void
    private var projectRoot: URL?
    private var generation = 0

    init(
        service: GitHubIntegrationService = GitHubIntegrationService(),
        openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.service = service
        self.openURL = openURL
    }

    func load(projectRoot: URL) {
        generation += 1
        self.projectRoot = projectRoot
        snapshot = nil
        error = nil
        refresh(generation: generation)
    }

    func reset() {
        generation += 1
        projectRoot = nil
        snapshot = nil
        loading = false
        signingIn = false
        switchingBranch = nil
        error = nil
        expanded = false
    }

    func refresh() {
        refresh(generation: generation)
    }

    func signIn() {
        guard let projectRoot, !signingIn else { return }
        signingIn = true
        error = nil
        let expectedGeneration = generation
        Task {
            do {
                try await service.signIn(projectRoot: projectRoot)
                guard expectedGeneration == generation else { return }
                signingIn = false
                refresh(generation: expectedGeneration)
            } catch {
                guard expectedGeneration == generation else { return }
                signingIn = false
                self.error = error.localizedDescription
                githubLog.error("GitHub sign-in failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func switchBranch(_ branch: GitBranch) {
        guard let projectRoot, switchingBranch == nil else { return }
        guard snapshot?.workingTree.isClean == true else {
            error = GitHubIntegrationError.dirtyWorktree.localizedDescription
            return
        }
        switchingBranch = branch.name
        error = nil
        let expectedGeneration = generation
        Task {
            do {
                try await service.switchBranch(branch, projectRoot: projectRoot)
                guard expectedGeneration == generation else { return }
                switchingBranch = nil
                refresh(generation: expectedGeneration)
            } catch {
                guard expectedGeneration == generation else { return }
                switchingBranch = nil
                self.error = error.localizedDescription
                githubLog.error("Git branch switch failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func open(_ item: GitHubListItem) {
        guard item.url.scheme == "https", item.url.host?.lowercased() == "github.com" else { return }
        openURL(item.url)
    }

    private func refresh(generation expectedGeneration: Int) {
        guard let projectRoot, !loading else { return }
        loading = true
        error = nil
        Task {
            do {
                let refreshed = try await service.refresh(projectRoot: projectRoot)
                guard expectedGeneration == generation else { return }
                snapshot = refreshed
                loading = false
            } catch {
                guard expectedGeneration == generation else { return }
                snapshot = nil
                loading = false
                self.error = error.localizedDescription
                githubLog.error("GitHub refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var lines: [String] {
        split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
