# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> The detailed pre-release history (0.1.0–0.1.62) was condensed into the summary
> below when the repository was squashed for its public release.

## [Unreleased]

## [0.1.63] - 2026-06-09

A modular PowerShell 7 profile + toolkit for Windows — 56 commands wired up
through one config-driven loader. Run `toolkit` to list them all.

### Profile & prompt

- One declarative `config.psd1` selects the prompt (Oh My Posh / Custom / Default), OneDrive org, jump folders, project roots, and feature toggles; everything else auto-detects.
- Oh My Posh integration: a ~120-theme gallery (`Update-PoshThemes`), `OhMyPoshTheme = 'Random'` for a fresh prompt each shell, `Set-PoshTheme` to browse/pin, and a Nerd-Font check.
- Per-machine (`Machines/<COMPUTERNAME>.ps1`) and per-host (`Hosts/<HostName>.ps1`) overrides, each with a tracked `.ps1.example` template.

### Commands

- **Navigation** — `j` folder jumper (alt-screen picker, `jb`/`jf` history), `prj` git-repo jumper, `mkcd`/`up`/`..`/`...`, and OneDrive shortcuts (`docs`/`desktop`/`downloads`/`onedrive`/`home`).
- **Files** — `peek` (extract & explore any archive), `json` (syntax-highlighting viewer/formatter), `dird`/`fr` (AI-described listings).
- **System** — `df`, `Get-SysInfo`, `Get-Uptime`, `Get-PubIP`, `Find-File`, `sudo`, `Start-AdminTerminal`.
- **AI helpers** — `ask` (ch.at), `wtf` (explain the last error), `tagdl` (AI-tag Downloads) — keys held in SecretStore.
- **Also** — `winup` (winget upgrade picker, `-Elevated`), `rdp`/`rps` (remote servers), `note`/`today`/`Find-Note` (journal), Secrets helpers, Windows Terminal font get/set, Microsoft 365 (`Connect-Graph`, `Get-TenantOverview`, …), and `toolkit`/`tip` discovery.

### Install & quality

- One-command `install.ps1` (symlink, or a dot-source stub as fallback) with a safe, restorative `-Uninstall` (removes only what it added, restores your prior profile) and `-Purge` for caches.
- Comment-based help on every command; rotating startup tips.
- Windows CI: PSScriptAnalyzer (lint clean; warnings block the build) + Pester smoke & unit suites (100+ tests).

### Docs

- README, per-folder READMEs, `docs/ARCHITECTURE.md`, and an interactive poster (`docs/poster.html`).
