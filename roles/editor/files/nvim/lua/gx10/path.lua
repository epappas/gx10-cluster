-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
--
-- Every language server here is installed by ansible into one of five places,
-- and neovim has to find them whether or not the shell that launched it had
-- sourced ~/.gx10env.sh. It often has not: `git commit` runs $EDITOR from a
-- non-login shell, and so does anything launched by a systemd unit or by
-- another editor's terminal.
--
-- So the paths are prepended here rather than assumed. This is additive and
-- idempotent - an entry already in $PATH is left where it is.
local M = {}

local home = vim.env.HOME or vim.uv.os_homedir()

local nvm_root = home .. "/.nvm"

local function first_line(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local line = (fd:read("l") or ""):gsub("%s+", "")
  fd:close()
  return line ~= "" and line or nil
end

--- Every installed version directory, newest first. The sort is numeric per
--- component on purpose: sorted as strings, v9 beats v25.
local function installed_versions()
  local root = nvm_root .. "/versions/node"
  local found = {}
  if not vim.uv.fs_stat(root) then return found end
  for name, kind in vim.fs.dir(root) do
    if kind == "directory" and name:match("^v%d+%.%d+%.%d+$") then
      found[#found + 1] = name
    end
  end
  table.sort(found, function(a, b)
    local ax, ay, az = a:match("^v(%d+)%.(%d+)%.(%d+)$")
    local bx, by, bz = b:match("^v(%d+)%.(%d+)%.(%d+)$")
    if ax ~= bx then return tonumber(ax) > tonumber(bx) end
    if ay ~= by then return tonumber(ay) > tonumber(by) end
    return tonumber(az) > tonumber(bz)
  end)
  return found
end

--- nvm keeps node under ~/.nvm/versions/node/<version>/bin and selects one
--- with a shell function, which no non-shell process inherits. So the version
--- the shell WOULD have used is worked out here, from the files nvm reads.
---
--- ~/.nvm/alias/default does not have to name a version, and on a box nobody
--- provisioned with roles/dev_node it usually does not: it names another
--- alias. `node` and `stable` mean "the newest installed"; `lts/*` is a file
--- pointing at `lts/jod`, which is a file pointing at v22.22.3. Each hop is a
--- file of its own under ~/.nvm/alias/.
---
--- The previous version of this read `default` and matched it straight against
--- the directory names, so on any of those boxes it returned nil - no node on
--- PATH, and five language servers whose `#!/usr/bin/env node` shebang cannot
--- start. That is a failure with no error message anywhere: the servers are
--- installed, the editor attaches nothing, and `:checkhealth` is happy.
local function nvm_bin()
  local want = first_line(nvm_root .. "/alias/default")
  local have = installed_versions()
  if not want or #have == 0 then return nil end

  -- Bounded: nothing stops a hand-edited alias file pointing at itself.
  for _ = 1, 10 do
    if want == "node" or want == "stable" then
      return nvm_root .. "/versions/node/" .. have[1] .. "/bin"
    end
    -- A version, exact or a prefix - "22" selects v22.22.3. Newest match
    -- wins, which is nvm's own rule and why `have` is sorted.
    local prefix = "v" .. want:gsub("^v", "")
    for _, name in ipairs(have) do
      if name == prefix or vim.startswith(name, prefix .. ".") then
        return nvm_root .. "/versions/node/" .. name .. "/bin"
      end
    end
    local next_want = first_line(nvm_root .. "/alias/" .. want)
    if not next_want or next_want == want then return nil end
    want = next_want
  end
  return nil
end

function M.setup()
  -- HIGHEST priority first. Note the loop below walks this backwards, because
  -- each entry is prepended - listing them in the order they should be
  -- searched is worth one reversed loop.
  --
  -- The order between the last two is the one that matters. nvm's global bin
  -- may still hold a copy of a language server from an older deploy, and it
  -- must not shadow the versioned set in ~/.local/lib/gx10-npm - otherwise
  -- bumping a server moves a symlink and changes nothing you can observe.
  local dirs = {
    home .. "/.local/bin",              -- uv tools: ruff, ansible-lint, yamllint
    home .. "/.cargo/bin",              -- rustup shims: rust-analyzer, rustfmt
    home .. "/go/bin",                  -- symlink to ~/go/versions/gopls-<version>
    home .. "/.local/lib/gx10-npm/bin", -- the yaml, json, bash, ansible and python servers
    "/usr/local/bin",                   -- symlinks to the versioned trees in /opt
    -- node ITSELF, which the servers above need: their shebang is
    -- `#!/usr/bin/env node`, so putting the servers on PATH without node gets
    -- you five servers that all fail to start.
    nvm_bin(),
  }
  local path = vim.env.PATH or ""
  for i = #dirs, 1, -1 do
    local dir = dirs[i]
    if dir and vim.uv.fs_stat(dir) and not (":" .. path .. ":"):find(":" .. dir .. ":", 1, true) then
      path = dir .. ":" .. path
    end
  end
  vim.env.PATH = path
end

return M
