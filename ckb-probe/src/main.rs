mod cli;
mod commands;

use anyhow::Result;
use clap::Parser;
use cli::{Cli, Commands};

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();
    let cli = Cli::parse();

    match cli.command {
        Commands::Check(args) => commands::check::run(args).await,
        Commands::Symbols(args) => commands::symbols::run(args),
        Commands::Rocksdb(args) => commands::rocksdb::run(args).await,
    }
}
