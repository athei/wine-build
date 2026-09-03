//! The table of per-process rules behind `compatdb.so`.
//!
//! A [`Rule`] says which processes it matches and which settings it applies to
//! them: the Direct3D implementations to load (one for D3D9, one for the DXGI
//! family), DLL load-order overrides, command-line switches and environment
//! entries.
//!
//! Shared by `compatdb.so`, the unix library wine's ntdll loads into every
//! process (it holds the built-in rules, parses [`ENV_VAR`], overlays the
//! result onto them and applies whatever matches the process), and by any
//! launcher that wants to feed it extra rules through that variable.
//!
//! Everything here is pure: it works on `&str`, `&[u16]` (UTF-16 as wine hands
//! it over) and owned values, with no unsafe and no I/O, so the library's
//! decision logic is all unit-tested on the host and the `.so` itself only has
//! to move bytes in and out of the process.
#![forbid(unsafe_code)]
#![deny(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects
)]

use std::fmt::Write as _;

/// The environment variable `compatdb.so` reads extra rules from. Wine itself
/// never looks at it; it is only the channel from whatever started the process
/// tree to the library.
pub const ENV_VAR: &str = "WINE_COMPATDB";

/// Serialized-table header.
///
/// A table carrying a different version is ignored wholesale, which is what
/// makes a format change safe: a long-lived process started before the change
/// still holds the old value and simply drops it.
pub const HEADER: &str = "v=3";

/// The parts of a PE version resource the database can match on. Vendor-set at
/// link time, so stable across install location and patches. Empty strings when
/// the image carries no version resource.
#[derive(Clone, Default, Debug, PartialEq, Eq)]
pub struct VersionInfo {
    pub company: String,
    pub product: String,
    pub original_filename: String,
}

impl VersionInfo {
    /// Extract the standard fields from a `VS_VERSIONINFO` blob (the bytes of an
    /// `RT_VERSION` resource, as UTF-16). Each `String` rule stores a
    /// NUL-terminated key immediately followed, after zero padding, by its
    /// value, so the value is the next non-empty UTF-16 run after the key run.
    #[must_use]
    pub fn from_resource(blob: &[u16]) -> Self {
        Self {
            company: value_after(blob, "CompanyName"),
            product: value_after(blob, "ProductName"),
            original_filename: value_after(blob, "OriginalFilename"),
        }
    }
}

/// The value that follows a `String` rule's key.
///
/// In a real `VS_VERSIONINFO` each `String` rule starts with three header
/// words (`wLength`, `wValueLength`, `wType`) immediately before the key text,
/// so the key run decodes with a short binary prefix (e.g. `"\u{40}\u{f}\u{1}CompanyName"`).
/// The value that follows has no such header, so it is a clean run. Match the
/// key as a run *suffix*, then take the next run as the value.
fn value_after(blob: &[u16], key: &str) -> String {
    let runs = utf16_runs(blob);
    runs.iter()
        .position(|run| run.ends_with(key))
        .and_then(|i| i.checked_add(1))
        .and_then(|next| runs.get(next))
        .cloned()
        .unwrap_or_default()
}

/// Split a UTF-16 buffer into its NUL-separated runs, dropping empty ones and
/// decoding each lossily.
fn utf16_runs(blob: &[u16]) -> Vec<String> {
    let mut runs = Vec::new();
    let mut cur: Vec<u16> = Vec::new();
    for &u in blob {
        if u == 0 {
            if !cur.is_empty() {
                runs.push(String::from_utf16_lossy(&cur));
                cur.clear();
            }
        } else {
            cur.push(u);
        }
    }
    if !cur.is_empty() {
        runs.push(String::from_utf16_lossy(&cur));
    }
    runs
}

/// Which implementation of the DXGI family a process loads.
///
/// D3D10, D3D10.1, D3D11 and D3D12 travel together because they all create
/// their device through one `dxgi.dll`, and each implementation's modules only
/// work with its own.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Dxgi {
    /// Apple's `D3DMetal` (Game Porting Toolkit). `x86_64` only.
    Gptk,
    /// DXMT.
    Dxmt,
    /// Wine's own wined3d.
    Wined3d,
}

impl Dxgi {
    /// Parse a wire/TOML value, case-insensitively.
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "gptk" => Some(Self::Gptk),
            "dxmt" => Some(Self::Dxmt),
            "wined3d" => Some(Self::Wined3d),
            _ => None,
        }
    }

    /// The wire/TOML spelling, which is also the `lib/wine/dxgi/<name>` tree.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Gptk => "gptk",
            Self::Dxmt => "dxmt",
            Self::Wined3d => "wined3d",
        }
    }

    /// What a process gets when no rule names an implementation.
    #[must_use]
    pub const fn default_for(arch: Arch) -> Self {
        match arch {
            Arch::X86_64 => Self::Gptk,
            Arch::I386 => Self::Dxmt,
        }
    }

    /// Whether the implementation exists for `arch` at all. Apple ships no
    /// 32-bit `D3DMetal`, so `gptk` on i386 has to fall back to the default.
    #[must_use]
    pub const fn available_for(self, arch: Arch) -> bool {
        !matches!((self, arch), (Self::Gptk, Arch::I386))
    }

    /// The implementation a process actually loads: the requested one, or the
    /// arch default when nothing was requested or the request does not exist
    /// for this arch.
    #[must_use]
    pub const fn effective(requested: Option<Self>, arch: Arch) -> Self {
        match requested {
            Some(want) if want.available_for(arch) => want,
            _ => Self::default_for(arch),
        }
    }
}

/// Which D3D9 implementation a process loads. Independent of [`Dxgi`]: neither
/// implementation's `d3d9.dll` touches `dxgi.dll`.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum D3d9 {
    /// mtld3d, the default on both architectures.
    #[default]
    Mtld3d,
    /// Wine's own wined3d.
    Wined3d,
}

impl D3d9 {
    /// Parse a wire/TOML value, case-insensitively.
    #[must_use]
    pub fn parse(s: &str) -> Option<Self> {
        match s.to_ascii_lowercase().as_str() {
            "mtld3d" => Some(Self::Mtld3d),
            "wined3d" => Some(Self::Wined3d),
            _ => None,
        }
    }

