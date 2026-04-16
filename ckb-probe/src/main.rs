mod cli;
mod commands;

use clap::Parser;
use cli::{Cli, Commands};

#[tokio::main]
async fn main() {
    env_logger::init();
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Check(args) => commands::check::run(args).await,
        Commands::Symbols(args) => commands::symbols::run(args),
        Commands::Rocksdb(args) => commands::rocksdb::run(args).await,
    };

    // Reset terminal on exit (clear alternate screen, show cursor)
    eprint!("\x1B[?25h");  // show cursor (may be hidden by TUI)

    match result {
        Ok(()) => std::process::exit(0),
        Err(e) => {
            eprintln!("Error: {:#}", e);
            std::process::exit(1);
        }
    }
}
