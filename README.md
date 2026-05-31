# cleaner

A single-file Swift CLI for macOS cleanup — uninstall apps cleanly, remove
`.pkg` packages, prune plugins, clear dev-tool caches, and find orphaned
Library residuals.

Based on [Pearcleaner](https://github.com/alienator88/Pearcleaner) by
alienator88, distributed under the same license.

## Requirements

macOS with Xcode Command Line Tools (`swift --version` to check;
`xcode-select --install` if missing). No third-party dependencies.

## Install

Run these from the directory where you cloned the repo:

```sh
git clone https://github.com/FishfishCai/cleaner.git
chmod +x cleaner/cleaner.swift

# Symlink it into any directory on your PATH. ~/.local/bin is just one choice
# (created here if missing); /usr/local/bin or your own bin dir works too.
mkdir -p ~/.local/bin
ln -sf "$(pwd)/cleaner/cleaner.swift" ~/.local/bin/cleaner

# If ~/.local/bin isn't on your PATH yet (zsh is the default macOS shell):
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && source ~/.zshrc
```

## Usage

```
cleaner                            # show help
cleaner app-list                   # list third-party apps with sizes
cleaner app-uninstall <name>
cleaner pkg-list                   # list third-party .pkg packages
cleaner pkg-uninstall <pkg-id>
cleaner plugin-list                # list installed plugins
cleaner plugin-uninstall <filename>
cleaner devenv-list                # list dev environments
cleaner devenv-uninstall <path>
cleaner orphan                     # trash unclaimed Library residuals
```

Delete commands open an interactive checklist (alternate screen, restores
your shell on exit):

| Key             | Action                |
| --------------- | --------------------- |
| `↑` `↓` `w/s` `k/j` | Move cursor       |
| `←` `→` `a/d` `h/l` | Toggle selection  |
| `enter`         | Delete checked items  |
| `q` / `Esc`     | Cancel                |

`app-uninstall` shows three sections — **STRICT** (default checked) is bundle-id
exact matches; **ENHANCED** (default unchecked) adds entitlements / team-id
associations (e.g. iCloud / Group Containers); **DEEP** (default unchecked)
adds same-vendor fuzzy matches and may overreach into sibling apps.

## License

[Apache 2.0 with Commons Clause](./LICENSE). **Free for personal and internal
use; commercial sale is prohibited** by the Commons Clause. See
[NOTICE](./NOTICE) for attribution and a summary of which portions are
derived from Pearcleaner.