    /// The wire/TOML spelling, which is also the `lib/wine/d3d9/<name>` tree.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Mtld3d => "mtld3d",
            Self::Wined3d => "wined3d",
        }
    }
}

/// The bitness of the process being configured.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Arch {
    X86_64,
    I386,
}

impl Arch {
    /// The `<arch>-windows` builtin directory name.
    #[must_use]
    pub const fn pe_dir(self) -> &'static str {
        match self {
            Self::X86_64 => "x86_64-windows",
            Self::I386 => "i386-windows",
        }
    }
}

/// The exe pattern that matches every process.
pub const ANY_EXE: &str = "*";

/// One rule of the table: what it matches, and the settings it applies to a
/// process that matches. `name` is its identity and `exe` its only required
/// matcher; everything else is optional.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rule {
    /// The rule's name, unique within a table. Carries no meaning beyond
    /// identity: it is what a game file names to extend, override or drop a
    /// rule, and what the log prints. Matched case-insensitively.
    pub name: String,
    /// Image basename to match, case-insensitively, or [`ANY_EXE`] for every
    /// process.
    pub exe: String,
    /// Substring the image's version `CompanyName` must contain.
    pub company: Option<String>,
    /// Substring the image's version `ProductName` must contain.
    pub product: Option<String>,
    /// Substring the image's version `OriginalFilename` must contain.
    pub original_filename: Option<String>,
    /// The DXGI-family implementation to load.
    pub dxgi: Option<Dxgi>,
    /// The D3D9 implementation to load.
    pub d3d9: Option<D3d9>,
    /// `WINEDLLOVERRIDES` elements (each a `names=order` string).
    pub dll_overrides: Vec<String>,
    /// Text appended to the command line, unless already present.
    pub arguments: Vec<String>,
    /// Environment entries; an empty value removes the variable.
    pub env: Vec<(String, String)>,
    /// `WINEDEBUG` channels for this process. Applied by the launcher through
    /// wine's own `WINEDEBUG=<exe>:` prefix, not by the library, because the
    /// channels are parsed before it loads; never serialized.
    pub debug_channels: Vec<String>,
    /// False marks an override that drops the rule of this name. Default true;
    /// only travels on the wire when false.
    pub enabled: bool,
}

impl Default for Rule {
    fn default() -> Self {
        Self {
            name: String::new(),
            exe: String::new(),
            company: None,
            product: None,
            original_filename: None,
            dxgi: None,
            d3d9: None,
            dll_overrides: Vec::new(),
            arguments: Vec::new(),
            env: Vec::new(),
            debug_channels: Vec::new(),
            enabled: true,
        }
    }
}

impl Rule {
    /// Whether this rule applies to a process with the given image basename
    /// and version resource. `exe` matches the basename case-insensitively, or
    /// every basename when it is [`ANY_EXE`]; a fingerprint field, when
    /// present, is an additional case-insensitive substring constraint on the
    /// corresponding version string (so a rule with none matches on the
    /// basename alone).
    #[must_use]
    pub fn matches(&self, exe: &str, version: &VersionInfo) -> bool {
        (self.exe == ANY_EXE || exe.eq_ignore_ascii_case(&self.exe))
            && field_matches(self.company.as_deref(), &version.company)
            && field_matches(self.product.as_deref(), &version.product)
            && field_matches(
                self.original_filename.as_deref(),
                &version.original_filename,
            )
    }

    /// How specific this rule is, which is the order [`Table::resolve`] folds
    /// matching rules in: a wildcard rule first (a launch-wide default), then
    /// one naming an executable, then one that also pins a version
    /// fingerprint. A more specific rule therefore wins a scalar field.
    #[must_use]
    pub fn specificity(&self) -> u8 {
        let fingerprinted =
            self.company.is_some() || self.product.is_some() || self.original_filename.is_some();
        match (self.exe == ANY_EXE, fingerprinted) {
            (true, false) => 0,
            (true, true) => 1,
            (false, false) => 2,
            (false, true) => 3,
        }
    }

    /// Whether this rule matches on its executable alone. Such a rule catches
    /// every program with that file name, which is worth a warning for all but
    /// the few basenames that are unique in practice.
    #[must_use]
    pub fn is_unfingerprinted(&self) -> bool {
        self.specificity() == 2
    }

    /// Whether two rules would match exactly the same processes, which can only
    /// be a mistake in a hand-written table.
    #[must_use]
    pub fn matches_the_same_as(&self, other: &Self) -> bool {
        self.exe.eq_ignore_ascii_case(&other.exe)
            && self.company == other.company
            && self.product == other.product
            && self.original_filename == other.original_filename
    }

    /// Lay an override on top of this rule: a set scalar field wins, lists are
    /// appended (this rule's own entries first), env entries are appended (a
    /// later duplicate name wins when the block is merged).
    fn overlay(&mut self, over: Self) {
        if over.company.is_some() {
            self.company = over.company;
        }
        if over.product.is_some() {
            self.product = over.product;
        }
        if over.original_filename.is_some() {
            self.original_filename = over.original_filename;
        }
        if over.dxgi.is_some() {
            self.dxgi = over.dxgi;
        }
        if over.d3d9.is_some() {
            self.d3d9 = over.d3d9;
        }
        if !over.exe.is_empty() {
            self.exe = over.exe;
        }
        self.dll_overrides.extend(over.dll_overrides);
        self.arguments.extend(over.arguments);
        self.env.extend(over.env);
        self.debug_channels.extend(over.debug_channels);
    }
}

/// The whole database: the built-in rules plus whatever a game file added,
/// in the order they were declared.
#[derive(Clone, Default, Debug, PartialEq, Eq)]
pub struct Table {
    pub rules: Vec<Rule>,
}

/// The settings that apply to one process.
///
/// Every matching rule folded in specificity order, so a scalar holds the most
/// specific rule's value and the lists accumulate. Also names the rules that
/// matched, for the log.
#[derive(Clone, Default, Debug, PartialEq, Eq)]
pub struct Resolution {
    pub dxgi: Option<Dxgi>,
    pub d3d9: Option<D3d9>,
    pub dll_overrides: Vec<String>,
    pub arguments: Vec<String>,
    pub env: Vec<(String, String)>,
    /// Names of the rules that matched, in the order they were folded.
    pub matched: Vec<String>,
}

