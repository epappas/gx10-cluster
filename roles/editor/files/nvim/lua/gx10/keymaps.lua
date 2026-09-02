-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
--
-- Only the maps that must exist whether or not a plugin loaded. Everything
-- owned by a plugin is declared in that plugin's `keys =` block instead, which
-- is what lets the plugin stay unloaded until the key is pressed.
--
-- The leader is <Space>. Press it and wait: which-key lists what is under it,
-- so this file is a starting point rather than something to memorise.
local map = vim.keymap.set

-- --- Basics ----------------------------------------------------------------
map("n", "<Esc>", "<cmd>nohlsearch<cr>", { desc = "Clear search highlight" })
map({ "n", "i", "v" }, "<C-s>", "<cmd>write<cr><esc>", { desc = "Save" })
map("n", "<leader>w", "<cmd>write<cr>", { desc = "Save" })
map("n", "<leader>q", "<cmd>quit<cr>", { desc = "Quit window" })
map("n", "<leader>Q", "<cmd>qall<cr>", { desc = "Quit all" })

-- Undo break points. Without these, everything typed between `i` and <Esc> is
-- a SINGLE undo step, so one `u` after writing a paragraph deletes the whole
-- paragraph - which reads as "undo is broken" rather than as undo working
-- exactly as told. <C-g>u closes the current undo block, so `u` walks back a
-- sentence at a time instead.
--
-- This matters more here than in a stock editor because conform calls
-- `undojoin` before formatting on save: the reformat is folded into the same
-- undo step as the edit that preceded it, so a coarse block is coarser still.
for _, ch in ipairs({ ",", ".", ";", ":", "!", "?" }) do
  map("i", ch, ch .. "<C-g>u", { desc = "Undo break point" })
end

-- Keep the cursor put. n/N and <C-d>/<C-u> otherwise walk the view off the
-- screen and you re-orient after every jump.
map("n", "n", "nzzzv", { desc = "Next match, centred" })
map("n", "N", "Nzzzv", { desc = "Previous match, centred" })
map("n", "<C-d>", "<C-d>zz")
map("n", "<C-u>", "<C-u>zz")

