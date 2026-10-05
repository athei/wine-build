//! The built-in rules, compiled into `compatdb.so`.
//!
//! This is static data the library owns, so it never travels through the
//! environment. Only overrides are serialized into `WINE_COMPATDB`; the
//! library overlays them onto these rules by name.
//!
//! Every rule that names an executable also carries a version fingerprint, so
//! none of them can catch an unrelated program that happens to share a file
//! name. The exceptions are `no-vulkan`, `dpi-aware`, `large-address-aware`,
//! `x87-sidecar` and `no-mono-gecko`, which match every process on purpose:
//! each is a default that a more specific rule can override and that can be
//! dropped by name.

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
            // Programs under this Wine are treated as DPI-aware unless a rule
            // says otherwise. An unaware program on a scaled desktop gets its
            // window and mouse coordinates scaled while display modes are
            // not, so a game that sizes itself from the mode list draws and
            // reads the pointer in two different coordinate spaces.
            Rule {
                name: "dpi-aware".into(),
                exe: ANY_EXE.into(),
                dpi_aware: Some(true),
                ..Rule::default()
            },
            // Every 32-bit process gets the 4 GB address space, whether or not
            // its executable has the large-address-aware flag. Older games
            // that run out of their 2 GB long before they would on Windows,
            // because Wine itself and the Direct3D layers take a share, get
            // the headroom. A rule for one game with `large_address_aware =
            // false` stops forcing it; an executable that has the flag keeps
            // it regardless. 64-bit processes are not affected.
            Rule {
                name: "large-address-aware".into(),
                exe: ANY_EXE.into(),
                large_address_aware: Some(true),
                ..Rule::default()
            },
            // Every i386 process under Rosetta starts with the x87sidecar
            // attached, which runs x87 floating-point code faster than
            // Rosetta does on its own. ntdll asks compatdb_query_x87 before it
            // starts the process, so a rule for one game with `x87_sidecar =
            // false` keeps the sidecar away from it.
            Rule {
                name: "x87-sidecar".into(),
                exe: ANY_EXE.into(),
                x87_sidecar: Some(true),
                ..Rule::default()
            },
            // Keeps Wine from prompting to install Mono and Gecko, in
            // wineboot and in any process that loads either. It is a separate
            // rule so disabling `no-vulkan` does not bring the prompts back.
            //
            // The override disables both modules, not only the prompts. ntdll
            // consults the overrides compatdb adds before the registry
            // DllOverrides keys, so an installed wine-mono, Gecko or native
            // .NET selected there stays disabled too. A prefix that needs one
            // either drops this rule (`name=no-mono-gecko;enabled=false`) or
            // adds a later entry for the module, such as `mscoree=n,b`.
            Rule {
                name: "no-mono-gecko".into(),
                exe: ANY_EXE.into(),
                dll_overrides: vec!["mscoree,mshtml=".into()],
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
    use compatdb_table::{HEADER, VersionInfo};

    use super::*;

    /// The names of the rules that match every process, in table order.
    fn wildcards() -> Vec<String> {
        vec![
            "no-vulkan".to_string(),
            "dpi-aware".to_string(),
            "large-address-aware".to_string(),
            "x87-sidecar".to_string(),
            "no-mono-gecko".to_string(),
        ]
    }

    /// `wildcards()` without the rule of the given name.
    fn wildcards_without(name: &str) -> Vec<String> {
        wildcards().into_iter().filter(|n| n != name).collect()
    }

    /// `wildcards()` followed by one more specific rule.
    fn wildcards_and(name: &str) -> Vec<String> {
        let mut names = wildcards();
        names.push(name.to_string());
        names
    }

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
        // it would catch every program of that name. The `*` rules are a
        // different case: they are meant for every process, and several of
        // them are not duplicates of each other.
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
    fn every_process_gets_the_wildcard_defaults() {
        let resolution = table().resolve("game.exe", &VersionInfo::default());
        assert_eq!(resolution.matched, wildcards());
        assert_eq!(
            resolution.dll_overrides,
            vec!["vulkan-1=".to_string(), "mscoree,mshtml=".to_string()]
        );
        assert_eq!(resolution.dpi_aware, Some(true));
        assert_eq!(resolution.large_address_aware, Some(true));
        assert_eq!(resolution.x87_sidecar, Some(true));
    }

    #[test]
    fn a_game_rule_turns_large_address_awareness_and_the_x87_sidecar_off() {
        let mut table = table();
        let (over, diagnostics) = Table::parse(&format!(
            "{HEADER}\nname=old;exe=old.exe;large_address_aware=false;x87_sidecar=false"
        ));
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert!(table.overlay(over).is_empty());
        let old = table.resolve("Old.exe", &VersionInfo::default());
        assert_eq!(old.large_address_aware, Some(false));
        assert_eq!(old.x87_sidecar, Some(false));
        assert_eq!(old.matched, wildcards_and("old"));
        // Another process keeps both defaults.
        let other = table.resolve("other.exe", &VersionInfo::default());
        assert_eq!(other.large_address_aware, Some(true));
        assert_eq!(other.x87_sidecar, Some(true));
        // The plain wildcard rules still stack without being reported.
        assert!(table.duplicate_matchers().is_empty());
    }

    #[test]
    fn disabling_the_laa_and_x87_rules_leaves_no_opinion() {
        let mut table = table();
        let (over, diagnostics) = Table::parse(&format!(
            "{HEADER}\nname=large-address-aware;enabled=false\nname=x87-sidecar;enabled=false"
        ));
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert!(table.overlay(over).is_empty());
        let resolution = table.resolve("game.exe", &VersionInfo::default());
        assert_eq!(resolution.large_address_aware, None);
        assert_eq!(resolution.x87_sidecar, None);
        assert_eq!(resolution.dpi_aware, Some(true));
    }

    #[test]
    fn disabling_dpi_aware_leaves_the_awareness_to_wine() {
        let mut table = table();
        let (over, diagnostics) = Table::parse(&format!("{HEADER}\nname=dpi-aware;enabled=false"));
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert!(table.overlay(over).is_empty());
        let resolution = table.resolve("game.exe", &VersionInfo::default());
        assert_eq!(resolution.dpi_aware, None);
        assert_eq!(resolution.matched, wildcards_without("dpi-aware"));
    }

    #[test]
    fn a_launch_wide_rule_beats_the_builtin_dpi_default() {
        // Both are plain `*` rules, so specificity does not separate them.
        // The launcher's rule has a new name, so the overlay appends it after
        // the built-ins, and the stable sort in `resolve` keeps that order.
        let mut table = table();
        let (over, diagnostics) =
            Table::parse(&format!("{HEADER}\nname=global;exe=*;dpi_aware=false"));
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert!(table.overlay(over).is_empty());
        let resolution = table.resolve("game.exe", &VersionInfo::default());
        assert_eq!(resolution.dpi_aware, Some(false));
        assert_eq!(resolution.matched, wildcards_and("global"));
    }

    #[test]
    fn a_rule_for_one_program_makes_it_unaware() {
        let mut table = table();
        let (over, diagnostics) =
            Table::parse(&format!("{HEADER}\nname=old;exe=old.exe;dpi_aware=false"));
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert!(table.overlay(over).is_empty());
        assert_eq!(
            table.resolve("Old.exe", &VersionInfo::default()).dpi_aware,
            Some(false)
        );
        assert_eq!(
            table
                .resolve("other.exe", &VersionInfo::default())
                .dpi_aware,
            Some(true)
        );
    }

    #[test]
    fn a_launch_wide_rule_re_enables_mono_after_the_builtins() {
        // What a launcher sends for a top-level `dll_overrides`: its own `*`
        // rule. Within the wildcard tier the rules fold in table order, which
        // puts the built-ins first, and ntdll keeps the last entry for a
        // module, so `mscoree=b` wins while mshtml stays disabled.
        let mut table = table();
        let (over, diagnostics) = Table::parse(&format!(
            "{HEADER}\nname=global;exe=*;dll_overrides=mscoree=b"
        ));
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert!(table.overlay(over).is_empty());
        let resolution = table.resolve("game.exe", &VersionInfo::default());
        assert_eq!(
            resolution.dll_overrides,
            vec![
                "vulkan-1=".to_string(),
                "mscoree,mshtml=".to_string(),
                "mscoree=b".to_string()
            ]
        );
        assert_eq!(resolution.matched, wildcards_and("global"));
        assert!(table.duplicate_matchers().is_empty());
    }

    #[test]
    fn disabling_no_mono_gecko_drops_only_its_override() {
        let mut table = table();
        let (over, _) = Table::parse(&format!("{HEADER}\nname=no-mono-gecko;enabled=false"));
        assert!(table.overlay(over).is_empty());
        assert_eq!(
            table
                .resolve("game.exe", &VersionInfo::default())
                .dll_overrides,
            vec!["vulkan-1=".to_string()]
        );
    }

    #[test]
    fn a_game_rule_re_enables_vulkan_after_the_builtin_disables_it() {
        // ntdll lets the last override for a module win, so the game's entry
        // has to come after the built-in one. That holds wherever the game's
        // rule is declared, because the `*` rules are folded first.
        let mut table = table();
        let (over, diagnostics) = Table::parse(&format!(
            "{HEADER}\nname=my-game;exe=game.exe;dll_overrides=vulkan-1=n"
        ));
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert!(table.overlay(over).is_empty());
        let resolution = table.resolve("Game.exe", &VersionInfo::default());
        assert_eq!(
            resolution.dll_overrides,
            vec![
                "vulkan-1=".to_string(),
                "mscoree,mshtml=".to_string(),
                "vulkan-1=n".to_string()
            ]
        );
        // Another process still has it disabled.
        assert_eq!(
            table
                .resolve("other.exe", &VersionInfo::default())
                .dll_overrides,
            vec!["vulkan-1=".to_string(), "mscoree,mshtml=".to_string()]
        );
    }

    #[test]
    fn disabling_no_vulkan_drops_the_override() {
        let mut table = table();
        let (over, _) = Table::parse(&format!("{HEADER}\nname=no-vulkan;enabled=false"));
        assert!(table.overlay(over).is_empty());
        let resolution = table.resolve("game.exe", &VersionInfo::default());
        assert_eq!(resolution.matched, wildcards_without("no-vulkan"));
        // The Mono and Gecko prompts stay off.
        assert_eq!(
            resolution.dll_overrides,
            vec!["mscoree,mshtml=".to_string()]
        );
    }

    #[test]
    fn a_game_override_merges_into_the_builtin_it_names() {
        let mut table = table();
        let (over, _) = Table::parse(&format!("{HEADER}\nname=rockstar-launcher;dxgi=dxmt"));
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
            wildcards_and("steam-web-helper")
        );
        let social = VersionInfo {
            company: "Take-Two Interactive Software, Inc.".into(),
            product: "Social Club UI".into(),
            original_filename: "SocialClubHelper.exe".into(),
        };
        assert_eq!(
            table.resolve("SocialClubHelper.exe", &social).matched,
            wildcards_and("rockstar-social-club-ui")
        );
        let gta = VersionInfo {
            company: "Rockstar Games".into(),
            product: "Grand Theft Auto IV".into(),
            original_filename: "GTAIV.exe".into(),
        };
        assert_eq!(
            table.resolve("GTAIV.exe", &gta).matched,
            wildcards_and("gta-iv")
        );
        // An unrelated program of the same name gets only the `*` rules.
        let only_wildcard = wildcards();
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