impl Resolution {
    /// Whether there is nothing to apply.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.dxgi.is_none()
            && self.d3d9.is_none()
            && self.dll_overrides.is_empty()
            && self.arguments.is_empty()
            && self.env.is_empty()
    }
}

impl Table {
    /// Fold every matching rule into one [`Resolution`]. `exe` is the image
    /// basename (see [`basename_of`]); `version` is the image's version
    /// resource, for the optional fingerprint constraints.
    ///
    /// Rules are folded least specific first (see [`Rule::specificity`]), and
    /// within a tier in table order, which puts the built-ins before a game's.
    /// So a scalar field ends up holding the most specific rule's value and a
    /// rule naming a process always beats a launch-wide default, while the
    /// lists accumulate across every rule that matched.
    ///
    /// A rule whose executable matches but whose fingerprint does not simply
    /// does not apply; nothing falls back to it, and the rules that do match
    /// still apply.
    #[must_use]
    pub fn resolve(&self, exe: &str, version: &VersionInfo) -> Resolution {
        let mut matching: Vec<&Rule> = self
            .rules
            .iter()
            .filter(|rule| rule.matches(exe, version))
            .collect();
        matching.sort_by_key(|rule| rule.specificity());
        let mut r = Resolution::default();
        for rule in matching {
            if let Some(dxgi) = rule.dxgi {
                r.dxgi = Some(dxgi);
            }
            if let Some(d3d9) = rule.d3d9 {
                r.d3d9 = Some(d3d9);
            }
            r.dll_overrides.extend(rule.dll_overrides.iter().cloned());
            r.arguments.extend(rule.arguments.iter().cloned());
            r.env.extend(rule.env.iter().cloned());
            r.matched.push(rule.name.clone());
        }
        r
    }

    /// Lay a set of overrides on top of this table, matching by rule name.
    ///
    /// An override naming a rule that is already there is merged into it field
    /// by field (a set scalar wins, lists append), one naming a rule that is
    /// not is appended, and one marked `enabled = false` removes the rule of
    /// that name. Matching by name rather than by executable is what lets two
    /// rules name the same executable with different fingerprints, and what
    /// keeps a new rule from inheriting an unrelated rule's fingerprint.
    ///
    /// An override that names no rule here may only add a new one, so it has to
    /// bring an `exe` of its own. One that does not (an `enabled = false` for a
    /// rule that is gone, or a rule whose only home was a misspelled name) can
    /// never match a process, so it is dropped and its name returned for the
    /// caller to warn about.
    pub fn overlay(&mut self, overrides: Self) -> Vec<String> {
        let mut unmatched = Vec::new();
        for over in overrides.rules {
            let pos = self
                .rules
                .iter()
                .position(|rule| rule.name.eq_ignore_ascii_case(&over.name));
            match pos {
                Some(i) if !over.enabled => {
                    self.rules.remove(i);
                }
                Some(i) => {
                    if let Some(existing) = self.rules.get_mut(i) {
                        existing.overlay(over);
                    }
                }
                None if over.enabled && !over.exe.is_empty() => self.rules.push(over),
                None => unmatched.push(over.name),
            }
        }
        unmatched
    }

    /// Every pair of rules that matches exactly the same processes, by name.
    /// A duplicate can only be a mistake, so the launcher warns about it.
    #[must_use]
    pub fn duplicate_matchers(&self) -> Vec<(String, String)> {
        let mut pairs = Vec::new();
        for (i, rule) in self.rules.iter().enumerate() {
            for other in self.rules.iter().skip(i.saturating_add(1)) {
                if rule.matches_the_same_as(other) {
                    pairs.push((rule.name.clone(), other.name.clone()));
                }
            }
        }
        pairs
    }

    /// Serialize the table into the value of [`ENV_VAR`]: the [`HEADER`] line
    /// followed by one record per rule.
    #[must_use]
    pub fn to_env_value(&self) -> String {
        let mut out = String::from(HEADER);
        for rule in &self.rules {
            out.push('\n');
            out.push_str(&rule_to_record(rule));
        }
        out
    }

    /// Parse the value of [`ENV_VAR`]. Lenient: a malformed record is skipped
    /// with a diagnostic rather than failing the whole table, since the `.so`
    /// must never abort a process. A header line other than [`HEADER`] yields
    /// an empty table and a single diagnostic. Returns the table and the
    /// diagnostics (empty when clean).
    #[must_use]
    pub fn parse(text: &str) -> (Self, Vec<String>) {
        let mut lines = text.lines();
        let mut diagnostics = Vec::new();
        match lines.next() {
            Some(HEADER) => {}
            other => {
                diagnostics.push(format!(
                    "unrecognized header {:?}, ignoring the whole table",
                    other.unwrap_or("")
                ));
                return (Self::default(), diagnostics);
            }
        }
        let mut rules = Vec::new();
        for line in lines {
            if line.trim().is_empty() {
                continue;
            }
            match record_to_rule(line) {
                Ok(rule) => rules.push(rule),
                Err(reason) => diagnostics.push(format!("skipping record {line:?}: {reason}")),
            }
        }
        (Self { rules }, diagnostics)
    }
}

/// The basename of a DOS image path (`...\Foo\Bar.exe` -> `Bar.exe`), decoded
/// lossily from UTF-16.
#[must_use]
pub fn basename_of(image_path: &[u16]) -> String {
    let start = image_path
        .iter()
        .rposition(|&u| u == u16::from(b'\\') || u == u16::from(b'/'))
        .map_or(0, |i| i.saturating_add(1));
    String::from_utf16_lossy(image_path.get(start..).unwrap_or(&[]))
}

/// Append each text to the command line unless it is already present.
///
/// The substring test is case-sensitive, the rule that leaves Chromium
/// `--type=` children, which inherit their parent's switches, untouched.
/// Returns `None` when nothing changed.
#[must_use]
pub fn append_cmdline(cmdline: &[u16], appends: &[String]) -> Option<Vec<u16>> {
    let mut cur = cmdline.to_vec();
    let mut changed = false;
    for text in appends {
        if text.is_empty() || contains_cs(&cur, text) {
            continue;
        }
        cur.push(u16::from(b' '));
        cur.extend(text.encode_utf16());
        changed = true;
    }
    changed.then_some(cur)
}

