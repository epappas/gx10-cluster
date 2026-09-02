# Runbook: edit code on the box

**What** — neovim 0.12, pinned plugins, ten language servers and a set of
keymaps that drive the tmux session the editor is running inside.
**When** — you are working *on* a GX10 rather than copying files off it: a
training script that only runs where the GPUs are, a role in this repo, a
workspace's `up.sh`.
**Risk** — low. Everything here is per-user configuration and release binaries
in `/opt`; nothing touches the driver stack, the fabric or a service.

## Why the editor is on the box at all

Because the work is. A dataloader that only reproduces against 121 GB of
coherent memory, a vLLM flag that only matters at `sm_121`, a two-node job that
cannot be run anywhere else — editing those over a mounted filesystem means
your editor's language server is analysing a different machine's environment
than the one the code runs in.

The consequence is that the editor has to survive the way you reach the box:
SSH, tmux, and a connection that drops. That is why the tmux integration below
is the part with the most thought in it, rather than an afterthought.

## What is installed

| Piece | Version pin | Where it comes from |
|---|---|---|
| neovim | `neovim_version` | upstream tarball → `/opt/nvim-<version>` |
| plugin manager | `lazy_nvim_version` | lazy.nvim at a tag |
| 37 plugins | `roles/editor/files/nvim/lazy-lock.json` | pinned **by commit**, restored not updated |
| 35 treesitter parsers | `tree_sitter_version` | compiled here at provision time |
| 10 language servers | one variable each | see [languages](#languages) |

```bash
make apply TAGS=editor     # the editor alone
make apply TAGS=dev        # editor + python, rust, node, go toolchains
```

There is **no mason.nvim** ([why](../decisions.md#editor-on-the-box)). Every server is installed by ansible from a pinned,
checksummed release, so the editor never downloads a binary on first open — and
never downloads an x86-only one, which is what mason's registry hands an
aarch64 box for about half of these servers. The trade is that adding a server
means editing `roles/editor`, which is the intended direction.

## Reading the keys

vim's notation, which is what every plugin's documentation uses:

| Written | You press |
|---|---|
| `<C-h>` | **Ctrl** and `h` together |
| `<S-l>` | **Shift** and `l` — i.e. a capital `L` |
| `<Space>` | the spacebar, which is the leader key |
| `<Space>tt` | spacebar, release, then `t`, then `t` — a sequence, not a chord |
| `<Esc>` | escape |
| `prefix f` | tmux's prefix, `Ctrl+a`, released, then `f` |

The distinction that matters on this box: **`Ctrl+h/j/k/l` needs no prefix and
works the same inside neovim and inside a plain shell pane**. `Ctrl+a` first is
only for asking tmux itself to do something.

## The 30-second version

`<Space>` is the leader. **Press it and wait**: which-key draws the menu, so
nothing below has to be memorised.

| Key | Does |
|---|---|
| `<C-h/j/k/l>` | move between nvim splits **and tmux panes**, same four keys |
| `<Space><Space>` | find a file |
| `<Space>fg` | grep the project (ripgrep) |
| `<Space>e` | file tree |
| `<Space>tt` | **run this file** in a tmux pane beside you |
| `<Space>tc` | run any command in that pane |
| `<Space>tr` | run it again |
| `<Space>rr` | send the paragraph under the cursor to a REPL |
| `<Space>ac` | open the AI chat (talks to *this* cluster) |
| `gd` `gr` `K` | definition, references, hover |
| `<Space>la` | code action |
| `:GX10Servers` | which language servers are installed and attached |

## Moving around: splits, buffers, panes

Three different things, and only the first four keys are shared between them.

| | Key |
|---|---|
| **Move** between splits *and* tmux panes | `<C-h>` `<C-j>` `<C-k>` `<C-l>` |
| Split the window | `<Space>-` below, `<Space>\|` right (or `<C-w>s` / `<C-w>v`) |
| Resize | `<C-Up>` `<C-Down>` `<C-Left>` `<C-Right>` |
| Close this split / every other one | `<Space>q` / `<C-w>o` |
| Equalise / swap | `<C-w>=` / `<C-w>x` |

Every standard `<C-w>` command still works; only the four navigation keys are
remapped.

The **tabs along the top are buffers, not splits** — bufferline draws them, and
they are open files rather than windows:

| | Key |
|---|---|
| Next / previous | `<S-l>` / `<S-h>` |
| Jump to one | `<Space>b1` … `<Space>b4` |
| Back to the last one | ``<Space>` `` |
| Close it | `<Space>bd` — `<Space>bD` to discard unsaved changes |
| Close every other one | `<Space>bo` |

`<Space>bd` is not `:bdelete`, and the difference is the reason it exists: a
window must always display *some* buffer, so `:bdelete` closes the window along
with the buffer when it has nothing else to put there — and quits the editor
when that was the last window. Closing a tab should not do that, so
`gx10.buffer` points the window at another buffer first (or an empty one) and
deletes afterwards.

The **file tree** is just a window on the left: `<Space>e` toggles it,
`<Space>E` reveals the current file in it, and `<C-l>` moves from it back into
your code.

One side effect worth knowing: `<C-l>` no longer redraws the screen in normal
mode, because it is "pane right" now. `<Esc>` clears search highlighting, and
`prefix C-l` clears a shell pane.

## tmux, from inside the editor

<a name="two-halves"></a>
### Both halves, or neither

`<C-h/j/k/l>` crossing the nvim/tmux boundary is two configurations agreeing:

- `~/.tmux.conf` (roles/shell) asks what is running in the target pane and, if
  it is neovim, forwards the key instead of switching panes.
- `vim-tmux-navigator` (roles/editor) receives it, moves to the next split if
  there is one, and hands control back to tmux if there is not.

Install one without the other and the keys work in one direction only, which is
a genuinely confusing thing to debug. Both arrive with `make apply`.

`<C-l>` was clear-screen; it is now "pane right". The shell's clear is
`prefix C-l`.

### The `<Space>t` group

These drive the *session*, not a `:terminal` buffer. That is the whole point: a
tmux pane outlives the editor, survives a dropped SSH connection, and can be
watched from another window while you keep typing.

| Key | Does |
|---|---|
| `<Space>ts` / `<Space>tv` | shell pane below / to the right, in **this file's** directory |
| `<Space>tw` | new tmux window here |
| `<Space>tt` | run this file — `python`, `go run`, `cargo run`, `bash`, `ansible-playbook --syntax-check`, by filetype |
| `<Space>tc` | prompt for a command, run it in the runner pane |
| `<Space>tr` | re-run the last one |
| `<Space>tk` | kill the runner pane |
| `<Space>tp` | shell in a popup over the whole screen |
| `<Space>tg` | `git status` in a popup, then a shell there |
| `<Space>tG` | `gx10-top` in a popup — both nodes, without an ssh |
| `<Space>tf` | switch or create a project session (fzf) |
| `<Space>tz` | zoom this tmux pane |

The runner pane is created on first use at 35% width, remembered **by tmux pane
id** rather than by index (indexes renumber; a remembered index eventually
sends `make apply` to whichever pane inherited the number), and the buffer is
written before anything runs.

### The tmux side

The prefix is `Ctrl+a` — pressed and released, then the key. What this repo
adds:

| Key | Does |
|---|---|
| `prefix f` | session switcher — git repos under `~/src`, plus anywhere zoxide has seen you work |
| `prefix e` | neovim in a new window, in this pane's directory |
| `prefix g` | `git status` popup, then a shell |
| `prefix G` | `gx10-top` popup |
| `prefix C-l` | clear the screen |

And the everyday tmux ones you will want anyway:

| Key | Does |
|---|---|
| `prefix \|` / `prefix -` | split the pane right / below, in the same directory |
| `prefix c` | new window |
| `prefix z` | zoom this pane full-screen (again to undo) |
| `prefix d` | detach — everything keeps running, `ta` reattaches |
| `prefix H/J/K/L` | resize; hold to repeat |
| `prefix h/j/k/l` | select a pane, for when the prefix-free keys are being eaten by whatever is running |
| `prefix Enter` | copy mode: `v` selects, `y` copies to your LOCAL clipboard |
| `prefix r` | reload `~/.tmux.conf` after an apply |

`prefix f` runs `gx10-sessionizer`, which creates the session if it does not
exist and switches to it if it does. Set `GX10_PROJECT_ROOTS` to change where it
looks.

While neovim is running, the tmux window is renamed after the open file, and
automatic renaming is restored when it exits.

<a name="languages"></a>
## Languages

| Language | Server | Installed by | Also |
|---|---|---|---|
| Ansible | `ansible-language-server` | npm | `yaml.ansible` detected from the path **and** the content; diagnostics from the same pinned `ansible-lint` CI uses |
| Rust | `rust-analyzer` | rustup, `roles/dev_rust` | rustaceanvim: runnables, expand macro, explain error; `crates.nvim` in `Cargo.toml` |
| Python | `pyright` + `ruff` | npm + uv tool | types from one, lint and format from the other; pyright's own linter is off so nothing is reported twice |
| Go | `gopls` | `go install`, `roles/dev_go` | gofumpt, staticcheck, inlay hints; `go.nvim` for struct tags and table tests |
| Bash | `bash-language-server` | npm | shellcheck as you type, `shfmt` on save |
| JSON | `vscode-json-language-server` | npm | ~700 schemas from SchemaStore, no network call |
| YAML | `yaml-language-server` | npm | same schema store; telemetry off |
| Terraform | `terraform-ls` | HashiCorp release | read and navigate HCL. **No formatting** — `terraform fmt` needs the terraform binary, which is not installed |
| Markdown | `marksman` | GitHub release | link and heading completion, rename across files; rendered in the buffer by `render-markdown.nvim` |
| Lua | `lua-language-server` | GitHub release | for editing this config |

`vim` is aware of none of that until it attaches. When something is quiet:

```vim
:GX10Servers      " installed? attached? or missing entirely
:checkhealth vim.lsp
```

```bash
# the same question from a shell, with an exit code - what verify.yml runs
nvim --headless -c 'lua require("gx10.provision").doctor()' +qa
```

## Data exploration

The loop here is a plain `.py` file plus a REPL in a tmux pane, not a notebook.
Notebook plugins that render plots need a terminal speaking the kitty graphics
protocol; these boxes are reached from whatever client is to hand, and text to
a pane works from all of them.

| Key | Does |
|---|---|
| `<Space>rp` | start `ipython` in the runner pane, with the ml venv activated |
| `<Space>rr` | send the paragraph under the cursor to it |
| `<Space>rl` | send the line |
| `<Space>r` (visual) | send the selection |
| `<Space>rb` | send the whole buffer |
| `<Space>rc` | choose which pane is the REPL |
| `<Space>xe` | open **this file** as a pandas dataframe in the runner pane (`.csv`, `.tsv`, `.parquet`, `.json`, `.jsonl`) |
| `<Space>xc` | CSV as an aligned table with a sticky header |
| `<Space>xd` | database UI (`vim-dadbod`) — sqlite, duckdb, postgres |

Bracketed paste is on, without which ipython re-indents every line it receives
and a multi-line block arrives as a syntax error.

## The AI assistant

`codecompanion.nvim`, pointed at **this cluster** before anything else. The
adapter is chosen at startup by what actually answers:

1. `gx10_vllm` — the OpenAI-compatible server a `ws up` workspace is serving on
   `:8000`. Fast, and the biggest models here.
2. `gx10_ollama` — the always-on ollama service. Model list comes from the
   server, so whatever `ollama list` shows is what you can pick.
3. `anthropic` — only if `ANTHROPIC_API_KEY` is set in the environment.

Both local endpoints are bound to loopback by design
([why](../../group_vars/all.yml)), which is exactly where an editor on the box
can reach them and nothing else can. Code in the buffer does not leave the
machine unless you deliberately select the anthropic adapter.

| Key | Does |
|---|---|
| `<Space>ac` | toggle the chat |
| `<Space>aa` | the action palette |
| `<Space>ai` | inline edit (normal or visual) |
| `<Space>ae` / `<Space>af` / `<Space>at` | explain / fix / write tests for the selection |
| `<Space>ad` | explain the diagnostics on this line |
| `<Space>ag` | write a commit message |

Force one adapter with `CODECOMPANION_ADAPTER=gx10_ollama`. Point the vLLM
adapter at a specific served model with `GX10_VLLM_MODEL`.

## Changing the setup

### Your own settings

Two files the play never writes:

```
~/.config/nvim-local/init.lua   loaded LAST by init.lua, so it wins
~/.tmux.conf.local              sourced at the end of ~/.tmux.conf
```

Note the first one is **outside** `~/.config/nvim`, and that is load-bearing.
`~/.config/nvim` is a symlink to `~/.local/share/gx10/nvim-<content hash>`, and
an apply that changes anything builds a *new* directory and moves the link — so
a file you put inside the deployed tree does not get overwritten, it gets left
behind in the old one. Anything under `~/.config/nvim` is a deployment, not a
place to keep things.

### Everything is versioned, and rollback is a symlink

Nothing this role installs is written over the top of the thing it replaces
([why](../decisions.md#immutable-artifacts)):

```
/opt/nvim-0.12.5/                          /usr/local/bin/nvim         ->
/opt/go-1.27.0/                            /usr/local/bin/go, gofmt    ->
/opt/lua-language-server-3.19.1/           /usr/local/bin/lua-…        ->
/opt/terraform-ls-0.39.0/                  /usr/local/bin/terraform-ls ->
/opt/marksman-2026-02-08/                  /usr/local/bin/marksman     ->
/opt/tree-sitter-0.27.0/                   /usr/local/bin/tree-sitter  ->
~/go/versions/gopls-v0.23.0/               ~/go/bin/gopls              ->
~/.local/lib/gx10-npm-<hash of the list>/  ~/.local/lib/gx10-npm       ->
~/.local/share/gx10/nvim-<content hash>/   ~/.config/nvim              ->
```

So a bad bump is undone without a download, and without ansible:

```bash
ls -l /usr/local/bin/nvim                  # what is current
ls -d /opt/nvim-*                          # what else is here
sudo ln -sfn /opt/nvim-0.12.4/bin/nvim /usr/local/bin/nvim
```

Then put the version back in `group_vars/all.yml`, or the next `make apply`
moves the link forward again. The old trees are never removed by the play —
deleting the thing you might need to roll back to is the mutation this layout
exists to avoid — so clear them out by hand when you are sure:
`sudo rm -rf /opt/nvim-0.12.4`.

### Adding or updating a plugin

The lockfile is the pin, exactly like the ML venv's:

```bash
# 1. edit the spec
vim roles/editor/files/nvim/lua/plugins/editor.lua

# 2. resolve it on the box, updating ~/.config/nvim/lazy-lock.json
make apply TAGS=editor        # installs the new plugin at its branch head
nvim                          # :Lazy sync, check it works

# 3. bring the resolved lockfile back into the repo and commit it
make nvim-lock
```

`make apply` runs `Lazy! restore`, never `sync`: restore checks out the
committed commits, sync resolves to whatever each branch's HEAD is today. Only
the first of those gives two boxes the same editor.

### Bumping neovim

`neovim_version` and `neovim_sha256` in `group_vars/all.yml`, together — the
project publishes no checksums file with its releases, so the digest is computed
from the asset:

```bash
curl -sSLO https://github.com/neovim/neovim/releases/download/v<new>/nvim-linux-arm64.tar.gz
sha256sum nvim-linux-arm64.tar.gz
```

Old versions stay in `/opt/nvim-<version>`; only the symlink moves.

## What your terminal has to provide

| Needs | Why | If absent |
|---|---|---|
| A Nerd Font | icons in the tree, statusline and completion menu | replacement boxes. Nothing breaks |
| Truecolor | the catppuccin palette matches the tmux status bar exactly | approximated colours |
| OSC 52 pass-through | `"+y` reaches your **local** clipboard from three SSH hops away | yank stays inside the box |

`tmux.conf` already sets `set-clipboard on` and `allow-passthrough on`; the
remaining half is the client. Termius, WezTerm, kitty and iTerm2 all do OSC 52;
Terminal.app does not.

Paste is deliberately left to the terminal: OSC 52 *reads* are refused by most
terminals, so a clipboard provider that tried would hang waiting for a reply
that never comes.

## Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `lazy.nvim is missing` on start | the role has not run for this user | `make apply TAGS=editor` |
| Everything is one colour, no highlighting | no treesitter parsers — the CLI was missing when they were compiled | `nvim --headless -c 'lua require("gx10.provision").parsers()' +qa` |
| A language has no completion or diagnostics | that server is not installed | `:GX10Servers`, then `make apply TAGS=editor` |
| Ansible files behave like plain YAML | the file is not detected as `yaml.ansible` | `:set ft?` — the path patterns are in `lua/gx10/autocmds.lua` |
| `ansiblels` attaches but reports nothing | `ansible-lint` or `ansible-doc` missing | `make apply TAGS=editor` — they are `editor_uv_tools` |
| `<C-h>` leaves nvim and will not come back | only one half of the navigator config is installed | `make apply TAGS=shell,editor`, then `prefix r` |
| `<Space>t…` says "not inside a tmux session" | nvim was started outside tmux | `tn work`, then `nvim` |
| AI chat cannot connect | no workspace serving, ollama down | `ws ps`, `systemctl status ollama`, or set `ANTHROPIC_API_KEY` |
| The editor is 0.9.5 | an old apt neovim is still first on PATH | `make apply TAGS=editor` removes it |
| A plugin update broke something | the lockfile moved | `git checkout roles/editor/files/nvim/lazy-lock.json`, `make apply TAGS=editor` |
| A config change did not take | you edited the deployed tree, not the repo | `ls -l ~/.config/nvim` — it is a symlink into `~/.local/share/gx10/`, replaced wholesale on every apply |
| Your `local.lua` stopped being loaded | it was inside the deployed tree | move it to `~/.config/nvim-local/init.lua`; the pre-versioning tree was renamed to `~/.config/nvim.pre-versioned` |

## See also

- [tools.md](../tools.md) — every `gx10-*` command, including `gx10-sessionizer`
- [provision-node](provision-node.md) — where this fits in a fresh build
- [contributing](../contributing.md) — the checks a change has to pass
