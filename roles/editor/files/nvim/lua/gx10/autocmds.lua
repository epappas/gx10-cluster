-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
local function group(name)
  return vim.api.nvim_create_augroup("gx10_" .. name, { clear = true })
end
local au = vim.api.nvim_create_autocmd

-- --- Filetypes -------------------------------------------------------------
-- Ansible is YAML plus a schema, and nothing in the file says so - which is
-- why an ansible language server that never activates is such a common
-- complaint. Two passes: the path, which catches this repo's layout and any
-- normal role tree, and then the content, which catches a playbook sitting
-- somewhere unusual.
vim.filetype.add({
  pattern = {
    [".*/tasks/.*%.ya?ml"] = "yaml.ansible",
    [".*/handlers/.*%.ya?ml"] = "yaml.ansible",
    [".*/roles/.*/.*%.ya?ml"] = "yaml.ansible",
    [".*/playbooks/.*%.ya?ml"] = "yaml.ansible",
    [".*/group_vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/host_vars/.*%.ya?ml"] = "yaml.ansible",
    [".*/molecule/.*%.ya?ml"] = "yaml.ansible",
    ["requirements%-.*%.txt"] = "requirements",
    [".*/%.env%..*"] = "sh",
  },
})

-- The content pass. `hosts:` at the top level of a document, or any
-- fully-qualified module name, is as good a signal as exists.
au("FileType", {
  group = group("ansible"),
  pattern = "yaml",
  callback = function(ev)
    local head = table.concat(vim.api.nvim_buf_get_lines(ev.buf, 0, 40, false), "\n")
    if head:match("\n%s*hosts:") or head:match("^%s*hosts:") or head:match("ansible%.builtin%.") then
      vim.bo[ev.buf].filetype = "yaml.ansible"
    end
  end,
})

-- Go is tabs, and gofmt will undo anything else on the next save.
au("FileType", {
  group = group("go"),
  pattern = "go",
  callback = function()
    vim.bo.expandtab = false
    vim.bo.tabstop = 4
    vim.bo.shiftwidth = 4
  end,
})

-- Prose settings for prose.
au("FileType", {
  group = group("prose"),
  pattern = { "markdown", "gitcommit", "text" },
  callback = function()
    vim.opt_local.wrap = true
    vim.opt_local.spell = true
    vim.opt_local.conceallevel = 2
  end,
})

-- q closes the throwaway windows, which otherwise need :q and a moment of
-- thinking about which window has focus.
au("FileType", {
  group = group("quickclose"),
  pattern = { "help", "man", "qf", "checkhealth", "lspinfo", "notify", "query", "dbout" },
  callback = function(ev)
    vim.bo[ev.buf].buflisted = false
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = ev.buf, silent = true })
  end,
})

-- --- Editing behaviour -----------------------------------------------------
au("TextYankPost", {
  group = group("yank"),
  callback = function() vim.hl.on_yank({ timeout = 150 }) end,
})

-- Reopen where you left off. Skipped for commit messages, where the top is
-- always where you want to be.
au("BufReadPost", {
  group = group("lastpos"),
  callback = function(ev)
    if vim.bo[ev.buf].filetype == "gitcommit" then return end
    local mark = vim.api.nvim_buf_get_mark(ev.buf, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(ev.buf) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})

-- :w into a directory that does not exist yet writes nothing and says
-- "E212: Can't open file for writing", which is a poor way to learn you typoed
-- a path. Create it instead.
au("BufWritePre", {
  group = group("mkdir"),
  callback = function(ev)
    if ev.match:match("^%w%w+://") then return end
    vim.fn.mkdir(vim.fs.dirname(vim.uv.fs_realpath(ev.match) or ev.match), "p")
  end,
})

-- Something else changed the file - a `git checkout` in the pane next door,
-- or ansible rewriting the config you are looking at. Reload it rather than
-- letting the buffer silently go stale.
au({ "FocusGained", "TermClose", "TermLeave" }, {
  group = group("checktime"),
  callback = function()
    if vim.o.buftype ~= "nofile" then vim.cmd.checktime() end
  end,
})

-- --- Big files -------------------------------------------------------------
-- A multi-hundred-megabyte JSONL of eval outputs is a normal thing to open
-- here, and treesitter parsing it will lock the UI for minutes. Turn off
-- everything that scales with file size and say so, rather than appearing to
-- hang.
au("BufReadPre", {
  group = group("bigfile"),
  callback = function(ev)
    local ok, stat = pcall(vim.uv.fs_stat, vim.api.nvim_buf_get_name(ev.buf))
    if not ok or not stat or stat.size < (vim.g.gx10_big_file_bytes or 1024 * 1024) then
      return
    end
    vim.b[ev.buf].gx10_big_file = true
    vim.bo[ev.buf].swapfile = false
    vim.bo[ev.buf].undofile = false
    vim.opt_local.foldmethod = "manual"
    vim.schedule(function()
      vim.bo[ev.buf].syntax = ""
      vim.notify(
        ("%.0f MB: syntax, treesitter and LSP are off for this buffer"):format(stat.size / 1024 / 1024),
        vim.log.levels.WARN
      )
    end)
  end,
})

-- --- tmux ------------------------------------------------------------------
-- Name the tmux window after what is open in it, so the status bar at the top
-- of the screen tells you which window has which file - which is the whole
-- reason to have a window list. Restored on exit, so the shell gets its
-- automatic name back.
if vim.env.TMUX then
  au({ "BufEnter", "VimEnter" }, {
    group = group("tmux_title"),
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name == "" or vim.bo[ev.buf].buftype ~= "" then return end
      vim.system({ "tmux", "rename-window", "n:" .. vim.fs.basename(name) })
    end,
  })
  au("VimLeavePre", {
    group = group("tmux_title_restore"),
    callback = function()
      vim.system({ "tmux", "set-window-option", "automatic-rename", "on" }):wait()
    end,
  })
end