/// Merge environment entries into a `NAME=value\0...\0\0` block.
///
/// A name is matched case-insensitively; a non-empty value replaces in place
/// or appends, an empty value removes. Drive entries (`=C:=...`) are left
/// alone. Returns `None` when nothing changed.
#[must_use]
pub fn merge_env(block: &[u16], entries: &[(String, String)]) -> Option<Vec<u16>> {
    let mut segs = split_env(block);
    let mut changed = false;
    for (name, value) in entries {
        let found = segs.iter().position(|seg| env_name_matches(seg, name));
        if value.is_empty() {
            if let Some(i) = found {
                segs.remove(i);
                changed = true;
            }
            continue;
        }
        let mut new_seg: Vec<u16> = name.encode_utf16().collect();
        new_seg.push(u16::from(b'='));
        new_seg.extend(value.encode_utf16());
        match found {
            Some(i) if segs.get(i) == Some(&new_seg) => {}
            Some(i) => {
                if let Some(slot) = segs.get_mut(i) {
                    *slot = new_seg;
                    changed = true;
                }
            }
            None => {
                segs.push(new_seg);
                changed = true;
            }
        }
    }
    if !changed {
        return None;
    }
    let mut out = Vec::new();
    for seg in &segs {
        out.extend_from_slice(seg);
        out.push(0);
    }
    out.push(0);
    Some(out)
}

// ── Wire format helpers ──────────────────────────────────────────────────

/// Serialize one rule. `debug_channels` is deliberately left out: whoever
/// starts wine applies those through `WINEDEBUG`, and the library would see
/// them too late.
fn rule_to_record(rule: &Rule) -> String {
    let mut fields: Vec<String> = vec![field("name", &rule.name)];
    if !rule.enabled {
        // A disabled rule is a directive to drop the rule of that name, so it
        // travels as the name and nothing else.
        fields.push(String::from("enabled=false"));
        return fields.join(";");
    }
    fields.push(field("exe", &rule.exe));
    if let Some(v) = &rule.company {
        fields.push(field("company", v));
    }
    if let Some(v) = &rule.product {
        fields.push(field("product", v));
    }
    if let Some(v) = &rule.original_filename {
        fields.push(field("original_filename", v));
    }
    if let Some(dxgi) = rule.dxgi {
        fields.push(field("dxgi", dxgi.as_str()));
    }
    if let Some(d3d9) = rule.d3d9 {
        fields.push(field("d3d9", d3d9.as_str()));
    }
    for over in &rule.dll_overrides {
        fields.push(field("dll_overrides", over));
    }
    for text in &rule.arguments {
        fields.push(field("arguments", text));
    }
    for (name, value) in &rule.env {
        fields.push(format!("env={}={}", encode(name), encode(value)));
    }
    fields.join(";")
}

fn record_to_rule(record: &str) -> Result<Rule, String> {
    let mut rule = Rule::default();
    let mut have_name = false;
    for raw in record.split(';') {
        if raw.is_empty() {
            continue;
        }
        let Some((key, value)) = raw.split_once('=') else {
            return Err(format!("field {raw:?} has no '='"));
        };
        match key {
            "name" => {
                rule.name = decode(value);
                have_name = true;
            }
            "exe" => rule.exe = decode(value),
            "company" => rule.company = Some(decode(value)),
            "product" => rule.product = Some(decode(value)),
            "original_filename" => rule.original_filename = Some(decode(value)),
            "enabled" => rule.enabled = decode(value) != "false",
            "dxgi" => {
                let decoded = decode(value);
                match Dxgi::parse(&decoded) {
                    Some(dxgi) => rule.dxgi = Some(dxgi),
                    None => return Err(format!("unknown dxgi value {decoded:?}")),
                }
            }
            "d3d9" => {
                let decoded = decode(value);
                match D3d9::parse(&decoded) {
                    Some(d3d9) => rule.d3d9 = Some(d3d9),
                    None => return Err(format!("unknown d3d9 value {decoded:?}")),
                }
            }
            "dll_overrides" => rule.dll_overrides.push(decode(value)),
            "arguments" => rule.arguments.push(decode(value)),
            "env" => {
                let (name, val) = value.split_once('=').unwrap_or((value, ""));
                rule.env.push((decode(name), decode(val)));
            }
            other => return Err(format!("unknown key {other:?}")),
        }
    }
    if !have_name {
        return Err(String::from("no name field"));
    }
    // `exe` may legitimately be absent: an override that extends or drops a
    // rule declared elsewhere carries only the fields it changes. A rule that
    // ends up with no exe at all matches nothing, which `overlay` reports.
    Ok(rule)
}

fn field(key: &str, value: &str) -> String {
    format!("{key}={}", encode(value))
}

/// Percent-escape the characters that would collide with the wire format
/// (`%`, `;`, and CR/LF) plus any other control character. Everything else,
/// including `=`, `,`, spaces and non-ASCII, passes through.
fn encode(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    encode_into(raw, &mut out);
    out
}

fn encode_into(raw: &str, out: &mut String) {
    for c in raw.chars() {
        match c {
            '%' => out.push_str("%25"),
            ';' => out.push_str("%3B"),
            '\n' => out.push_str("%0A"),
            '\r' => out.push_str("%0D"),
            c if (c as u32) < 0x20 || c == '\u{7f}' => {
                let _ = write!(out, "%{:02X}", c as u32);
            }
            c => out.push(c),
        }
    }
}

/// Reverse [`encode_into`]. Lenient: a `%` not followed by two hex digits is
/// kept literally, so decoding can never fail.
fn decode(encoded: &str) -> String {
    let mut out = String::with_capacity(encoded.len());
    let mut chars = encoded.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        let rest = chars.as_str();
        match rest
            .get(..2)
            .and_then(|hex| u8::from_str_radix(hex, 16).ok())
        {
            Some(byte) => {
                out.push(byte as char);
                let _ = chars.next();
                let _ = chars.next();
            }
            None => out.push('%'),
        }
    }
    out
}

