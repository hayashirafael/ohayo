import XCTest
@testable import Ohayo

final class SkillCatalogTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-catalog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Cria `<dir>/<nome>/SKILL.md` (ou só a pasta, com `withFile: false`).
    private func makeSkill(at dir: URL, named name: String, withFile: Bool = true) throws {
        let skillDir = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        if withFile {
            try "---\nname: \(name)\n---\n".write(
                to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
    }

    /// Cria um plugin Codex mínimo, no formato apontado por
    /// `codex plugin list --json`.
    private func makeCodexPlugin(
        at pluginRoot: URL,
        manifestName: String,
        skillsPath: String = "./skills/",
        skills: [String]
    ) throws {
        let manifestDir = pluginRoot.appendingPathComponent(".codex-plugin")
        try FileManager.default.createDirectory(
            at: manifestDir,
            withIntermediateDirectories: true
        )
        let manifest: [String: Any] = [
            "name": manifestName,
            "skills": skillsPath,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        )
        try data.write(to: manifestDir.appendingPathComponent("plugin.json"))
        let skillsRoot = pluginRoot.appendingPathComponent(skillsPath)
        for skill in skills {
            try makeSkill(at: skillsRoot, named: skill)
        }
    }

    private func codexInventory(
        _ plugins: [[String: Any]]
    ) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["installed": plugins],
            options: [.sortedKeys]
        )
    }

    private func inventoryPlugin(
        name: String,
        path: URL,
        installed: Bool = true,
        enabled: Bool = true,
        source: String = "local"
    ) -> [String: Any] {
        [
            "name": name,
            "installed": installed,
            "enabled": enabled,
            "source": [
                "source": source,
                "path": path.path,
            ],
        ]
    }

    func testClaudeListaSkillsPessoaisOrdenadas() throws {
        let skills = root.appendingPathComponent("skills")
        try makeSkill(at: skills, named: "zeta")
        try makeSkill(at: skills, named: "alfa")
        XCTAssertEqual(SkillCatalog.skills(for: .claude, at: root),
                       [SkillRef(name: "alfa"), SkillRef(name: "zeta")])
    }

    func testClaudeIncluiSkillsDePluginsComNamespace() throws {
        let versionDir = root.appendingPathComponent(
            "plugins/cache/claude-plugins-official/superpowers/6.1.1/skills")
        try makeSkill(at: versionDir, named: "brainstorming")
        XCTAssertEqual(SkillCatalog.skills(for: .claude, at: root),
                       [SkillRef(name: "superpowers:brainstorming")])
    }

    func testVersoesMultiplasDoMesmoPluginDeduplicam() throws {
        let cache = root.appendingPathComponent("plugins/cache/mp/plug")
        try makeSkill(at: cache.appendingPathComponent("1.0.0/skills"), named: "x")
        try makeSkill(at: cache.appendingPathComponent("2.0.0/skills"), named: "x")
        XCTAssertEqual(SkillCatalog.skills(for: .claude, at: root),
                       [SkillRef(name: "plug:x")])
    }

    func testClaudeIncluiSkillDoDiretorioDeTrabalhoEFontesGlobais() throws {
        let config = root.appendingPathComponent("config")
        let working = root.appendingPathComponent("repo")
        try makeSkill(at: config.appendingPathComponent("skills"), named: "global")
        try makeSkill(
            at: config.appendingPathComponent("plugins/cache/mp/plug/1.0.0/skills"),
            named: "plugin")
        try makeSkill(at: working.appendingPathComponent(".claude/skills"), named: "projeto")
        try makeSkill(at: working.appendingPathComponent(".claude/skills"), named: "global")

        XCTAssertEqual(
            SkillCatalog.skills(for: .claude, at: config, workingDir: working),
            [
                SkillRef(name: "global"),
                SkillRef(name: "plug:plugin"),
                SkillRef(name: "projeto"),
            ]
        )
    }

    func testDiretorioDeTrabalhoSemMarcadorGitTerminaNaPastaInformada() throws {
        let config = root.appendingPathComponent("config")
        let parent = root.appendingPathComponent("sem-repo")
        let working = parent.appendingPathComponent("Sources/App")
        try makeSkill(
            at: parent.appendingPathComponent(".claude/skills"),
            named: "ancestral")
        try makeSkill(
            at: working.appendingPathComponent(".claude/skills"),
            named: "local")

        XCTAssertEqual(
            SkillCatalog.skills(
                for: .claude,
                at: config,
                workingDir: working),
            [SkillRef(name: "local")]
        )
    }

    func testClaudeIncluiSkillDaRaizDoRepositorioQuandoCwdEhSubdiretorio() throws {
        let config = root.appendingPathComponent("config")
        let repo = root.appendingPathComponent("repo")
        let working = repo.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try makeSkill(at: repo.appendingPathComponent(".claude/skills"), named: "repo")
        try makeSkill(at: working.appendingPathComponent(".claude/skills"), named: "local")

        XCTAssertEqual(
            SkillCatalog.skills(
                for: .claude,
                at: config,
                workingDir: working),
            [SkillRef(name: "local"), SkillRef(name: "repo")]
        )
    }

    func testPastaSemSkillMdEhIgnorada() throws {
        try makeSkill(at: root.appendingPathComponent("skills"), named: "vazia", withFile: false)
        XCTAssertEqual(SkillCatalog.skills(for: .claude, at: root), [])
    }

    func testCodexListaSkillsEIgnoraDotSystem() throws {
        let skills = root.appendingPathComponent("skills")
        try makeSkill(at: skills, named: "gmud")
        try makeSkill(at: skills, named: ".system")
        XCTAssertEqual(SkillCatalog.skills(
            for: .codex,
            at: root,
            homeDir: root.appendingPathComponent("home")),
                       [SkillRef(name: "gmud")])
    }

    func testCodexIncluiSkillsGlobaisDeAgentsEDeduplicaComConfig() throws {
        let config = root.appendingPathComponent("config")
        let home = root.appendingPathComponent("home")
        try makeSkill(at: config.appendingPathComponent("skills"), named: "compartilhada")
        try makeSkill(at: home.appendingPathComponent(".agents/skills"), named: "compartilhada")
        try makeSkill(at: home.appendingPathComponent(".agents/skills"), named: "global")

        XCTAssertEqual(
            SkillCatalog.skills(for: .codex, at: config, homeDir: home),
            [SkillRef(name: "compartilhada"), SkillRef(name: "global")]
        )
    }

    func testCodexIncluiSkillsDoDiretorioAteRaizDoRepositorio() throws {
        let repo = root.appendingPathComponent("repo")
        let package = repo.appendingPathComponent("packages/core")
        let working = package.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"),
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        try makeSkill(at: repo.appendingPathComponent(".agents/skills"), named: "repo")
        try makeSkill(at: package.appendingPathComponent(".agents/skills"), named: "pacote")
        try makeSkill(at: working.appendingPathComponent(".agents/skills"), named: "local")
        try makeSkill(at: root.appendingPathComponent(".agents/skills"), named: "fora-do-repo")

        XCTAssertEqual(
            SkillCatalog.skills(
                for: .codex,
                at: root.appendingPathComponent("config"),
                workingDir: working,
                homeDir: root.appendingPathComponent("home")),
            [SkillRef(name: "local"), SkillRef(name: "pacote"), SkillRef(name: "repo")]
        )
    }

    func testCodexNaoVarrePlugins() throws {
        let versionDir = root.appendingPathComponent("plugins/cache/mp/plug/1.0.0/skills")
        try makeSkill(at: versionDir, named: "x")
        XCTAssertEqual(SkillCatalog.skills(
            for: .codex,
            at: root,
            homeDir: root.appendingPathComponent("home")), [])
    }

    func testSkillPessoalPorSymlinkEhListadaPeloNomeDoLink() throws {
        let targetRoot = root.appendingPathComponent("shared")
        try makeSkill(at: targetRoot, named: "real")
        let skills = root.appendingPathComponent("config/skills")
        try FileManager.default.createDirectory(
            at: skills,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: skills.appendingPathComponent("alias"),
            withDestinationURL: targetRoot.appendingPathComponent("real")
        )

        XCTAssertEqual(
            SkillCatalog.skills(
                for: .codex,
                at: root.appendingPathComponent("config"),
                homeDir: root.appendingPathComponent("home")
            ),
            [SkillRef(name: "alias")]
        )
    }

    func testCodexIncluiSomentePluginsInstaladosEHabilitadosDoInventario() throws {
        let enabled = root.appendingPathComponent("plugins/enabled")
        let disabled = root.appendingPathComponent("plugins/disabled")
        let notInstalled = root.appendingPathComponent("plugins/not-installed")
        try makeCodexPlugin(
            at: enabled,
            manifestName: "enabled",
            skills: ["review", "plan"]
        )
        try makeCodexPlugin(
            at: disabled,
            manifestName: "disabled",
            skills: ["hidden"]
        )
        try makeCodexPlugin(
            at: notInstalled,
            manifestName: "not-installed",
            skills: ["ghost"]
        )
        let inventory = try codexInventory([
            inventoryPlugin(name: "enabled", path: enabled),
            inventoryPlugin(name: "disabled", path: disabled, enabled: false),
            inventoryPlugin(
                name: "not-installed",
                path: notInstalled,
                installed: false
            ),
        ])

        XCTAssertEqual(
            SkillCatalog.skills(
                for: .codex,
                at: root.appendingPathComponent("config"),
                homeDir: root.appendingPathComponent("home"),
                codexPluginInventory: inventory
            ),
            [
                SkillRef(name: "enabled:plan"),
                SkillRef(name: "enabled:review"),
            ]
        )
    }

    func testCodexUsaPathExatoDoInventarioENaoVersaoDoCache() throws {
        let selected = root.appendingPathComponent("resolved/plugin-v2")
        let staleCache = root.appendingPathComponent(
            "config/plugins/cache/market/plugin/1.0.0/skills"
        )
        try makeCodexPlugin(
            at: selected,
            manifestName: "plugin",
            skills: ["current"]
        )
        try makeSkill(at: staleCache, named: "stale")
        let inventory = try codexInventory([
            inventoryPlugin(name: "plugin", path: selected),
        ])

        XCTAssertEqual(
            SkillCatalog.skills(
                for: .codex,
                at: root.appendingPathComponent("config"),
                homeDir: root.appendingPathComponent("home"),
                codexPluginInventory: inventory
            ),
            [SkillRef(name: "plugin:current")]
        )
    }

    func testCodexPluginAceitaSymlinkInternoERejeitaEscape() throws {
        let plugin = root.appendingPathComponent("plugins/symlinks")
        try makeCodexPlugin(
            at: plugin,
            manifestName: "symlinks",
            skills: ["target"]
        )
        let skillsRoot = plugin.appendingPathComponent("skills")
        try FileManager.default.createSymbolicLink(
            at: skillsRoot.appendingPathComponent("alias"),
            withDestinationURL: skillsRoot.appendingPathComponent("target")
        )

        let outsideRoot = root.appendingPathComponent("outside")
        try makeSkill(at: outsideRoot, named: "external")
        try FileManager.default.createSymbolicLink(
            at: skillsRoot.appendingPathComponent("escape"),
            withDestinationURL: outsideRoot.appendingPathComponent("external")
        )
        let inventory = try codexInventory([
            inventoryPlugin(name: "symlinks", path: plugin),
        ])

        XCTAssertEqual(
            SkillCatalog.skills(
                for: .codex,
                at: root.appendingPathComponent("config"),
                homeDir: root.appendingPathComponent("home"),
                codexPluginInventory: inventory
            ),
            [
                SkillRef(name: "symlinks:alias"),
                SkillRef(name: "symlinks:target"),
            ]
        )
    }

    func testCodexIgnoraManifestIncompativelOuSkillsForaDoPlugin() throws {
        let mismatch = root.appendingPathComponent("plugins/mismatch")
        let escaped = root.appendingPathComponent("plugins/escaped")
        try makeCodexPlugin(
            at: mismatch,
            manifestName: "outro-nome",
            skills: ["hidden"]
        )
        try makeCodexPlugin(
            at: escaped,
            manifestName: "escaped",
            skillsPath: "../outside",
            skills: ["hidden"]
        )
        try makeSkill(
            at: root.appendingPathComponent("config/skills"),
            named: "personal"
        )
        let inventory = try codexInventory([
            inventoryPlugin(name: "mismatch", path: mismatch),
            inventoryPlugin(name: "escaped", path: escaped),
        ])

        XCTAssertEqual(
            SkillCatalog.skills(
                for: .codex,
                at: root.appendingPathComponent("config"),
                homeDir: root.appendingPathComponent("home"),
                codexPluginInventory: inventory
            ),
            [SkillRef(name: "personal")]
        )
    }

    func testCodexInventarioMalformadoPreservaSkillsLocais() throws {
        try makeSkill(
            at: root.appendingPathComponent("config/skills"),
            named: "personal"
        )

        XCTAssertEqual(
            SkillCatalog.skills(
                for: .codex,
                at: root.appendingPathComponent("config"),
                homeDir: root.appendingPathComponent("home"),
                codexPluginInventory: Data("{invalid".utf8)
            ),
            [SkillRef(name: "personal")]
        )
        XCTAssertFalse(
            CodexPluginCatalog.isValidInventory(Data("{invalid".utf8))
        )
        XCTAssertTrue(
            CodexPluginCatalog.isValidInventory(
                try codexInventory([])
            )
        )
    }

    func testDiretorioInexistenteRetornaVazio() {
        let missing = root.appendingPathComponent("nao-existe")
        XCTAssertEqual(SkillCatalog.skills(for: .claude, at: missing), [])
        XCTAssertEqual(SkillCatalog.skills(
            for: .codex,
            at: missing,
            homeDir: root.appendingPathComponent("home")), [])
    }
}
