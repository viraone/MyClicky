import XCTest
@testable import MyClicky

final class GitHubIntegrationTests: XCTestCase {
    private var root: URL!
    private let gh = URL(fileURLWithPath: "/test/bin/gh")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekyGitHubTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testParsesWorktreeCountsAndTracking() throws {
        let status = try GitHubIntegrationService.parseStatus("""
        ## feature/github...origin/feature/github [ahead 2, behind 1]
        M  staged.swift
         M unstaged.swift
        MM both.swift
        ?? new.swift
        """)

        XCTAssertEqual(status.branch, "feature/github")
        XCTAssertEqual(status.staged, 2)
        XCTAssertEqual(status.unstaged, 2)
        XCTAssertEqual(status.untracked, 1)
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertFalse(status.isClean)
    }

    func testParsesInitialBranch() throws {
        let status = try GitHubIntegrationService.parseStatus("## No commits yet on main\n")
        XCTAssertEqual(status.branch, "main")
        XCTAssertTrue(status.isClean)
    }

    func testValidatesGitHubRemoteForms() {
        XCTAssertEqual(
            GitHubIntegrationService.parseGitHubRemote("https://github.com/viraone/MyClicky.git")?.slug,
            "viraone/MyClicky"
        )
        XCTAssertEqual(
            GitHubIntegrationService.parseGitHubRemote("git@github.com:viraone/MyClicky.git")?.slug,
            "viraone/MyClicky"
        )
        XCTAssertNil(GitHubIntegrationService.parseGitHubRemote("https://gitlab.com/viraone/MyClicky.git"))
        XCTAssertNil(GitHubIntegrationService.parseGitHubRemote("https://github.com/viraone/MyClicky/extra"))
    }

    func testRemoteDisplayStripsCredentialsAndQuery() {
        XCTAssertEqual(
            GitHubIntegrationService.remoteForDisplay("https://secret@github.com/viraone/MyClicky.git?token=also-secret"),
            "https://github.com/viraone/MyClicky.git"
        )
        XCTAssertEqual(
            GitHubIntegrationService.remoteForDisplay("git@github.com:viraone/MyClicky.git"),
            "github.com:viraone/MyClicky.git"
        )
    }

    func testRefreshReportsMissingGitHubCLIWithoutNetwork() async throws {
        let fake = FakeCommandRunner(responses: baseResponses(ghStatus: 127))
        let snapshot = try await GitHubIntegrationService(runner: fake, ghExecutable: nil).refresh(projectRoot: root)

        XCTAssertEqual(snapshot.repository?.slug, "viraone/MyClicky")
        XCTAssertEqual(snapshot.workingTree.branch, "main")
        XCTAssertEqual(snapshot.cli, .missing)
        XCTAssertTrue(snapshot.issues.isEmpty)
        let commands = await fake.commands
        XCTAssertFalse(commands.contains { $0.arguments.starts(with: ["issue", "list"]) })
    }