// ── UTF-16 helpers ───────────────────────────────────────────────────────

const fn to_lower_u16(u: u16) -> u16 {
    if u >= b'A' as u16 && u <= b'Z' as u16 {
        u | 0x20
    } else {
        u
    }
}

/// A fingerprint constraint against an actual version string: an absent
/// constraint matches anything, a present one must be an ASCII-case-insensitive
/// substring.
fn field_matches(constraint: Option<&str>, actual: &str) -> bool {
    constraint.is_none_or(|want| {
        actual
            .to_ascii_lowercase()
            .contains(&want.to_ascii_lowercase())
    })
}

/// Case-sensitive substring test.
fn contains_cs(haystack: &[u16], needle: &str) -> bool {
    let n: Vec<u16> = needle.encode_utf16().collect();
    if n.is_empty() {
        return true;
    }
    if haystack.len() < n.len() {
        return false;
    }
    haystack.windows(n.len()).any(|w| w == n.as_slice())
}

/// Split an environment block into its `NAME=value` segments, dropping the
/// terminating NULs.
fn split_env(block: &[u16]) -> Vec<Vec<u16>> {
    let mut segs = Vec::new();
    let mut cur = Vec::new();
    for &u in block {
        if u == 0 {
            if cur.is_empty() {
                break;
            }
            segs.push(std::mem::take(&mut cur));
        } else {
            cur.push(u);
        }
    }
    segs
}

/// Whether an env segment's name equals `name` case-insensitively, skipping
/// the `=C:` drive entries.
fn env_name_matches(seg: &[u16], name: &str) -> bool {
    if seg.first() == Some(&u16::from(b'=')) {
        return false;
    }
    let seg_name = seg.split(|&u| u == u16::from(b'=')).next().unwrap_or(seg);
    let want: Vec<u16> = name.encode_utf16().map(to_lower_u16).collect();
    seg_name.len() == want.len()
        && seg_name
            .iter()
            .map(|&u| to_lower_u16(u))
            .eq(want.iter().copied())
}

#[cfg(test)]
#[allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::panic
)]
mod tests {
    use super::*;

    fn u16s(s: &str) -> Vec<u16> {
        s.encode_utf16().collect()
    }

    fn env_block(entries: &[&str]) -> Vec<u16> {
        let mut out = Vec::new();
        for e in entries {
            out.extend(e.encode_utf16());
            out.push(0);
        }
        out.push(0);
        out
    }

    #[test]
    fn encode_decode_round_trips_specials() {
        for raw in [
            "plain",
            "a;b",
            "a%b",
            "a=b,c d",
            "line\nfeed\r",
            "tab\there",
            "café ünïcode",
            "",
        ] {
            assert_eq!(decode(&encode(raw)), raw, "round trip of {raw:?}");
        }
    }

    #[test]
    fn encode_escapes_only_the_dangerous_characters() {
        assert_eq!(encode("d3d12,vulkan-1="), "d3d12,vulkan-1=");
        assert_eq!(encode("a;b"), "a%3Bb");
        assert_eq!(encode("100%"), "100%25");
    }

    #[test]
    fn decode_is_lenient_about_bad_escapes() {
        assert_eq!(decode("50%"), "50%");
        assert_eq!(decode("%zz"), "%zz");
        assert_eq!(decode("%2"), "%2");
    }

    #[test]
    fn table_round_trips_through_the_env_value() {
        let table = Table {
            rules: vec![
                Rule {
                    name: "rockstar-launcher".into(),
                    exe: "Launcher.exe".into(),
                    company: Some("Rockstar Games".into()),
                    product: Some("Rockstar Games Launcher".into()),
                    dxgi: Some(Dxgi::Wined3d),
                    ..Rule::default()
                },
                Rule {
                    name: "social-club-ui".into(),
                    exe: "SocialClubHelper.exe".into(),
                    arguments: vec!["--in-process-gpu --disable-gpu".into()],
                    original_filename: Some("SocialClubHelper.exe".into()),
                    ..Rule::default()
                },
                Rule {
                    name: "wow".into(),
                    exe: "WoW.exe".into(),
                    d3d9: Some(D3d9::Wined3d),
                    dll_overrides: vec!["d3d12,vulkan-1=".into()],
                    env: vec![("DXMT_CONFIG".into(), "d3d11.maxFrameRate=60".into())],
                    ..Rule::default()
                },
            ],
        };
        let (parsed, diagnostics) = Table::parse(&table.to_env_value());
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert_eq!(parsed, table);
    }

    #[test]
    fn env_field_survives_an_equals_in_the_value() {
        let table = Table {
            rules: vec![Rule {
                name: "x".into(),
                exe: "x.exe".into(),
                env: vec![("A".into(), "b=c;d".into())],
                ..Rule::default()
            }],
        };
        let (parsed, _) = Table::parse(&table.to_env_value());
        assert_eq!(parsed, table);
    }

    #[test]
    fn parse_rejects_a_foreign_header() {
        let (table, diagnostics) = Table::parse("v=2\nname=x;exe=x.exe");
        assert!(table.rules.is_empty());
        assert_eq!(diagnostics.len(), 1);
    }

    #[test]
    fn parse_skips_a_record_without_a_name_but_keeps_the_rest() {
        let (table, diagnostics) = Table::parse("v=3\nexe=no-name.exe\nname=ok;exe=ok.exe");
        assert_eq!(table.rules.len(), 1);
        assert_eq!(table.rules.first().map(|r| r.exe.as_str()), Some("ok.exe"));
        assert_eq!(diagnostics.len(), 1);
    }

    #[test]
    fn an_override_carrying_only_the_changed_fields_needs_no_exe() {
        // What a game file writes to extend a built-in rule: the name it is
        // addressing plus the one field it changes.
        let (over, diagnostics) = Table::parse("v=3\nname=rockstar-launcher;dxgi=dxmt");
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert_eq!(over.rules.len(), 1);
        assert!(over.rules.first().map(|r| r.exe.is_empty()).unwrap());
    }

