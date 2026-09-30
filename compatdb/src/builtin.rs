//! The built-in rules, compiled into `compatdb.so`.
//!
//! This is static data the library owns, so it never travels through the
//! environment. Only overrides are serialized into `WINE_COMPATDB`; the
//! library overlays them onto these rules by name.
//!
//! Every rule that names an executable also carries a version fingerprint, so
//! none of them can catch an unrelated program that happens to share a file
//! name. The one exception is `no-vulkan`, which matches every process on
//! purpose.

use compatdb_table::{ANY_EXE, Dxgi, Rule, Table};

/// The rules the bundle ships with.
pub fn table() -> Table {
    Table {
        rules: vec![
            // The bundle ships no Vulkan: Wine is built --without-vulkan and
            // bundle-wine.sh deletes vulkan-1.dll and winevulkan. A Vulkan
            // loader a game ships next to its exe can therefore only fail, so
            // disable vulkan-1 in every process: the loader then fails to
            // load, and a game that has another renderer uses it. A rule for
            // one game's exe that adds `vulkan-1=n` is folded after this one
            // and wins.
            Rule {
                name: "no-vulkan".into(),
                exe: ANY_EXE.into(),
                dll_overrides: vec!["vulkan-1=".into()],
                ..Rule::default()
            },
            // The Rockstar Games Launcher needs a real D3D10.1 device, which
            // the 64-bit default (Apple's D3DMetal) does not provide; wined3d
            // does. Matched by its version resource, not its path, so it works
            // wherever it is installed and never hits another game's
            // Launcher.exe.
            Rule {
                name: "rockstar-launcher".into(),
                exe: "Launcher.exe".into(),
                company: Some("Rockstar Games".into()),
                product: Some("Rockstar Games Launcher".into()),
                dxgi: Some(Dxgi::Wined3d),
                ..Rule::default()
            },
            // The launcher's embedded browser (CEF): its GPU process cannot
            // paint into a window owned by another process under winemac, so
            // the sign-in page stays blank. Keeping the drawing in-process
            // fixes it; the child --type= processes inherit the switches.
            Rule {
                name: "rockstar-social-club-ui".into(),
                exe: "SocialClubHelper.exe".into(),
                company: Some("Take-Two Interactive Software".into()),
                product: Some("Social Club UI".into()),
                arguments: vec!["--in-process-gpu".into()],
                ..Rule::default()
            },
            // Steam's embedded browser (CEF): its GPU process cannot paint into
            // the browser's window (blank UI), so keep the GPU in-process. GPU
            // rendering stays on and goes through D3DMetal; the dxgi pin keeps
            // it there even when a wildcard rule selects another tree.
            Rule {
                name: "steam-web-helper".into(),
                exe: "steamwebhelper.exe".into(),
                company: Some("Valve Corporation".into()),
                product: Some("Steam Client WebHelper".into()),
                dxgi: Some(Dxgi::Gptk),
                arguments: vec!["--in-process-gpu".into()],
                ..Rule::default()
            },
            // GTA IV (Complete Edition). The switch overrides the game's own
            // video-memory detection, which mis-reads the reported figure and
            // falls back to 512 MB; 2048 unlocks every quality tier while
            // staying inside the 32-bit address space. Nothing else is needed
            // here: the D3D9 quirks this game wants are backend behaviour, so
            // they live in mtld3d's own built-in profile for GTAIV.exe and
            // apply whichever launcher started it.
            Rule {
                name: "gta-iv".into(),
                exe: "GTAIV.exe".into(),
                company: Some("Rockstar Games".into()),
                product: Some("Grand Theft Auto IV".into()),
                arguments: vec!["-availablevidmem 2048.0".into()],
                ..Rule::default()
            },
        ],
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::indexing_slicing)]
mod tests {
    use compatdb_table::VersionInfo;

    use super::*;

    #[test]
    fn the_builtin_table_pins_the_launcher_and_round_trips() {
        let table = table();
        let launcher = table
            .rules
            .iter()
            .find(|r| r.name == "rockstar-launcher")
            .unwrap();
        assert_eq!(launcher.dxgi, Some(Dxgi::Wined3d));
        assert_eq!(launcher.company.as_deref(), Some("Rockstar Games"));
        let gta = table.rules.iter().find(|r| r.name == "gta-iv").unwrap();
        assert!(gta.arguments[0].starts_with("-availablevidmem"));
        // The D3D9 quirks are mtld3d's, not ours.
        assert!(gta.env.is_empty());

        let (parsed, diagnostics) = Table::parse(&table.to_env_value());
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert_eq!(parsed, table);
    }