-- Paste over a selection without losing the register. The default puts the
-- replaced text into "" and the next paste silently repeats it.
map("x", "p", [["_dP]], { desc = "Paste without clobbering the register" })
map({ "n", "v" }, "<leader>d", [["_d]], { desc = "Delete to the black hole" })

-- Keep the selection after indenting, so > > > works.
map("v", "<", "<gv")
map("v", ">", ">gv")
map("v", "J", ":m '>+1<cr>gv=gv", { desc = "Move selection down" })
map("v", "K", ":m '<-2<cr>gv=gv", { desc = "Move selection up" })

-- --- Windows and buffers ---------------------------------------------------
-- NOTE <C-h/j/k/l> are NOT mapped here. vim-tmux-navigator owns them, so the
-- same four keys cross the boundary between an nvim split and a tmux pane
-- without you having to know which one is next to you.
map("n", "<C-Up>", "<cmd>resize +2<cr>", { desc = "Taller" })
map("n", "<C-Down>", "<cmd>resize -2<cr>", { desc = "Shorter" })
map("n", "<C-Left>", "<cmd>vertical resize -4<cr>", { desc = "Narrower" })
map("n", "<C-Right>", "<cmd>vertical resize +4<cr>", { desc = "Wider" })
map("n", "<leader>-", "<C-w>s", { desc = "Split below" })
map("n", "<leader>|", "<C-w>v", { desc = "Split right" })

-- NOT <cmd>bdelete<cr>, which takes the WINDOW with it when there is nothing
-- else to show there - and the whole editor when that was the last window. See
-- gx10.buffer.
map("n", "<leader>bd", function() require("gx10.buffer").close() end, { desc = "Close buffer" })
map("n", "<leader>bD", function() require("gx10.buffer").close(0, true) end, { desc = "Close buffer, discard changes" })
map("n", "<leader>bo", function() require("gx10.buffer").close_others() end, { desc = "Close other buffers" })

map("n", "<S-l>", "<cmd>bnext<cr>", { desc = "Next buffer" })
map("n", "<S-h>", "<cmd>bprevious<cr>", { desc = "Previous buffer" })
map("n", "<leader>`", "<cmd>buffer #<cr>", { desc = "Last buffer" })

-- --- Terminal --------------------------------------------------------------
-- A :terminal buffer is the fallback, not the default - see gx10.tmux for why
-- the real shell lives in a tmux pane.
map("t", "<Esc><Esc>", [[<C-\><C-n>]], { desc = "Leave terminal mode" })

-- --- Diagnostics -----------------------------------------------------------
map("n", "[d", function() vim.diagnostic.jump({ count = -1 }) end, { desc = "Previous diagnostic" })
map("n", "]d", function() vim.diagnostic.jump({ count = 1 }) end, { desc = "Next diagnostic" })
map("n", "<leader>ld", vim.diagnostic.open_float, { desc = "Line diagnostics" })

-- --- Toggles ---------------------------------------------------------------
map("n", "<leader>uw", function() vim.opt.wrap = not vim.opt.wrap:get() end, { desc = "Wrap" })
map("n", "<leader>us", function() vim.opt.spell = not vim.opt.spell:get() end, { desc = "Spell" })
map("n", "<leader>un", function() vim.opt.relativenumber = not vim.opt.relativenumber:get() end, { desc = "Relative numbers" })
map("n", "<leader>ul", function() vim.opt.list = not vim.opt.list:get() end, { desc = "Whitespace" })
-- Folds are ENABLED but all open (foldlevel 99 in gx10.options), so this is
-- the switch for "stop folding entirely", not "open everything" - zR already
-- does that, and zM closes it all again.
map("n", "<leader>uz", function()
  vim.opt_local.foldenable = not vim.opt_local.foldenable:get()
  vim.notify("folds " .. (vim.opt_local.foldenable:get() and "on" or "off"))
end, { desc = "Folds" })
map("n", "<leader>ud", function()
  local on = vim.diagnostic.is_enabled()
  vim.diagnostic.enable(not on)
  vim.notify("diagnostics " .. (on and "off" or "on"))
end, { desc = "Diagnostics" })
map("n", "<leader>uh", function()
  local on = vim.lsp.inlay_hint.is_enabled({ bufnr = 0 })
  vim.lsp.inlay_hint.enable(not on, { bufnr = 0 })
end, { desc = "Inlay hints" })

-- --- tmux ------------------------------------------------------------------
-- The reason this config exists in the shape it does. <leader>t drives the
-- session these boxes are actually used from: panes, a runner, popups and the
-- session switcher, all without leaving the editor.
local tmux = require("gx10.tmux")
-- stylua: ignore start
map("n", "<leader>ts", function() tmux.split("-v") end,    { desc = "Shell pane below" })
map("n", "<leader>tv", function() tmux.split("-h") end,    { desc = "Shell pane right" })
map("n", "<leader>tw", tmux.window,                        { desc = "New tmux window here" })
map("n", "<leader>tc", tmux.prompt_run,                    { desc = "Run a command in the runner pane" })
map("n", "<leader>tr", tmux.rerun,                         { desc = "Re-run the last command" })
map("n", "<leader>tt", tmux.run_file,                      { desc = "Run THIS file (by filetype)" })
map("n", "<leader>tk", tmux.kill_runner,                   { desc = "Kill the runner pane" })
map("n", "<leader>tp", function() tmux.popup() end,        { desc = "Shell popup over the session" })
map("n", "<leader>tg", function() tmux.popup("git status; $SHELL") end, { desc = "Git popup" })
map("n", "<leader>tG", function() tmux.popup("gx10-top") end,           { desc = "gx10-top popup (all nodes)" })
map("n", "<leader>tf", tmux.sessionizer,                   { desc = "Switch tmux session (fzf)" })
map("n", "<leader>tz", tmux.zoom,                          { desc = "Zoom this tmux pane" })
-- stylua: ignore end

-- --- Data ------------------------------------------------------------------
-- <leader>x is the "look at this data" group; the rest of it (CSV table view,
-- the database UI) is declared with those plugins.
map("n", "<leader>xe", tmux.explore, { desc = "Open this file as a dataframe (pandas, in a pane)" })