    #[test]
    fn overlay_drops_an_override_that_could_never_match() {
        // A misspelled name with no exe of its own: it neither extends a rule
        // nor stands on its own, so it is reported rather than kept.
        let mut base = Table::default();
        let unmatched = base.overlay(Table {
            rules: vec![Rule {
                name: "typo".into(),
                dxgi: Some(Dxgi::Dxmt),
                ..Rule::default()
            }],
        });
        assert_eq!(unmatched, vec!["typo".to_string()]);
        assert!(base.rules.is_empty());
    }

    #[test]
    fn parse_rejects_unknown_keys_and_implementation_values() {
        let (_, d1) = Table::parse("v=3\nname=x;exe=x.exe;bogus=1");
        assert_eq!(d1.len(), 1);
        let (_, d2) = Table::parse("v=3\nname=x;exe=x.exe;dxgi=vulkan");
        assert_eq!(d2.len(), 1);
        let (_, d3) = Table::parse("v=3\nname=x;exe=x.exe;d3d9=gptk");
        assert_eq!(d3.len(), 1);
    }

    #[test]
    fn resolve_matches_case_insensitively_and_folds_in_order() {
        let table = Table {
            rules: vec![
                Rule {
                    name: "first".into(),
                    exe: "game.exe".into(),
                    dxgi: Some(Dxgi::Gptk),
                    dll_overrides: vec!["a=".into()],
                    ..Rule::default()
                },
                Rule {
                    name: "second".into(),
                    exe: "GAME.EXE".into(),
                    dxgi: Some(Dxgi::Wined3d),
                    dll_overrides: vec!["b=".into()],
                    ..Rule::default()
                },
            ],
        };
        let r = table.resolve("Game.exe", &VersionInfo::default());
        assert_eq!(r.dxgi, Some(Dxgi::Wined3d));
        assert_eq!(r.dll_overrides, vec!["a=".to_string(), "b=".to_string()]);
    }

    #[test]
    fn a_fingerprint_constraint_is_an_optional_extra_filter() {
        let table = Table {
            rules: vec![Rule {
                name: "rockstar-launcher".into(),
                exe: "Launcher.exe".into(),
                company: Some("Rockstar Games".into()),
                product: Some("Rockstar Games Launcher".into()),
                dxgi: Some(Dxgi::Wined3d),
                ..Rule::default()
            }],
        };
        let rockstar = VersionInfo {
            company: "Rockstar Games".into(),
            product: "Rockstar Games Launcher".into(),
            original_filename: "Launcher.exe".into(),
        };
        // Matches by basename + fingerprint regardless of where it is installed.
        assert_eq!(
            table.resolve("Launcher.exe", &rockstar).dxgi,
            Some(Dxgi::Wined3d)
        );
        // A different program that happens to be called Launcher.exe: same
        // basename, no version resource, so the fingerprint fails and it is
        // left alone.
        assert!(
            table
                .resolve("launcher.exe", &VersionInfo::default())
                .is_empty()
        );
    }

    #[test]
    fn a_bare_basename_rule_needs_no_fingerprint() {
        let table = Table {
            rules: vec![Rule {
                name: "steam-web-helper".into(),
                exe: "steamwebhelper.exe".into(),
                arguments: vec!["--in-process-gpu".into()],
                ..Rule::default()
            }],
        };
        let r = table.resolve("steamwebhelper.exe", &VersionInfo::default());
        assert_eq!(r.arguments, vec!["--in-process-gpu".to_string()]);
    }

    #[test]
    fn version_info_reads_the_standard_fields_from_a_resource() {
        // A realistic VS_VERSIONINFO shape: each key is preceded by the three
        // String-rule header words (wLength, wValueLength, wType), the value
        // is a clean run.
        let mut blob: Vec<u16> = Vec::new();
        let key = |b: &mut Vec<u16>, s: &str| {
            b.extend([0x40u16, 0x0f, 0x01]); // header words
            b.extend(s.encode_utf16());
            b.push(0);
            b.push(0); // padding
        };
        let val = |b: &mut Vec<u16>, s: &str| {
            b.extend(s.encode_utf16());
            b.push(0);
        };
        key(&mut blob, "CompanyName");
        val(&mut blob, "Rockstar Games");
        key(&mut blob, "ProductName");
        val(&mut blob, "Rockstar Games Launcher");
        key(&mut blob, "OriginalFilename");
        val(&mut blob, "Launcher.exe");
        let vi = VersionInfo::from_resource(&blob);
        assert_eq!(vi.company, "Rockstar Games");
        assert_eq!(vi.product, "Rockstar Games Launcher");
        assert_eq!(vi.original_filename, "Launcher.exe");
    }

    #[test]
    fn append_cmdline_is_idempotent() {
        let base = u16s("cmd.exe");
        let appends = vec!["--in-process-gpu".to_string()];
        let once = append_cmdline(&base, &appends).expect("should append");
        assert_eq!(String::from_utf16_lossy(&once), "cmd.exe --in-process-gpu");
        assert!(append_cmdline(&once, &appends).is_none());
    }

    #[test]
    fn append_cmdline_keeps_the_existing_arguments() {
        // The launcher's `arguments` knob and any switches the parent passed
        // are in the command line already; appending must never drop them.
        let base = u16s("game.exe -console --width 1280");
        let out = append_cmdline(&base, &["--in-process-gpu".to_string()]).expect("appended");
        assert_eq!(
            String::from_utf16_lossy(&out),
            "game.exe -console --width 1280 --in-process-gpu"
        );
    }

    #[test]
    fn append_cmdline_applies_each_new_text_once() {
        let base = u16s("app.exe --foo");
        let appends = vec!["--foo".to_string(), "--bar".to_string()];
        let out = append_cmdline(&base, &appends).expect("should append --bar");
        assert_eq!(String::from_utf16_lossy(&out), "app.exe --foo --bar");
    }

    #[test]
    fn merge_env_replaces_appends_and_removes() {
        let block = env_block(&["PATH=C:\\windows", "FOO=old", "=C:=C:\\cur"]);
        let out = merge_env(
            &block,
            &[
                ("foo".into(), "new".into()),   // case-insensitive replace
                ("BAR".into(), "added".into()), // append
                ("PATH".into(), String::new()), // remove
            ],
        )
        .expect("changed");
        let segs = split_env(&out);
        let text: Vec<String> = segs.iter().map(|s| String::from_utf16_lossy(s)).collect();
        assert_eq!(text, vec!["foo=new", "=C:=C:\\cur", "BAR=added"]);
        // Terminated with a double NUL.
        assert_eq!(out.last(), Some(&0));
    }

