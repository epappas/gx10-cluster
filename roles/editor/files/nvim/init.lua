-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN,
-- and not by being edited in place: this whole directory is one deployment.
-- ~/.config/nvim is a SYMLINK to ~/.local/share/gx10/nvim-<content hash>, and
-- an apply that changes anything here builds a new directory and moves the
-- link. Nothing survives inside it.
--
-- So your own settings go in ~/.config/nvim-local/init.lua, which is outside
-- the deployment, is loaded last (so it wins), and is never written by the
-- play - the same split as ~/.tmux.conf.local. See docs/runbooks/edit-code.md.
--
-- Two rules this config keeps, because they are the repo's rules:
--
--   1. Nothing downloads itself. There is no mason.nvim here: every language
--      server is installed by ansible from a pinned release, so the editor
--      never fetches an unpinned binary on first open - and never fetches an
--      x86-only one, which is what mason's registry hands an aarch64 box for
--      about half of these servers.
--   2. Plugins are pinned. lazy-lock.json is committed in the repo and the
--      play restores exactly those commits, so both nodes run byte-identical
--      plugin trees however many months apart they were provisioned.

-- Before anything else: every keymap below hangs off these, and a plugin that
-- loads first would capture the old value.
vim.g.mapleader = " "
vim.g.maplocalleader = ","

require("gx10.path").setup()
require("gx10.options")
require("gx10.keymaps")
require("gx10.autocmds")

-- lazy.nvim is installed by the role at a pinned tag, deliberately NOT
-- self-cloned from here. A bootstrap clone in init.lua fetches whatever HEAD
-- is that day, which is the one thing this config is not allowed to do.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.notify(
    "lazy.nvim is missing. Install it with:  make apply TAGS=editor\n"
      .. "(expected at " .. lazypath .. ")",
    vim.log.levels.ERROR
  )
  return
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  spec = { { import = "plugins" } },
  -- The lockfile lives WITH the config, which is what makes `make apply` able
  -- to restore it. `:Lazy update` rewrites this copy; copy it back into
  -- roles/editor/files/nvim/lazy-lock.json and commit to move both nodes.
  lockfile = vim.fn.stdpath("config") .. "/lazy-lock.json",
  install = { colorscheme = { "vscode" } },
  -- Off on purpose. A background update check on a box that is meant to match
  -- its twin is an invitation to drift, and it costs a network round trip on
  -- every start of an editor that is usually opened over SSH.
  checker = { enabled = false },
  change_detection = { enabled = false, notify = false },
  ui = { border = "rounded" },
  performance = {
    rtp = {
      disabled_plugins = { "gzip", "tarPlugin", "tohtml", "zipPlugin", "tutor", "netrwPlugin" },
    },
  },
})

-- Last, so it outranks everything above. dofile rather than require: this path
-- is deliberately NOT on the runtimepath, because the runtimepath is the
-- deployed tree and the whole point of this file is to live outside it.
local override = vim.fs.joinpath(vim.env.HOME or "", ".config", "nvim-local", "init.lua")
if vim.uv.fs_stat(override) then
  local ok, err = pcall(dofile, override)
  if not ok then
    vim.notify("nvim-local/init.lua: " .. tostring(err), vim.log.levels.ERROR)
  end
end
