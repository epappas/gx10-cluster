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

--- nvm keeps node under ~/.nvm/versions/node/<version>/bin and selects one
--- with a shell function, which no non-shell process inherits. The `default`
--- alias file holds the version roles/dev_node aliased, so this resolves the
--- same node the shell would have used.
local function nvm_bin()
  local alias = home .. "/.nvm/alias/default"
  local fd = io.open(alias, "r")
  if not fd then return nil end
  local want = (fd:read("l") or ""):gsub("%s+", "")
  fd:close()
  if want == "" then return nil end
  -- The alias is usually a major ("22") and the directory is the full version,
  -- so match on the prefix rather than requiring an exact name.
  local root = home .. "/.nvm/versions/node"
  for name, kind in vim.fs.dir(root) do
    if kind == "directory" and (name == want or name == "v" .. want or vim.startswith(name, "v" .. want .. ".")) then
      return root .. "/" .. name .. "/bin"
    end
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
