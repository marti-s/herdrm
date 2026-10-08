import AppKit
import HerdrKit
import SwiftUI
import XCTest
@testable import herdrm

@MainActor
final class AtomicAgentTests: XCTestCase {
    func testAtomicActivityRequiresSeparatelyStyledOrBareGlyphOnVisibleScreen() {
        XCTAssertTrue(AtomicActivityDetector.isWorking(in: "ready\n∀"))
        XCTAssertTrue(AtomicActivityDetector.isWorking(in: "∀\n" + Array(repeating: "other", count: 8).joined(separator: "\n")))
        XCTAssertFalse(AtomicActivityDetector.isWorking(in: "  ∀ working\nwaiting"))
        XCTAssertFalse(AtomicActivityDetector.isWorking(in: "∀x"))
        XCTAssertFalse(AtomicActivityDetector.isWorking(in: "plain text"))
    }

    func testRealShapedCRLFPaneReadsFindWorkingLoaderBeyondFooterAndIgnoreIdleScreen() {
        XCTAssertEqual(AtomicPaneReadFixture.working.components(separatedBy: "\r\n").count, 69)
        XCTAssertTrue(AtomicPaneReadFixture.working.contains("Tasks  2 background tasks running"))
        XCTAssertTrue(AtomicPaneReadFixture.working.contains("BACKGROUND  8 runs"))
        XCTAssertTrue(AtomicActivityDetector.isWorking(in: AtomicPaneReadFixture.working))
        XCTAssertFalse(AtomicActivityDetector.isWorking(in: AtomicPaneReadFixture.idle))
    }

    func testPersistentYieldTranscriptDoesNotMakeIdlePaneWorking() {
        let yieldRows = AtomicPaneReadFixture.yieldRows
        var rows = AtomicPaneReadFixture.idle.components(separatedBy: "\r\n")
        rows.insert(contentsOf: yieldRows, at: 10) // Far above the editor.
        XCTAssertFalse(AtomicActivityDetector.isWorking(in: rows.joined(separator: "\r\n")))
        rows = AtomicPaneReadFixture.idle.components(separatedBy: "\r\n")
        let editor = rows.firstIndex { $0.contains("❯ ") }!
        rows.insert(contentsOf: yieldRows, at: editor - 2) // Immediately above editor spacers.
        XCTAssertFalse(AtomicActivityDetector.isWorking(in: rows.joined(separator: "\r\n")))
    }

    func testAtomicActivityRecognizesStyledLoaderInStatusAndEditorBorder() {
        let coloredWorking = "\u{1B}[0m\u{1B}[38;2;102;102;102m∀\u{1B}[0m \u{1B}[0m…Kerfuffling..."
        let borderWorking = "\u{1B}[38;2;178;148;187m── \u{1B}[38;2;102;102;102m∀\u{1B}[39m Skedaddling... ───"
        let boldWorking = "\u{1B}[1m\u{1B}[38;2;102;102;102m∀\u{1B}[39m\u{1B}[22m Skedaddling..."
        let linkedWorking = "\u{1B}]8;;https://example.com\u{7}∀\u{1B}]8;;\u{1B}\\ working"
        let taskRow = "\u{1B}[38;2;102;102;102m∀\u{1B}[39m running task"
        XCTAssertTrue(AtomicActivityDetector.isWorking(in: coloredWorking))
        XCTAssertTrue(AtomicActivityDetector.isWorking(in: borderWorking))
        XCTAssertTrue(AtomicActivityDetector.isWorking(in: boldWorking))
        XCTAssertTrue(AtomicActivityDetector.isWorking(in: linkedWorking))
        XCTAssertTrue(AtomicActivityDetector.isWorking(in: taskRow))
        XCTAssertFalse(AtomicActivityDetector.isWorking(in: "\u{1B}[38;2;138;190;183m∀ Continued in background\u{1B}[39m"))
        XCTAssertFalse(AtomicActivityDetector.isWorking(in: "\u{1B}[38;2;102;102;102m∀x\u{1B}[0m"))
    }

    func testPiAgentWithAtomicNameOrTabLabelDisplaysAsAtomic() throws {
        let model = AppModel()
        model.devices = [.local]
        var session = DeviceSessionState()
        session.agents = try [
            agent(name: "atomic", paneID: "pane-one"),
            agent(name: "atomic-abcd", paneID: "pane-two"),
            agent(name: "Pi Agent", paneID: "pane-three"),
            agent(name: "Pi Agent", paneID: "pane-four"),
        ]
        session.tabs = try ["plain", "plain", "atomic-abcd", "plain"].enumerated().map { index, label in
            try decode(TabInfo.self, ["tab_id": "tab-\(index)", "workspace_id": "ws-0", "label": label])
        }
        model.sessions[Device.local.id] = session
        XCTAssertEqual(model.visibleAgents.map(model.agentDisplayKind(for:)), ["atomic", "atomic", "atomic", "pi"])
    }

