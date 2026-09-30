// The dlopen'd unix library carries an @rpath install name, the same way
// mtld3d.so and winemetal.so are built. ntdll loads it by absolute path, so the
// name only matters to tools that read it back.
fn main() {
    // The macOS floor comes from MACOSX_DEPLOYMENT_TARGET, which
    // .cargo/config.toml sets. Cargo does not track that variable on its own,
    // so without this a changed pin never relinks an already built library.
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");

    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("apple") {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/compatdb.so");
    }
}