    #[test]
    fn merge_env_reports_no_change() {
        let block = env_block(&["FOO=bar"]);
        assert!(merge_env(&block, &[("FOO".into(), "bar".into())]).is_none());
        assert!(merge_env(&block, &[("MISSING".into(), String::new())]).is_none());
    }

    #[test]
    fn basename_handles_both_separators_and_none() {
        assert_eq!(basename_of(&u16s("C:\\a\\b\\Foo.exe")), "Foo.exe");
        assert_eq!(basename_of(&u16s("/a/b/Bar.exe")), "Bar.exe");
        assert_eq!(basename_of(&u16s("Baz.exe")), "Baz.exe");
    }

    #[test]
    fn overlay_merges_by_name_appends_lists_and_adds_new_rules() {
        let mut base = Table {
            rules: vec![Rule {
                name: "rockstar-launcher".into(),
                exe: "Launcher.exe".into(),
                company: Some("Rockstar Games".into()),
                dxgi: Some(Dxgi::Wined3d),
                dll_overrides: vec!["a=".into()],
                ..Rule::default()
            }],
        };
        let unmatched = base.overlay(Table {
            rules: vec![
                Rule {
                    name: "Rockstar-Launcher".into(), // case-insensitive match
                    dxgi: Some(Dxgi::Dxmt),
                    dll_overrides: vec!["b=".into()],
                    ..Rule::default()
                },
                Rule {
                    name: "new".into(),
                    exe: "New.exe".into(),
                    arguments: vec!["-x".into()],
                    ..Rule::default()
                },
            ],
        });
        assert!(unmatched.is_empty());
        let launcher = base
            .rules
            .iter()
            .find(|r| r.name == "rockstar-launcher")
            .unwrap();
        assert_eq!(launcher.dxgi, Some(Dxgi::Dxmt)); // override wins
        assert_eq!(launcher.company.as_deref(), Some("Rockstar Games")); // untouched survives
        assert_eq!(launcher.exe, "Launcher.exe"); // an override needs no exe
        assert_eq!(
            launcher.dll_overrides,
            vec!["a=".to_string(), "b=".to_string()]
        ); // appended
        assert!(base.rules.iter().any(|r| r.exe == "New.exe")); // new rule added
    }

    #[test]
    fn overlay_leaves_a_rule_with_the_same_exe_under_another_name_alone() {
        // The bug named rules exist to fix: keying by executable made a new
        // rule for a common basename merge into an unrelated one and inherit
        // its fingerprint.
        let mut base = Table {
            rules: vec![Rule {
                name: "rockstar-launcher".into(),
                exe: "Launcher.exe".into(),
                company: Some("Rockstar Games".into()),
                dxgi: Some(Dxgi::Wined3d),
                ..Rule::default()
            }],
        };
        base.overlay(Table {
            rules: vec![Rule {
                name: "my-launcher".into(),
                exe: "Launcher.exe".into(),
                dxgi: Some(Dxgi::Dxmt),
                ..Rule::default()
            }],
        });
        assert_eq!(base.rules.len(), 2);
        let mine = base.rules.iter().find(|r| r.name == "my-launcher").unwrap();
        assert!(mine.company.is_none(), "no fingerprint inherited");
        assert_eq!(
            base.rules
                .iter()
                .find(|r| r.name == "rockstar-launcher")
                .unwrap()
                .dxgi,
            Some(Dxgi::Wined3d),
            "the pinned rule is untouched"
        );
    }

    #[test]
    fn overlay_reports_an_override_that_names_no_rule() {
        let mut base = Table::default();
        let unmatched = base.overlay(Table {
            rules: vec![Rule {
                name: "gone".into(),
                enabled: false,
                ..Rule::default()
            }],
        });
        assert_eq!(unmatched, vec!["gone".to_string()]);
        assert!(base.rules.is_empty());
    }

    #[test]
    fn overlay_disabled_drops_the_rule_of_that_name() {
        let mut base = Table {
            rules: vec![Rule {
                name: "steam-web-helper".into(),
                exe: "steamwebhelper.exe".into(),
                ..Rule::default()
            }],
        };
        let unmatched = base.overlay(Table {
            rules: vec![Rule {
                name: "steam-web-helper".into(),
                enabled: false,
                ..Rule::default()
            }],
        });
        assert!(unmatched.is_empty());
        assert!(base.rules.is_empty());
    }

    #[test]
    fn a_disabled_override_round_trips_through_the_wire() {
        let table = Table {
            rules: vec![Rule {
                name: "x".into(),
                enabled: false,
                ..Rule::default()
            }],
        };
        let (parsed, diagnostics) = Table::parse(&table.to_env_value());
        assert!(diagnostics.is_empty(), "{diagnostics:?}");
        assert_eq!(parsed, table);
        assert!(!parsed.rules.first().unwrap().enabled);
    }

    #[test]
    fn a_wildcard_rule_is_the_least_specific_and_a_process_rule_beats_it() {
        let table = Table {
            rules: vec![
                Rule {
                    name: "defaults".into(),
                    exe: ANY_EXE.into(),
                    dxgi: Some(Dxgi::Dxmt),
                    dll_overrides: vec!["global=".into()],
                    ..Rule::default()
                },
                Rule {
                    name: "launcher".into(),
                    exe: "Launcher.exe".into(),
                    dxgi: Some(Dxgi::Wined3d),
                    dll_overrides: vec!["specific=".into()],
                    ..Rule::default()
                },
            ],
        };
        // The wildcard alone reaches an unrelated process.
        let other = table.resolve("Other.exe", &VersionInfo::default());
        assert_eq!(other.dxgi, Some(Dxgi::Dxmt));
        assert_eq!(other.matched, vec!["defaults".to_string()]);
        // Both match Launcher.exe; the more specific rule takes the scalar and
        // the lists accumulate least-specific-first.
        let launcher = table.resolve("launcher.exe", &VersionInfo::default());
        assert_eq!(launcher.dxgi, Some(Dxgi::Wined3d));
        assert_eq!(
            launcher.dll_overrides,
            vec!["global=".to_string(), "specific=".to_string()]
        );
        assert_eq!(
            launcher.matched,
            vec!["defaults".to_string(), "launcher".to_string()]
        );
    }

