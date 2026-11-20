//! `cargo run -p muya-switchover --example verify_sig -- <file> <sig-file> <pubkey-base64>`
//! Checks a Tauri updater signature (minisign) with the very code the apps use. Used by scripts/release-v5.sh to prove that
//! the `.app.tar.gz` it just signed verifies against the public key compiled into classic 4.1.22 and into Muya 5.

fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() != 4 {
        eprintln!("usage: verify_sig <file> <sig-file> <pubkey-base64>");
        std::process::exit(64);
    }
    let data = std::fs::read(&a[1]).expect("read file");
    let sig = std::fs::read_to_string(&a[2]).expect("read signature");
    match muya_switchover::manifest::verify_signature(&data, &sig, &a[3]) {
        Ok(()) => println!("signature OK ({} bytes)", data.len()),
        Err(e) => {
            eprintln!("signature FAILED: {e:?}");
            std::process::exit(1);
        }
    }
}
