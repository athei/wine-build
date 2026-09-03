// The dlopen'd unix library carries an @rpath install name, the same way
// mtld3d.so and winemetal.so are built. ntdll loads it by absolute path, so the
// name only matters to tools that read it back.
fn main() {
    let target = std::env::var("TARGET").unwrap_or_default();
    if target.contains("apple") {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-install_name,@rpath/compatdb.so");
    }
}