    #[test]
    fn a_process_rule_wins_however_the_rules_are_ordered() {
        // Table order must not decide a scalar; specificity does. Same two
        // rules as above with the specific one declared first.
        let specific = Rule {
            name: "launcher".into(),
            exe: "Launcher.exe".into(),
            dxgi: Some(Dxgi::Wined3d),
            ..Rule::default()
        };
        let wildcard = Rule {
            name: "defaults".into(),
            exe: ANY_EXE.into(),
            dxgi: Some(Dxgi::Dxmt),
            ..Rule::default()
        };
        let table = Table {
            rules: vec![specific, wildcard],
        };
        assert_eq!(
            table.resolve("Launcher.exe", &VersionInfo::default()).dxgi,
            Some(Dxgi::Wined3d)
        );
    }

    #[test]
    fn two_rules_for_one_basename_resolve_independently() {
        let table = Table {
            rules: vec![
                Rule {
                    name: "rockstar-launcher".into(),
                    exe: "Launcher.exe".into(),
                    company: Some("Rockstar Games".into()),
                    dxgi: Some(Dxgi::Wined3d),
                    ..Rule::default()
                },
                Rule {
                    name: "acme-launcher".into(),
                    exe: "Launcher.exe".into(),
                    company: Some("Acme".into()),
                    dxgi: Some(Dxgi::Dxmt),
                    ..Rule::default()
                },
            ],
        };
        let rockstar = VersionInfo {
            company: "Rockstar Games".into(),
            ..VersionInfo::default()
        };
        let acme = VersionInfo {
            company: "Acme Inc".into(),
            ..VersionInfo::default()
        };
        assert_eq!(
            table.resolve("Launcher.exe", &rockstar).matched,
            vec!["rockstar-launcher".to_string()]
        );
        assert_eq!(table.resolve("Launcher.exe", &acme).dxgi, Some(Dxgi::Dxmt));
        // A third program of that name matches neither.
        assert!(
            table
                .resolve("Launcher.exe", &VersionInfo::default())
                .matched
                .is_empty()
        );
    }

    #[test]
    fn specificity_orders_wildcard_then_exe_then_fingerprint() {
        let wildcard = Rule {
            exe: ANY_EXE.into(),
            ..Rule::default()
        };
        let wildcard_pinned = Rule {
            exe: ANY_EXE.into(),
            company: Some("Rockstar Games".into()),
            ..Rule::default()
        };
        let named = Rule {
            exe: "a.exe".into(),
            ..Rule::default()
        };
        let named_pinned = Rule {
            exe: "a.exe".into(),
            product: Some("A".into()),
            ..Rule::default()
        };
        assert!(wildcard.specificity() < wildcard_pinned.specificity());
        assert!(wildcard_pinned.specificity() < named.specificity());
        assert!(named.specificity() < named_pinned.specificity());
        assert!(named.is_unfingerprinted());
        assert!(!named_pinned.is_unfingerprinted());
        assert!(!wildcard.is_unfingerprinted());
    }

    #[test]
    fn duplicate_matchers_finds_rules_that_cannot_be_told_apart() {
        let table = Table {
            rules: vec![
                Rule {
                    name: "one".into(),
                    exe: "game.exe".into(),
                    company: Some("Acme".into()),
                    ..Rule::default()
                },
                Rule {
                    name: "two".into(),
                    exe: "GAME.EXE".into(),
                    company: Some("Acme".into()),
                    ..Rule::default()
                },
                Rule {
                    name: "three".into(),
                    exe: "game.exe".into(),
                    ..Rule::default()
                },
            ],
        };
        assert_eq!(
            table.duplicate_matchers(),
            vec![("one".to_string(), "two".to_string())]
        );
    }

    #[test]
    fn dxgi_defaults_are_per_arch_and_gptk_degrades_on_i386() {
        assert_eq!(Dxgi::default_for(Arch::X86_64), Dxgi::Gptk);
        assert_eq!(Dxgi::default_for(Arch::I386), Dxgi::Dxmt);
        assert_eq!(Dxgi::effective(None, Arch::X86_64), Dxgi::Gptk);
        assert_eq!(Dxgi::effective(None, Arch::I386), Dxgi::Dxmt);
        assert_eq!(Dxgi::effective(Some(Dxgi::Gptk), Arch::I386), Dxgi::Dxmt);
        assert_eq!(
            Dxgi::effective(Some(Dxgi::Wined3d), Arch::I386),
            Dxgi::Wined3d
        );
        assert_eq!(Dxgi::Wined3d.as_str(), "wined3d");
        assert_eq!(Dxgi::parse("GPTK"), Some(Dxgi::Gptk));
        assert_eq!(Dxgi::parse("default"), None);
    }

    #[test]
    fn d3d9_defaults_to_mtld3d_on_every_arch() {
        assert_eq!(D3d9::default(), D3d9::Mtld3d);
        assert_eq!(D3d9::parse("wined3d"), Some(D3d9::Wined3d));
        assert_eq!(D3d9::parse("gptk"), None);
        assert_eq!(D3d9::Mtld3d.as_str(), "mtld3d");
    }

    #[test]
    fn the_two_implementations_resolve_independently() {
        let table = Table {
            rules: vec![
                Rule {
                    name: "defaults".into(),
                    exe: ANY_EXE.into(),
                    dxgi: Some(Dxgi::Wined3d),
                    ..Rule::default()
                },
                Rule {
                    name: "game".into(),
                    exe: "game.exe".into(),
                    d3d9: Some(D3d9::Wined3d),
                    ..Rule::default()
                },
            ],
        };
        let r = table.resolve("game.exe", &VersionInfo::default());
        assert_eq!(r.dxgi, Some(Dxgi::Wined3d));
        assert_eq!(r.d3d9, Some(D3d9::Wined3d));
        let other = table.resolve("other.exe", &VersionInfo::default());
        assert_eq!(other.dxgi, Some(Dxgi::Wined3d));
        assert_eq!(other.d3d9, None);
    }
}