    func testRefreshLoadsSignedInAccountIssuesAndPullRequests() async throws {
        var responses = baseResponses()
        responses[FakeCommandRunner.key(["auth", "status", "--hostname", "github.com", "--json", "hosts"])] = [
            .success(#"{"hosts":{"github.com":[{"state":"success","active":true,"login":"octocat"}]}}"#),
        ]
        responses[FakeCommandRunner.key([
            "issue", "list", "--repo", "viraone/MyClicky", "--state", "open", "--limit", "10",
            "--json", "number,title,state,author,url",
        ])] = [.success(#"[{"number":12,"title":"Fix it","state":"OPEN","author":{"login":"hubot"},"url":"https://github.com/viraone/MyClicky/issues/12"}]"#)]
        responses[FakeCommandRunner.key([
            "pr", "list", "--repo", "viraone/MyClicky", "--state", "open", "--limit", "10",
            "--json", "number,title,state,author,url",
        ])] = [.success(#"[{"number":76,"title":"Code intelligence","state":"OPEN","author":{"login":"viraone"},"url":"https://github.com/viraone/MyClicky/pull/76"}]"#)]

        let snapshot = try await GitHubIntegrationService(runner: FakeCommandRunner(responses: responses), ghExecutable: gh)
            .refresh(projectRoot: root)

        XCTAssertEqual(snapshot.cli, .signedIn("octocat"))
        XCTAssertEqual(snapshot.issues.map(\.number), [12])
        XCTAssertEqual(snapshot.issues.first?.author, "hubot")
        XCTAssertEqual(snapshot.pullRequests.map(\.number), [76])
    }

    func testDirtyWorktreeBlocksSwitchWithoutRunningGitSwitch() async {
        var responses = baseResponses(status: "## main...origin/main\n M local.swift\n")
        responses[FakeCommandRunner.key(["auth", "status", "--hostname", "github.com", "--json", "hosts"])] = [
            CommandResult(status: 1, stdout: "", stderr: "not logged in"),
        ]
        let fake = FakeCommandRunner(responses: responses)
        let service = GitHubIntegrationService(runner: fake, ghExecutable: gh)

        do {
            try await service.switchBranch(GitBranch(name: "feature", kind: .local), projectRoot: root)
            XCTFail("Expected dirty worktree to block switching")
        } catch {
            XCTAssertEqual(error as? GitHubIntegrationError, .dirtyWorktree)
        }
        let commands = await fake.commands
        XCTAssertFalse(commands.contains { $0.executable.lastPathComponent == "git" && $0.arguments.first == "switch" })
    }

    func testRejectsUnlistedAndUnsafeBranches() async {
        let fake = FakeCommandRunner(responses: baseResponses())
        let service = GitHubIntegrationService(runner: fake, ghExecutable: gh)

        do {
            try await service.switchBranch(GitBranch(name: "--discard-changes", kind: .local), projectRoot: root)
            XCTFail("Expected invalid branch to be rejected")
        } catch {
            XCTAssertEqual(error as? GitHubIntegrationError, .invalidBranch)
        }
    }

    func testCleanWorktreeSwitchUsesArgumentArrayInProjectRoot() async throws {
        var responses = baseResponses()
        responses[FakeCommandRunner.key(["auth", "status", "--hostname", "github.com", "--json", "hosts"])] = [
            CommandResult(status: 1, stdout: "", stderr: "not logged in"),
        ]
        responses[FakeCommandRunner.key(["switch", "--", "feature"])] = [.success("")]
        let fake = FakeCommandRunner(responses: responses)

        try await GitHubIntegrationService(runner: fake, ghExecutable: gh)
            .switchBranch(GitBranch(name: "feature", kind: .local), projectRoot: root)

        let commands = await fake.commands
        let invocation = try XCTUnwrap(commands.last)
        XCTAssertEqual(invocation.executable.path, "/usr/bin/git")
        XCTAssertEqual(invocation.arguments, ["switch", "--", "feature"])
        XCTAssertEqual(invocation.currentDirectory, root)
        XCTAssertTrue(commands.allSatisfy { $0.currentDirectory == root })
    }

    func testBrowserSignInUsesGhWebFlowWithoutCredentials() async throws {
        let fake = FakeCommandRunner(responses: [
            FakeCommandRunner.key([
                "auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web",
            ]): [.success("")],
        ])

        try await GitHubIntegrationService(runner: fake, ghExecutable: gh).signIn(projectRoot: root)

        let commands = await fake.commands
        let invocation = try XCTUnwrap(commands.first)
        XCTAssertEqual(invocation.executable.path, gh.path)
        XCTAssertEqual(invocation.arguments, [
            "auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web",
        ])
        XCTAssertEqual(invocation.currentDirectory, root)
    }

    private func baseResponses(
        status: String = "## main...origin/main [ahead 1]\n",
        ghStatus: Int32 = 0
    ) -> [String: [CommandResult]] {
        [
            FakeCommandRunner.key(["rev-parse", "--show-toplevel"]): [.success(root.path + "\n")],
            FakeCommandRunner.key(["status", "--porcelain=v1", "--branch"]): [.success(status)],
            FakeCommandRunner.key(["remote", "get-url", "origin"]): [.success("https://github.com/viraone/MyClicky.git\n")],
            FakeCommandRunner.key(["for-each-ref", "--format=%(refname:short)", "refs/heads"]): [.success("feature\nmain\n")],
            FakeCommandRunner.key(["for-each-ref", "--format=%(refname:short)", "refs/remotes"]): [.success("origin/HEAD\norigin/main\n")],
            FakeCommandRunner.key(["--version"]): [
                CommandResult(status: ghStatus, stdout: ghStatus == 0 ? "gh version test\n" : "", stderr: ""),
            ],
        ]
    }
}

private actor FakeCommandRunner: CommandRunning {
    struct Invocation: Sendable {
        let executable: URL
        let arguments: [String]
        let currentDirectory: URL
    }

    private var responses: [String: [CommandResult]]
    private(set) var commands: [Invocation] = []

    init(responses: [String: [CommandResult]]) {
        self.responses = responses
    }

    func run(executable: URL, arguments: [String], currentDirectory: URL) async -> CommandResult {
        commands.append(Invocation(executable: executable, arguments: arguments, currentDirectory: currentDirectory))
        let key = Self.key(arguments)
        guard var queued = responses[key], !queued.isEmpty else {
            return CommandResult(status: 99, stdout: "", stderr: "Unexpected command: \(arguments)")
        }
        let result = queued.removeFirst()
        responses[key] = queued
        return result
    }

    static func key(_ arguments: [String]) -> String {
        arguments.joined(separator: "\u{1f}")
    }
}

private extension CommandResult {
    static func success(_ stdout: String) -> CommandResult {
        CommandResult(status: 0, stdout: stdout, stderr: "")
    }
}
