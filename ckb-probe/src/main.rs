mod cli;
mod commands;

use anyhow::Result;
use clap::Parser;
use cli::{Cli, Commands};

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Commands::Symbols(args) => commands::symbols::run(args),
        // Week 3+:
        // Commands::Check(args) => commands::check::run(args),
    }
}