    #[test]
    fn every_builtin_rule_has_a_unique_name_and_none_matches_a_bare_basename() {
        // A rule naming an executable must also pin its version resource, or
        // it would catch every program of that name. The `*` rule is a
        // different case: it is meant for every process.
        let table = table();
        for rule in &table.rules {
            assert!(!rule.name.is_empty(), "{} has no name", rule.exe);
            assert!(!rule.exe.is_empty(), "{} has no exe", rule.name);
            assert!(
                !rule.is_unfingerprinted(),
                "{} matches on its executable alone",
                rule.name
            );
        }
        let mut names: Vec<&str> = table.rules.iter().map(|r| r.name.as_str()).collect();
        names.sort_unstable();
        let count = names.len();
        names.dedup();
        assert_eq!(names.len(), count, "duplicate rule name");
        assert!(table.duplicate_matchers().is_empty());
    }

    #[test]
    fn every_process_gets_the_vulkan_loader_disabled() {
        let resolution = table().resolve("game.exe", &VersionInfo::default());
        assert_eq!(resolution.matched, vec!["no-vulkan".to_string()]);
        assert_eq!(resolution.dll_overrides, vec!["vulkan-1=".to_string()]);
    }

    #[test]
    fn a_game_rule_re_enables_vulkan_after_the_builtin_disables_it() {
        // ntdll lets the last override for a module win, so the game's entry
        // has to come after the built-in one. That holds wherever the game's
        // rule is declared, because the `*` rule is folded first.
        let mut table = table();
        let (over, diagnostics) =
            Table::parse("v=3\nname=my-game;exe=game.exe;dll_overrides=vulkan-1=n");
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert!(table.overlay(over).is_empty());
        let resolution = table.resolve("Game.exe", &VersionInfo::default());
        assert_eq!(
            resolution.dll_overrides,
            vec!["vulkan-1=".to_string(), "vulkan-1=n".to_string()]
        );
        // Another process still has it disabled.
        assert_eq!(
            table
                .resolve("other.exe", &VersionInfo::default())
                .dll_overrides,
            vec!["vulkan-1=".to_string()]
        );
    }

    #[test]
    fn disabling_no_vulkan_drops_the_override() {
        let mut table = table();
        let (over, _) = Table::parse("v=3\nname=no-vulkan;enabled=false");
        assert!(table.overlay(over).is_empty());
        let resolution = table.resolve("game.exe", &VersionInfo::default());
        assert!(resolution.matched.is_empty());
        assert!(resolution.dll_overrides.is_empty());
    }

    #[test]
    fn a_game_override_merges_into_the_builtin_it_names() {
        let mut table = table();
        let (over, _) = Table::parse("v=3\nname=rockstar-launcher;dxgi=dxmt");
        assert!(table.overlay(over).is_empty());
        let launcher = table
            .rules
            .iter()
            .find(|r| r.name == "rockstar-launcher")
            .unwrap();
        assert_eq!(launcher.dxgi, Some(Dxgi::Dxmt));
        // The pin survives the override.
        assert_eq!(launcher.company.as_deref(), Some("Rockstar Games"));
        assert_eq!(launcher.exe, "Launcher.exe");
    }

    #[test]
    fn the_steam_helper_rule_matches_the_real_binarys_resource() {
        // Guards the fingerprints against a typo: these are the strings read
        // out of the shipped exes.
        let table = table();
        let steam = VersionInfo {
            company: "Valve Corporation".into(),
            product: "Steam Client WebHelper".into(),
            original_filename: "steamwebhelper.exe".into(),
        };
        assert_eq!(
            table.resolve("steamwebhelper.exe", &steam).matched,
            vec!["no-vulkan".to_string(), "steam-web-helper".to_string()]
        );
        let social = VersionInfo {
            company: "Take-Two Interactive Software, Inc.".into(),
            product: "Social Club UI".into(),
            original_filename: "SocialClubHelper.exe".into(),
        };
        assert_eq!(
            table.resolve("SocialClubHelper.exe", &social).matched,
            vec![
                "no-vulkan".to_string(),
                "rockstar-social-club-ui".to_string()
            ]
        );
        let gta = VersionInfo {
            company: "Rockstar Games".into(),
            product: "Grand Theft Auto IV".into(),
            original_filename: "GTAIV.exe".into(),
        };
        assert_eq!(
            table.resolve("GTAIV.exe", &gta).matched,
            vec!["no-vulkan".to_string(), "gta-iv".to_string()]
        );
        // An unrelated program of the same name gets only the `*` rule.
        let only_wildcard = vec!["no-vulkan".to_string()];
        assert_eq!(
            table
                .resolve("steamwebhelper.exe", &VersionInfo::default())
                .matched,
            only_wildcard
        );
        assert_eq!(
            table.resolve("GTAIV.exe", &VersionInfo::default()).matched,
            only_wildcard
        );
    }
}