    func testNonPiAgentWithAtomicTabLabelKeepsItsOwnKind() throws {
        let model = AppModel()
        model.devices = [.local]
        var session = DeviceSessionState()
        session.agents = [try agent(name: "Claude", paneID: "pane-one", kind: "claude")]
        session.tabs = [try decode(TabInfo.self, ["tab_id": "tab-0", "workspace_id": "ws-0", "label": "atomic-refactor"])]
        model.sessions[Device.local.id] = session
        XCTAssertEqual(model.visibleAgents.map(model.agentDisplayKind(for:)), ["claude"])
    }

    func testLaunchedAtomicPaneReusedByClaudeKeepsClaudeKind() throws {
        let model = AppModel()
        model.devices = [.local]
        var session = DeviceSessionState()
        session.agents = [try agent(name: "Claude", paneID: "pane-one", kind: "claude")]
        model.sessions[Device.local.id] = session
        model.atomicPaneRefs.insert(PaneRef(deviceID: Device.local.id, paneID: "pane-one"))
        XCTAssertEqual(model.visibleAgents.map(model.agentDisplayKind(for:)), ["claude"])
    }

    func testBlockedAtomicStatusIsNotMaskedByWorkingPane() throws {
        let model = AppModel()
        let entry = AppModel.AgentEntry(
            device: .local, agent: try agent(name: "Atomic", paneID: "pane-one").updatingStatus(.blocked), tabLabel: "atomic"
        )
        model.atomicWorkingPanes.insert(entry.ref)
        XCTAssertEqual(model.agentDisplayStatus(for: entry), .blocked)
    }

    func testAtomicStatusUsesRealLoaderButNotIdleYieldTranscript() throws {
        let model = AppModel()
        let entry = AppModel.AgentEntry(
            device: .local, agent: try agent(name: "Atomic", paneID: "pane-one").updatingStatus(.idle), tabLabel: "atomic"
        )
        var rows = AtomicPaneReadFixture.idle.components(separatedBy: "\r\n")
        rows.insert(contentsOf: AtomicPaneReadFixture.yieldRows, at: 10)
        if AtomicActivityDetector.isWorking(in: rows.joined(separator: "\r\n")) {
            model.atomicWorkingPanes.insert(entry.ref)
        }
        XCTAssertEqual(model.agentDisplayStatus(for: entry), .idle)
        if AtomicActivityDetector.isWorking(in: AtomicPaneReadFixture.working) {
            model.atomicWorkingPanes.insert(entry.ref)
        }
        XCTAssertEqual(model.agentDisplayStatus(for: entry), .working)
    }

    func testAtomicUsesPiBrandIcon() {
        XCTAssertEqual(BrandIconLoader.agentIcon(for: "atomic"), BrandIconLoader.agentIcon(for: "pi"))
        XCTAssertNotNil(BrandIconLoader.agentIcon(for: "atomic"))
    }

    func testLocalAtomicInsertedAfterInstalledPi() {
        let catalog = AppModel.insertingAtomic(
            kinds: ["claude", "pi", "codex"], piAdvertised: true,
            atomicPath: "/bin/atomic", isRemote: false, paths: ["pi": "/bin/pi"]
        )
        XCTAssertEqual(catalog.kinds, ["claude", "pi", "atomic", "codex"])
        XCTAssertEqual(catalog.paths, ["pi": "/bin/pi", "atomic": "/bin/atomic"])
    }

    func testLocalAtomicAppendedWhenPiAdvertisedButNotInstalled() {
        let catalog = AppModel.insertingAtomic(
            kinds: ["claude"], piAdvertised: true,
            atomicPath: "/bin/atomic", isRemote: false, paths: ["claude": "/bin/claude"]
        )
        XCTAssertEqual(catalog.kinds, ["claude", "atomic"])
        XCTAssertEqual(catalog.paths["atomic"], "/bin/atomic")
    }

    func testLocalCatalogDoesNotDuplicateAdvertisedAtomic() {
        let catalog = AppModel.insertingAtomic(
            kinds: ["pi", "atomic"], piAdvertised: true,
            atomicPath: "/bin/atomic", isRemote: false, paths: ["pi": "/bin/pi", "atomic": "/bin/atomic"]
        )
        XCTAssertEqual(catalog.kinds, ["pi", "atomic"])
    }

