use std::process::Command;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    match args.get(1).map(|s| s.as_str()) {
        Some("build-ebpf") => build_ebpf(),
        Some("build") => {
            build_ebpf();
            build_userspace();
        }
        _ => {
            eprintln!("Usage: cargo xtask [build-ebpf|build]");
            eprintln!();
            eprintln!("  build-ebpf   Build eBPF programs (requires nightly + bpf target)");
            eprintln!("  build        Build eBPF programs + userspace CLI");
            std::process::exit(1);
        }
    }
}

fn build_ebpf() {
    let status = Command::new("cargo")
        .current_dir(
            std::env::current_dir()
                .unwrap()
                .join("ckb-probe-ebpf"),
        )
        .args([
            "+nightly",
            "build",
            "--target=bpfel-unknown-none",
            "-Z",
            "build-std=core",
            "--release",
        ])
        .status()
        .expect("failed to build eBPF program");

    assert!(status.success(), "eBPF build failed");
    println!("eBPF program built successfully");
}

fn build_userspace() {
    let status = Command::new("cargo")
        .args(["build", "--release"])
        .status()
        .expect("failed to build userspace");

    assert!(status.success(), "Userspace build failed");
    println!("Userspace program built successfully");
}
