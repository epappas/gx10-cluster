-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
local opt = vim.opt

opt.number = true
opt.relativenumber = true
opt.signcolumn = "yes"        -- reserved, so diagnostics do not shift the text
opt.cursorline = true
opt.termguicolors = true
opt.mouse = "a"
opt.showmode = false          -- lualine already says it
opt.laststatus = 3            -- one status line for the whole window layout
opt.splitright = true
opt.splitbelow = true
opt.scrolloff = 8
opt.sidescrolloff = 8
opt.wrap = false
opt.linebreak = true          -- when wrap is on (markdown), break on words

-- Two spaces: this repo is YAML and Lua, and both want two. Go is tabs and
-- says so in its own ftplugin (see gx10.autocmds).
opt.expandtab = true
opt.shiftwidth = 2
opt.tabstop = 2
opt.softtabstop = 2
opt.smartindent = true
opt.shiftround = true

opt.ignorecase = true
opt.smartcase = true          -- a capital in the pattern makes it case-sensitive
opt.inccommand = "split"      -- live preview of :s, in a split
opt.hlsearch = true

-- Undo that survives a reboot. On a box you reach over SSH and reattach to
-- days later, session-scoped undo is the wrong default.
opt.undofile = true
opt.swapfile = false
opt.backup = false
opt.updatetime = 200          -- CursorHold, gitsigns and LSP highlight delay
opt.timeoutlen = 400          -- how long which-key waits before showing itself
opt.confirm = true            -- ask rather than refuse to abandon a dirty buffer

opt.completeopt = { "menu", "menuone", "noselect" }
opt.pumheight = 12
opt.winborder = "rounded"     -- 0.11+: floats get a border without per-plugin config

opt.list = true
opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
opt.fillchars = { eob = " " }

-- Folds from treesitter, but everything open on entry. Files that arrive
-- folded shut are the fastest way to make an editor feel broken.
opt.foldmethod = "expr"
opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
opt.foldlevel = 99
opt.foldenable = true

-- Big-file guard. A 200 MB JSONL of eval outputs is a plausible thing to open
-- on this box, and treesitter + LSP on it will hang the UI; gx10.autocmds
-- turns them off past this size.
vim.g.gx10_big_file_bytes = 1024 * 1024

-- --- Clipboard -------------------------------------------------------------
-- OSC 52, explicitly, whenever this is a remote session. Neovim autodetects it
-- when $SSH_TTY is set, but NOT when you have simply attached to a tmux
-- session that outlived the SSH login that started it - which is the normal
-- way to use these boxes. tmux.conf already sets `set-clipboard on`, so the
-- sequence reaches the local terminal from inside the pane.
--
-- Paste is deliberately left alone: OSC 52 reads are refused by most
-- terminals, so `"+p` would hang waiting for a reply that never comes. Use the
-- terminal's own paste, which arrives as typed input.
if vim.env.SSH_TTY or vim.env.TMUX then
  vim.g.clipboard = {
    name = "OSC 52",
    copy = {
      ["+"] = require("vim.ui.clipboard.osc52").copy("+"),
      ["*"] = require("vim.ui.clipboard.osc52").copy("*"),
    },
    paste = {
      ["+"] = function() return { vim.fn.split(vim.fn.getreg('"'), "\n"), vim.fn.getregtype('"') } end,
      ["*"] = function() return { vim.fn.split(vim.fn.getreg('"'), "\n"), vim.fn.getregtype('"') } end,
    },
  }
end

-- --- Diagnostics -----------------------------------------------------------
vim.diagnostic.config({
  -- Virtual LINES rather than virtual text: an ansible-lint or rust-analyzer
  -- message is routinely 200 characters, and virtual text truncates it into
  -- something you have to hover to read.
  virtual_text = false,
  virtual_lines = { current_line = true },
  severity_sort = true,
  underline = true,
  update_in_insert = false,
  float = { border = "rounded", source = true },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = "E",
      [vim.diagnostic.severity.WARN] = "W",
      [vim.diagnostic.severity.INFO] = "I",
      [vim.diagnostic.severity.HINT] = "H",
    },
  },
})