    func testLocalCatalogUnchangedWithoutAtomicBinary() {
        let catalog = AppModel.insertingAtomic(
            kinds: ["pi"], piAdvertised: true,
            atomicPath: nil, isRemote: false, paths: ["pi": "/bin/pi"]
        )
        XCTAssertEqual(catalog.kinds, ["pi"])
        XCTAssertEqual(catalog.paths, ["pi": "/bin/pi"])
    }

    func testRemoteAtomicInsertedAfterPi() {
        let catalog = AppModel.insertingAtomic(
            kinds: ["claude", "pi", "codex"], piAdvertised: true,
            atomicPath: "atomic", isRemote: true, paths: [:]
        )
        XCTAssertEqual(catalog.kinds, ["claude", "pi", "atomic", "codex"])
        XCTAssertEqual(catalog.paths, ["atomic": "atomic"])
    }

    func testRemoteCatalogUnchangedWithoutPi() {
        let catalog = AppModel.insertingAtomic(
            kinds: ["claude"], piAdvertised: false,
            atomicPath: "atomic", isRemote: true, paths: [:]
        )
        XCTAssertEqual(catalog.kinds, ["claude"])
        XCTAssertTrue(catalog.paths.isEmpty)
    }

    func testRemoteCatalogUnchangedWhenAtomicAlreadyListed() {
        let catalog = AppModel.insertingAtomic(
            kinds: ["atomic", "pi"], piAdvertised: true,
            atomicPath: "atomic", isRemote: true, paths: [:]
        )
        XCTAssertEqual(catalog.kinds, ["atomic", "pi"])
        XCTAssertTrue(catalog.paths.isEmpty)
    }
    private func agent(name: String, paneID: String, kind: String = "pi") throws -> AgentInfo {
        let index = ["pane-one": 0, "pane-two": 1, "pane-three": 2, "pane-four": 3][paneID]!
        return try decode(AgentInfo.self, ["agent": kind, "name": name, "workspace_id": "ws-0", "tab_id": "tab-\(index)", "pane_id": paneID])
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: json))
    }
}

