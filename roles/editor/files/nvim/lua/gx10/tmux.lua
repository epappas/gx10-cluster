-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
--
-- Driving the tmux session from inside neovim.
--
-- The point is that the editor and the shell are the SAME session: you open a
-- pane next to the file you are looking at, run the thing, and the output is
-- still there when you detach at the end of the day and reattach from a
-- different machine tomorrow. A :terminal buffer gives up all of that - it
-- dies with the nvim process, it is invisible to `tmux ls`, and it cannot be
-- watched from another window while you keep editing.
--
-- So everything here shells out to the tmux client rather than reimplementing
-- it. Keymaps are in gx10.keymaps under <leader>t.
local M = {}

-- The runner pane's tmux ID (%12). Not its index: indexes renumber when a pane
-- is closed, so an index remembered here would eventually send a command to
-- whatever pane inherited the number - which on this box could be the one with
-- a training run in it.
M.runner = nil
M.last_cmd = nil

local function warn(msg)
  vim.notify(msg, vim.log.levels.WARN, { title = "tmux" })
end

function M.available()
  return vim.env.TMUX ~= nil and vim.fn.executable("tmux") == 1
end

-- vim.system, not vim.fn.system: it takes an argv list, so a path with a space
-- in it needs no quoting and cannot be re-split by a shell.
local function tmux(args)
  local res = vim.system(vim.list_extend({ "tmux" }, args), { text = true }):wait()
  if res.code ~= 0 then
    warn("tmux " .. table.concat(args, " ") .. ": " .. (res.stderr or ""):gsub("%s+$", ""))
    return nil
  end
  return (res.stdout or ""):gsub("%s+$", "")
end

local function guard()
  if not M.available() then
    warn("not inside a tmux session - start one with `tn work` (alias for tmux new -s)")
    return false
  end
  return true
end

-- The directory the new pane should start in: the current file's, falling back
-- to nvim's cwd for scratch and plugin buffers.
local function cwd()
  local file = vim.api.nvim_buf_get_name(0)
  if file ~= "" and vim.fn.filereadable(file) == 1 then
    return vim.fs.dirname(file)
  end
  return vim.uv.cwd()
end

--- Split a shell pane next to this one.
--- @param orientation string "-h" (right) or "-v" (below)
function M.split(orientation)
  if not guard() then return end
  tmux({ "split-window", orientation, "-c", cwd() })
end

--- New tmux window, in the current file's directory.
function M.window()
  if not guard() then return end
  tmux({ "new-window", "-c", cwd() })
end

--- Is the remembered runner pane still alive?
local function runner_alive()
  if not M.runner then return false end
  local panes = tmux({ "list-panes", "-a", "-F", "#{pane_id}" })
  if not panes then return false end
  for _, id in ipairs(vim.split(panes, "\n", { trimempty = true })) do
    if id == M.runner then return true end
  end
  return false
end

--- The pane commands are sent to, created on first use.
--- 35% of the width, and focus stays HERE: the whole point is that you keep
--- typing in the editor while the command runs beside it.
function M.ensure_runner()
  if runner_alive() then return M.runner end
  local id = tmux({ "split-window", "-h", "-l", "35%", "-d", "-P", "-F", "#{pane_id}", "-c", cwd() })
  M.runner = id ~= "" and id or nil
  return M.runner
end

--- Run a shell command in the runner pane.
--- @param cmd string
function M.run(cmd)
  if not guard() then return end
  if not cmd or cmd == "" then return end
  local pane = M.ensure_runner()
  if not pane then return end
  M.last_cmd = cmd
  -- Write the buffer first. Running the tests against the version on disk
  -- while you are looking at a newer one in the editor is a genuinely
  -- confusing five minutes.
  if vim.bo.modifiable and vim.bo.modified and vim.api.nvim_buf_get_name(0) ~= "" then
    vim.cmd.write()
  end
  -- C-c first: if the pane is sitting in a REPL or a paused pager, send-keys
  -- would otherwise type the command into it.
  tmux({ "send-keys", "-t", pane, "C-c" })
  tmux({ "send-keys", "-t", pane, cmd, "Enter" })
end

function M.prompt_run()
  if not guard() then return end
  vim.ui.input({ prompt = "tmux run: ", default = M.last_cmd, completion = "shellcmd" }, function(cmd)
    if cmd then M.run(cmd) end
  end)
end

function M.rerun()
  if not M.last_cmd then
    return M.prompt_run()
  end
  M.run(M.last_cmd)
end

function M.kill_runner()
  if not guard() then return end
  if runner_alive() then
    tmux({ "kill-pane", "-t", M.runner })
  end
  M.runner = nil
end

--- Run something in a tmux popup over the whole session: git, a shell, htop.
--- -E closes the popup when the command exits.
--- @param cmd string|nil defaults to an interactive shell
function M.popup(cmd)
  if not guard() then return end
  tmux({ "display-popup", "-E", "-w", "90%", "-h", "85%", "-d", cwd(), cmd or vim.env.SHELL or "bash" })
end

--- The session switcher, in a popup. Shipped by roles/shell as
--- ~/.local/bin/gx10-sessionizer; it switches the CLIENT, so nvim keeps
--- running in the session you left.
function M.sessionizer()
  if not guard() then return end
  tmux({ "display-popup", "-E", "-w", "60%", "-h", "50%", "gx10-sessionizer" })
end

function M.zoom()
  if not guard() then return end
  tmux({ "resize-pane", "-Z" })
end

--- Send the current buffer's file to a pane as an argument - `python foo.py`,
--- `ansible-playbook foo.yml`. The command is picked per filetype, which is
--- what makes <leader>tt one key for every language here.
local runners = {
  python = "python",
  sh = "bash",
  bash = "bash",
  go = "go run",
  rust = "cargo run",
  lua = "nvim -l",
  yaml = "ansible-playbook --syntax-check",
  ["yaml.ansible"] = "ansible-playbook --syntax-check",
  terraform = "terraform validate",
  markdown = "glow",
}

function M.run_file()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" then
    return warn("this buffer has no file")
  end
  local runner = runners[vim.bo.filetype]
  if not runner then
    return M.prompt_run()
  end
  M.run(runner .. " " .. vim.fn.fnameescape(vim.fs.basename(file)))
end

--- Open the file under the cursor as a dataframe, in the runner pane.
---
--- The other half of the data-exploration loop: csvview.nvim (and dadbod for
--- SQL) shows you the file, this hands the same file to pandas in a REPL you
--- can keep talking to. It reads the ml venv, which is where pandas, pyarrow
--- and the rest already are.
function M.explore()
  local file = vim.api.nvim_buf_get_name(0)
  if file == "" or vim.fn.filereadable(file) == 0 then
    return warn("this buffer is not a file on disk")
  end
  local readers = {
    csv = "pd.read_csv(%s)",
    tsv = 'pd.read_csv(%s, sep="\\t")',
    parquet = "pd.read_parquet(%s)",
    json = "pd.read_json(%s)",
    jsonl = "pd.read_json(%s, lines=True)",
    ndjson = "pd.read_json(%s, lines=True)",
  }
  local ext = file:match("%.([%w]+)$")
  local reader = ext and readers[ext:lower()]
  if not reader then
    return warn("no pandas reader for ." .. (ext or "?") .. " - try <leader>rp for a bare ipython")
  end
  local expr = reader:format(("%q"):format(file))
  M.run(table.concat({
    ". ~/venvs/ml/bin/activate 2>/dev/null",
    ("ipython -i -c 'import pandas as pd; df = %s; print(df.dtypes); print(df.head())'"):format(expr),
  }, "; "))
end

return M