// Sanitized real 69-row pane.read screens; ANSI sequences and CRLF row boundaries are unchanged.
// Visible transcript, paths, titles, run identifiers and footer values are replaced with x.
private enum AtomicPaneReadFixture {
    // Rows emitted by Atomic's bash renderer in /tmp/herdrm-risk/yield-rows.ansi.
    static let yieldRows = [
        "\u{1B}[48;2;40;50;40m                                                                                                    \u{1B}[49m",
        "\u{1B}[48;2;40;50;40m \u{1B}[38;2;138;190;183m∀ Continued in background\u{1B}[39m                                                                          \u{1B}[49m",
        "\u{1B}[48;2;40;50;40m \u{1B}[38;2;102;102;102m/tasks to inspect output or stop\u{1B}[39m                                                                   \u{1B}[49m",
        "\u{1B}[48;2;40;50;40m                                                                                                    \u{1B}[49m",
    ]
    static let working = [
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;203;166;247m♥ \u{1B}[0m\u{1B}[1m\u{1B}[38;2;205;214;244mxxxxxxxx \"xxxxxxxx-xxxx\" xx xxxxx xxxxxxx\u{1B}[0m                                                                                                                          \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;127;132;156mxxxxxxxx \u{1B}[0m \u{1B}[0m\u{1B}[38;2;205;214;244mxxxxxxxx-xxxx\u{1B}[0m                                                                                                                                              \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;127;132;156mxxx      \u{1B}[0m \u{1B}[0m\u{1B}[38;2;205;214;244mxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\u{1B}[0m                                                                                                                       \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;127;132;156mxxxxxxx  \u{1B}[0m \u{1B}[0m\u{1B}[38;2;166;173;200mxx-xxxxxx\u{1B}[0m                                                                                                                                                  \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;127;132;156mxxxxxxx  \u{1B}[0m \u{1B}[0m\u{1B}[38;2;166;173;200mxx xxx\u{1B}[0m                                                                                                                                                     \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;137;180;250m▸ \u{1B}[0m\u{1B}[38;2;166;173;200m/xxxxxxxx xxxxxx xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\u{1B}[0m                                                                                                              \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m╰──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\u{1B}[0m",
        "",
        " \u{1B}[0m\u{1B}[3m\u{1B}[38;2;128;128;128mx xxxxxx xxxx xxxxx xxx xxxxxx xx xxx xx xxxx xxxxx xxxxxx xxx xxx xxxxx-xxxxxxx xxxxxx, xxxxx xxxxx xxx xxxxx xxxxxxx.\u{1B}[0m                                                ",
        "",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m xxxxxxxx xxxxxx \u{1B}[0m\u{1B}[38;2;102;102;102m\u{1B}[48;2;40;50;40mxxxx-x-x-x\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                             \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m xxxxxx · xxxxxxxxx                                                                                                                                                     \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;102;102;102m\u{1B}[48;2;40;50;40mxxxxxx-xxxxx/xxx-x-xxx · xxxxxxxx xxxx\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                 \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40mxxxxx xxx xx xxxxxxxxx-xxxx xxxxx xxx xxx xxxxx xxxx-xxxxxxx xxxxxxxx xxxxxxx (xxxx x). xxxx/xxx xxxx xxxx.\u{1B}[0m\u{1B}[48;2;40;50;40m                                                            \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;102;102;102m\u{1B}[48;2;40;50;40m/xxxxx xx xxxxxxx xxxxxx xxx xxxxxx xxxxx\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                              \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m xxxxxxxx xxxxxx \u{1B}[0m\u{1B}[38;2;102;102;102m\u{1B}[48;2;40;50;40mxxxx-x-x-xx\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                            \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m xxxxxx · xxxxxxx                                                                                                                                                       \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;102;102;102m\u{1B}[48;2;40;50;40mxxxxxx-xxxxx/xxx-x-xxx · xxxxxxxx xxxx\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                 \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40mxxx xxxxxxxxxx xxxxxxxxxx xxxxx-xxxxxxxx xxx xxx xxxxx xxxx-xxxxxxxx xxxxxxx: xx→xx, xxxx xx→xx. xxx xxxx xx xxxxx xxxxxx xxxxxxxx (x xxxxx xxxxx): xxx xxxx xxxxx xx  \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40mxxx xxxxxxxxxx xxxxxxx xxxx x xxxxxxxx xxxxxxx (xx xx xx xxx), xxxxxxx xx xxxxxxxx.\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                    \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;102;102;102m\u{1B}[48;2;40;50;40m/xxxxx xx xxxxxxx xxxxxx xxx xxxxxx xxxxx\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                              \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "",
        " \u{1B}[0m\u{1B}[3m\u{1B}[38;2;128;128;128mxxxx xxx xx xxxxx xxxxxxxx, x'x xxxxx xx xxxxxx xxx xxxxxxxx xxxxxxxxx xxxx xxxx xxxxxx=xxxx xxx xxxxxxx_xxxx xxxx, xxxxxx x'x xxxxxxxx xxxxxxx xx xxxx xx-xxx xxx     \u{1B}[0m",
        " \u{1B}[0m\u{1B}[3m\u{1B}[38;2;128;128;128mxxxx xxxxxxxxxx xxxxx xxxxx, xxxxx xxxxx xxxx xxxxxxxxxxx xxxxxxx xxxx xxxxx xxx xxxx, xxxxxxx xx xxx xx xxxxxxx xxx xxxxxxx xxxxxx.\u{1B}[0m                                   ",
        "                                                                                                                                                                        ",
        " \u{1B}[0m\u{1B}[3m\u{1B}[38;2;128;128;128mx'x xxxx xxxxxxxx xxxx xxx xxxxxxx xxxxxx xxx xxxxx xxx xxxxxxxxxxx xxxxxx/xxxxxx xxxxxx xxxx xxxx xx xx xxxxxx xx x xx-x xxxxx, xxx xxxx xxxxxxx x xxxxxxxxxxx:       \u{1B}[0m",
        " \u{1B}[0m\u{1B}[3m\u{1B}[38;2;128;128;128mxxxxxxx xxxx xxx xxxxxxx xxx xxxx, xxxxx xxxxx xxxx xx xxxxxxx xx-xxxxxxx xxx xxxx xx xxx xxx xxxx, xxx xxx xxxxxx xxxxx'x xxxxxx xx xx xxxxxxxx xx xxxxxxx xxxx xxxx  \u{1B}[0m",
        " \u{1B}[0m\u{1B}[3m\u{1B}[38;2;128;128;128mxxxxx xxxx — xx x xxxx xx xxxxxx xxx xxx xxxxx xxxxxxxxxx xx xxxxx xx xxxxxxxx xxxx xx xxxx xx-xxxx.\u{1B}[0m                                                                   ",
        "",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                                                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m $ xx /xxxxx/xxxxxxxxxxxxxxx/xxx/xxxxx-xxxxx-xxxxxxxxx/xxxx-xxxxxxxx/xxxxxxxxxxx-xx; xx xxxx/xxxxxxxx/ | xxxx -x xxxxxxx; xxxx -x -x 'xxxxxx\\|xxxxxxxxxxx\\|xxx\\|<'      \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m xxxx/xxxxxxxx/xx-xxxxxxx-xxxx-xxxxxxx-xxxxxxxxx.xx x>/xxx/xxxx | xxxx -x | xxx -xx-xxx; xxxx -x -x 'xxx\\|xxxxxxxxxxx\\|<xxxxxx\\|<xxxxxx\\|xxxxxx'                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m xxxx/xxxxxxxx/xx-xxxxxxx-xxxx-xxxxxxx-xxxxxxxxx.xx | xxxx -x | xxx -xx-xxx                                                                                             \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                                                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;40;50m... (x xxxxxxx xxxxx, \u{1B}[0m\u{1B}[38;2;102;102;102m\u{1B}[48;2;40;40;50mxxxx+x\u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;40;50m xxxxxx)\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                   \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;40;50mxx-xxxxxxx-xxxx-xxxxxxx-xxxxxxxxx.xx\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                   \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;40;50mxx-xxxxxxxxxx-x-xxxxxxx.xx\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                             \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;40;50mxx-xxxxxxx-xxxxxxxxx.xx\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                                \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;40;50mxx-xxxxxxx-xxxx-xxxxxxx-xxxxxxxxx.xx\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                   \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;40;50mxx-xxxxxxx-xxxx-xxxxxxx-xxxxxxxxx.xx\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                   \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                                                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;40;50mxxxxxxx x.xx\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                                           \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;40;50m                                                                                                                                                                        \u{1B}[0m",
        "",
        " \u{1B}[0m\u{1B}[38;2;102;102;102m∀\u{1B}[0m \u{1B}[0m\u{1B}[38;2;128;128;128mSkedaddling...\u{1B}[0m                                                                                                                                                       ",
        "",
        "                                                                                            \u{1B}[0m\u{1B}[38;2;102;102;102m↑\u{1B}[0m\u{1B}[38;2;128;128;128mxxx\u{1B}[0m\u{1B}[38;2;102;102;102m • ↓\u{1B}[0m\u{1B}[38;2;128;128;128mx.xx\u{1B}[0m\u{1B}[38;2;102;102;102m • x\u{1B}[0m\u{1B}[38;2;128;128;128mxxxxx\u{1B}[0m\u{1B}[38;2;102;102;102m • x\u{1B}[0m\u{1B}[38;2;128;128;128mx.xx\u{1B}[0m\u{1B}[38;2;102;102;102m • xx\u{1B}[0m\u{1B}[38;2;128;128;128mxx.x%\u{1B}[0m\u{1B}[38;2;102;102;102m • \u{1B}[0m\u{1B}[38;2;128;128;128m$xxx.xxx\u{1B}[0m \u{1B}[0m\u{1B}[38;2;102;102;102m(xxx) • \u{1B}[0m\u{1B}[38;2;128;128;128mxx.x%/x.xx (xxxx)\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;178;148;187m────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\u{1B}[0m",
        "❯ \u{1B}[0m\u{1B}[7m \u{1B}[0m                                                                                                                                                                     ",
        "\u{1B}[0m\u{1B}[38;2;178;148;187m────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;128;128;128mesc to interrupt\u{1B}[0m",
        "",
        "\u{1B}[0m\u{1B}[38;2;138;190;183mTasks  2 background tasks running · /xxxxx\u{1B}[0m",
        "",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m╭ BACKGROUND  8 runs  \u{1B}[0m\u{1B}[38;2;249;226;175m● 8 running\u{1B}[0m\u{1B}[38;2;108;112;134m ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\u{1B}[0m\u{1B}[38;5;7m┃\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m   \u{1B}[0m\u{1B}[38;2;249;226;175m●\u{1B}[0m  \u{1B}[0m\u{1B}[38;2;137;180;250mxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\u{1B}[0m                                                                                                                            \u{1B}[0m\u{1B}[38;5;7m┃\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m     \u{1B}[0m\u{1B}[1m\u{1B}[38;2;205;214;244mxxxxxxxx-xxxx\u{1B}[0m · \u{1B}[0m\u{1B}[38;2;166;173;200mxxxxxx · x/x · xxx xxx\u{1B}[0m                                                                                                                           \u{1B}[0m\u{1B}[38;5;7m┃\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m                                                                                                                                                                      \u{1B}[0m\u{1B}[38;5;7m┃\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m   \u{1B}[0m\u{1B}[38;2;249;226;175m●\u{1B}[0m  \u{1B}[0m\u{1B}[38;2;137;180;250mxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\u{1B}[0m                                                                                                                            \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m     \u{1B}[0m\u{1B}[1m\u{1B}[38;2;205;214;244mxxxxxxxx-xxxx\u{1B}[0m · \u{1B}[0m\u{1B}[38;2;166;173;200mxxxxxx · x/x · xxx xxx\u{1B}[0m                                                                                                                           \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m                                                                                                                                                                      \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m   \u{1B}[0m\u{1B}[38;2;249;226;175m●\u{1B}[0m  \u{1B}[0m\u{1B}[38;2;137;180;250mxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\u{1B}[0m                                                                                                                            \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m     \u{1B}[0m\u{1B}[1m\u{1B}[38;2;205;214;244mxxxxxxxx-xxxx\u{1B}[0m · \u{1B}[0m\u{1B}[38;2;166;173;200mxxxxxx · x/x · xx xxx\u{1B}[0m                                                                                                                            \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m                                                                                                                                                                      \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
    ].joined(separator: "\r\n")
    static let idle = [
        "\u{1B}[0m\u{1B}[48;2;40;50;40m /xxxxx/xxxxxxxxxxxxxxx/xxx/xxxxx-xxxxx/.xxxxxx/xxxxxxxxx/xxx/xxxxxxxxxx-xxxxxxxx/xxxxx-xxxxx xxxxxx x>&x | xxxx -x; xxxxxx xx.xxxxxxxxx | xxx -xx-xx; xxxxxx           \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40m... (x xxxxxxx xxxxx, \u{1B}[0m\u{1B}[38;2;102;102;102m\u{1B}[48;2;40;50;40mxxxx+x\u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40m xxxxxx)\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                   \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40mxxxx-x: xxx xxxxx, xxxxx, /xxxxx/xxxxxxxxxxxxxxx/xxx/xxxxx-xxxxx-xxxxxxxxx/xxxx-xxxxxxxx/xxxx-xx-x\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                     \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40mxxxx-x: xxx xxxxx, xxxxx, /xxxxx/xxxxxxxxxxxxxxx/xxx/xxxxx-xxxxx-xxxxxxxxx/xxxx-xxxxxxxx/xxxx-xx-xx\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                    \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40mxxxxx=x (+ xxxxxxxx xxxx-x xxx xxxxx) xxxx=x\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                           \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40mxx.xxxxxxxxx: xxxxx = xxxxx.xxx  xxxx = xxxxx.xxx  xxxx = xxxx.xxx  (x\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                 \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40mxx:xx  xx x xxxx,  x:xx, xx xxxxx, xxxx xxxxxxxx: xx.xx xxx.xx xxx.xx\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                  \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40mxxxx x.xx\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                              \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m╭ xxxxxxxx xxxxxxxxx ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╮\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;203;166;247m♥ \u{1B}[0m\u{1B}[1m\u{1B}[38;2;205;214;244mxxxxxxxx \"xxxxxxxx-xxxx\" xx xxxxx xxxxxxx\u{1B}[0m                                                                                                                          \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;127;132;156mxxxxxxxx \u{1B}[0m \u{1B}[0m\u{1B}[38;2;205;214;244mxxxxxxxx-xxxx\u{1B}[0m                                                                                                                                              \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;127;132;156mxxx      \u{1B}[0m \u{1B}[0m\u{1B}[38;2;205;214;244mxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\u{1B}[0m                                                                                                                       \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;127;132;156mxxxxxxx  \u{1B}[0m \u{1B}[0m\u{1B}[38;2;166;173;200mxx-xxxxxx\u{1B}[0m                                                                                                                                                  \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;127;132;156mxxxxxxx  \u{1B}[0m \u{1B}[0m\u{1B}[38;2;166;173;200mxxx\u{1B}[0m                                                                                                                                                        \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m \u{1B}[0m\u{1B}[1m\u{1B}[38;2;137;180;250m▸ \u{1B}[0m\u{1B}[38;2;166;173;200m/xxxxxxxx xxxxxx xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\u{1B}[0m                                                                                                              \u{1B}[0m\u{1B}[38;2;203;166;247m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;203;166;247m╰──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────╯\u{1B}[0m",
        "",
        " \u{1B}[0m\u{1B}[3m\u{1B}[38;2;128;128;128mxxxxxx xxx xx-xx xxxxxxx xxxx xxxx xxxxxxxxx xxxxx xxxx xxx xxxx xxxxxx xx-xxx. x'x xxxxxxxx xxxxxxx xx xxxxx xxx xxxxxxxxxx xxxxx xxxxx xx x — xxxx xxxxx xxxxxx xxx  \u{1B}[0m",
        " \u{1B}[0m\u{1B}[3m\u{1B}[38;2;128;128;128mxxx xxxxxxxxxx xxxxx xxxx xxxxx xxxx, xxxxxx xxxxx xx x xxxxx xxxx xxxx xxxxx xxx xxx xxxx xxxxx xx. xxxx xx xxxxx xxx x xxxx xxx xxxxx, x xxxxxxxxxx xxxxxx xxxxx x   \u{1B}[0m",
        " \u{1B}[0m\u{1B}[3m\u{1B}[38;2;128;128;128mxxxx xxxxx, xx x xxxx xx xxxxx xxxxxxx xxx xxxxxxxxxx xxxxxx xxxxxxxxxx xxxxxxxx xxxxx xxx xxxxxxx-xxxx xxxx.\u{1B}[0m                                                          ",
        "",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m $ xxxx x > /xxx/xxxxx-xxxxx-xxxxx/xxxxx; xxxx \"- xxxx xxxxx (xx:xx): xxxx xx.x xx (< xx), xxxx ~xx–xxx → xxxxx xxxxx xx x xxxxx (xxx; xxxx'x ≥xx xx xxxx xxxxxx).      \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m xxxxxx xxxx xxxxxx xx–xx xxx xxx xxxx xxxx x xxxxx xxxxxx.\" >> /xxxxx/xxxxxxxxxxxxxxx/xxx/xxxxx-xxxxx/.xxxxxx/xxxxxxxxx/xxxx/xxxx-xxxxxxxx/xxxxx/xx-xxxx-xxxxx.xx      \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40m(xx xxxxxx)\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                            \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m \u{1B}[0m\u{1B}[38;2;128;128;128m\u{1B}[48;2;40;50;40mxxxx x.xx\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                              \u{1B}[0m",
        "\u{1B}[0m\u{1B}[48;2;40;50;40m                                                                                                                                                                        \u{1B}[0m",
        "",
        " xxx xxxx xxxxx xxxxxxx xxxx xxxxx xxx xxx xxxxxxxx xx xxxxxx, xxx xxxxx, xx x'x xxx xxxxxxxx xxx xx xxxx. xxxxxx xxx xxx xxxxxx xx xx xx xxxxxxx xxx xxxx.             ",
        "                                                                                                                                                                        ",
        " ┌──────────┬───────────────┬─────────────────────────────────────────────────────────────┐                                                                             ",
        " │ \u{1B}[0m\u{1B}[1mxxx     \u{1B}[0m │ \u{1B}[0m\u{1B}[1mxxxx         \u{1B}[0m │ \u{1B}[0m\u{1B}[1mxxxxx                                                      \u{1B}[0m │                                                                             ",
        " ├──────────┼───────────────┼─────────────────────────────────────────────────────────────┤                                                                             ",
        " │ \u{1B}[0m\u{1B}[38;2;138;190;183mxxxxxxxx\u{1B}[0m │ xx-xx (x-xxx) │ xxxxxxxx xxxx x, xx xxxxxxx xxxx xxx xxxxx                  │                                                                             ",
        " ├──────────┼───────────────┼─────────────────────────────────────────────────────────────┤                                                                             ",
        " │ \u{1B}[0m\u{1B}[38;2;138;190;183mxxxxxxxx\u{1B}[0m │ xx-xx (xxx)   │ xxxx x, xx xxxxxxx; xxxxx xxxxxxxxx, +xxx/−xx               │                                                                             ",
        " ├──────────┼───────────────┼─────────────────────────────────────────────────────────────┤                                                                             ",
        " │ \u{1B}[0m\u{1B}[38;2;138;190;183mxxxxxxxx\u{1B}[0m │ xx-x-xxx      │ xxxx x, xx xxxxxxx                                          │                                                                             ",
        " ├──────────┼───────────────┼─────────────────────────────────────────────────────────────┤                                                                             ",
        " │ \u{1B}[0m\u{1B}[38;2;138;190;183mxxxxxxxx\u{1B}[0m │ xx-x (xxx)    │ xxxxxx; xxx xxxx xxxx xxxxx, xxxx xxxxx xxxx xx xxxxxxx xxx │                                                                             ",
        " └──────────┴───────────────┴─────────────────────────────────────────────────────────────┘                                                                             ",
        "                                                                                                                                                                        ",
        " \u{1B}[0m\u{1B}[1mxxxxx xxxxx:\u{1B}[0m xxxxxx xxxx xx x xxxxx. xxxx xxx xxxxxxx xx xx.x xx, xxxxx xxxx'x xx xx xxxx. xxxx xx xxxxx xxxx (xxxxx xx–xxx), xx x'x xxxxxxx x xxxxxx xxxx xxxxx       ",
        " xxxxxx; xxx xxxxx xxxx xxxxx x xx xxx xxxx xxxxx xx xxx x.                                                                                                             ",
        "",
        "                                                                                            \u{1B}[0m\u{1B}[38;2;102;102;102m↑\u{1B}[0m\u{1B}[38;2;128;128;128mxxx\u{1B}[0m\u{1B}[38;2;102;102;102m • ↓\u{1B}[0m\u{1B}[38;2;128;128;128mx.xx\u{1B}[0m\u{1B}[38;2;102;102;102m • x\u{1B}[0m\u{1B}[38;2;128;128;128mxxxxx\u{1B}[0m\u{1B}[38;2;102;102;102m • x\u{1B}[0m\u{1B}[38;2;128;128;128mx.xx\u{1B}[0m\u{1B}[38;2;102;102;102m • xx\u{1B}[0m\u{1B}[38;2;128;128;128mxx.x%\u{1B}[0m\u{1B}[38;2;102;102;102m • \u{1B}[0m\u{1B}[38;2;128;128;128m$xxx.xxx\u{1B}[0m \u{1B}[0m\u{1B}[38;2;102;102;102m(xxx) • \u{1B}[0m\u{1B}[38;2;128;128;128mxx.x%/x.xx (xxxx)\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;178;148;187m────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\u{1B}[0m",
        "❯ \u{1B}[0m\u{1B}[7m \u{1B}[0m                                                                                                                                                                     ",
        "\u{1B}[0m\u{1B}[38;2;178;148;187m────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;102;102;102m(xxxxxxxxx) xxxxxx-xxxx-x-x xxxx\u{1B}[0m \u{1B}[0m\u{1B}[38;2;102;102;102m•\u{1B}[0m \u{1B}[0m\u{1B}[38;2;128;128;128m~/xxx/xxxxx-xxxxx (xxxx)\u{1B}[0m",
        "",
        "\u{1B}[0m\u{1B}[38;2;138;190;183mTasks  2 background tasks running · /xxxxx\u{1B}[0m",
        "",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m╭ BACKGROUND  8 runs  \u{1B}[0m\u{1B}[38;2;249;226;175m● 8 running\u{1B}[0m\u{1B}[38;2;108;112;134m ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\u{1B}[0m\u{1B}[38;5;7m┃\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m   \u{1B}[0m\u{1B}[38;2;249;226;175m●\u{1B}[0m  \u{1B}[0m\u{1B}[38;2;137;180;250mxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\u{1B}[0m                                                                                                                            \u{1B}[0m\u{1B}[38;5;7m┃\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m     \u{1B}[0m\u{1B}[1m\u{1B}[38;2;205;214;244mxxxxxxxx-xxxx\u{1B}[0m · \u{1B}[0m\u{1B}[38;2;166;173;200mxxxxxx · x/x · xxx xxx\u{1B}[0m                                                                                                                           \u{1B}[0m\u{1B}[38;5;7m┃\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m                                                                                                                                                                      \u{1B}[0m\u{1B}[38;5;7m┃\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m   \u{1B}[0m\u{1B}[38;2;249;226;175m●\u{1B}[0m  \u{1B}[0m\u{1B}[38;2;137;180;250mxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\u{1B}[0m                                                                                                                            \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m     \u{1B}[0m\u{1B}[1m\u{1B}[38;2;205;214;244mxxxxxxxx-xxxx\u{1B}[0m · \u{1B}[0m\u{1B}[38;2;166;173;200mxxxxxx · x/x · xxx xxx\u{1B}[0m                                                                                                                           \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m                                                                                                                                                                      \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m   \u{1B}[0m\u{1B}[38;2;249;226;175m●\u{1B}[0m  \u{1B}[0m\u{1B}[38;2;137;180;250mxxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\u{1B}[0m                                                                                                                            \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m     \u{1B}[0m\u{1B}[1m\u{1B}[38;2;205;214;244mxxxxxxxx-xxxx\u{1B}[0m · \u{1B}[0m\u{1B}[38;2;166;173;200mxxxxxx · x/x · xx xx\u{1B}[0m                                                                                                                             \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
        "\u{1B}[0m\u{1B}[38;2;108;112;134m│\u{1B}[0m                                                                                                                                                                      \u{1B}[0m\u{1B}[38;5;8m│\u{1B}[0m",
    ].joined(separator: "\r\n")
}
