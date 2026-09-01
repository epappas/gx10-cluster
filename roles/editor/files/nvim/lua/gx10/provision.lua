-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
--
-- The entry points roles/editor calls headlessly. Everything here is
-- synchronous and reports a non-zero exit on failure - a provisioning step
-- that finishes before its own work does is a step that always passes.
local M = {}

--- Compile every parser in gx10.parsers, and prove each one can actually
--- highlight. Called as:
---   nvim --headless -c 'lua require("gx10.provision").parsers()' +qa
---   nvim --headless -c 'lua require("gx10.provision").parsers({check = true})' +qa
--- @param opts table|nil { check = true } verifies and installs nothing
function M.parsers(opts)
  opts = opts or {}

  -- A parser on its own highlights NOTHING. The .so and the query files are
  -- installed by separate steps of the same operation, and one can land
  -- without the other: this box had yaml.so with no queries/yaml directory,
  -- so every YAML buffer opened with a treesitter highlighter attached, zero
  -- captures, and an indentexpr that returned 0 for a list item. It looks
  -- exactly like "treesitter is not working" and passed every check that only
  -- asked whether the parser was installed.
  --
  -- The FILE, not vim.treesitter.query.get. get caches its answer for the life
  -- of the process, including a negative one - so the check below would call
  -- it, install the missing queries, call it again and be handed the cached
  -- nil, reporting a failure it had just fixed. (Observed, before this line
  -- looked like this.)
  --
  -- Searching the runtimepath also covers the languages neovim bundles, whose
  -- queries are in $VIMRUNTIME rather than under site/.
  local function can_highlight(lang)
    return #vim.api.nvim_get_runtime_file("queries/" .. lang .. "/highlights.scm", false) > 0
  end

  local want = require("gx10.parsers")
  local have = require("nvim-treesitter.config").get_installed("parsers")
  local missing, unqueried = {}, {}
  for _, lang in ipairs(want) do
    if not vim.tbl_contains(have, lang) then
      missing[#missing + 1] = lang
    elseif not can_highlight(lang) then
      unqueried[#unqueried + 1] = lang
    end
  end

  local broken = vim.list_extend(vim.list_slice(missing), unqueried)
  if #broken == 0 then
    print("parsers: all " .. #want .. " present, with queries")
    return
  end

  if opts.check then
    io.stderr:write("parsers: incomplete:\n")
    for _, lang in ipairs(missing) do io.stderr:write("  " .. lang .. ": not installed\n") end
    for _, lang in ipairs(unqueried) do io.stderr:write("  " .. lang .. ": parser but no highlight queries\n") end
    os.exit(1)
  end

  if vim.fn.executable("tree-sitter") == 0 then
    io.stderr:write("tree-sitter CLI not found - parsers cannot be compiled\n")
    os.exit(1)
  end

  print("parsers: installing " .. table.concat(broken, " "))
  -- force, and this is the point: plain install() skips a language whose
  -- parser is already there, which is precisely the half-installed case above,
  -- so without force the repair is a no-op that reports success.
  --
  -- 20 minutes. Compiling 35 grammars on this hardware takes about two, but a
  -- cold apt cache and a slow mirror can stretch the downloads.
  require("nvim-treesitter").install(broken, { force = true }):wait(1200000)

  have = require("nvim-treesitter.config").get_installed("parsers")
  local failed = {}
  for _, lang in ipairs(broken) do
    if not vim.tbl_contains(have, lang) then
      failed[#failed + 1] = lang .. " (no parser)"
    elseif not can_highlight(lang) then
      failed[#failed + 1] = lang .. " (no queries)"
    end
  end
  if #failed > 0 then
    io.stderr:write("parsers: FAILED to install " .. table.concat(failed, ", ") .. "\n")
    os.exit(1)
  end
  print("parsers: installed " .. #broken)
end

--- Assert every plugin is installed AT THE COMMIT IN lazy-lock.json.
--- Called after `Lazy! restore`, which reports its failures to a UI that
--- headless neovim does not have and then exits 0 regardless - so without this
--- a half-restored plugin tree provisions "successfully" and the editor is
--- quietly missing whatever failed to clone.
function M.plugins()
  local lockfile = vim.fs.joinpath(vim.fn.stdpath("config"), "lazy-lock.json")
  local ok, lock = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(lockfile), "\n"))
  end)
  if not ok or type(lock) ~= "table" then
    io.stderr:write("plugins: cannot read " .. lockfile .. "\n")
    os.exit(1)
  end

  local root = vim.fs.joinpath(vim.fn.stdpath("data"), "lazy")
  local wrong = {}
  local count = 0
  for name, info in pairs(lock) do
    -- lazy.nvim is the one plugin the lockfile does NOT own: ansible clones it
    -- at the tag in lazy_nvim_version and re-checks that tag out on every
    -- apply, so its version has a source of truth already. lazy writes itself
    -- into the lockfile anyway whenever :Lazy sync runs, and the two then
    -- disagree - which is what this skip (and the missing entry in the
    -- committed lockfile) exists to prevent.
    if name == "lazy.nvim" then goto continue end
    count = count + 1
    local dir = vim.fs.joinpath(root, name)
    if vim.fn.isdirectory(dir) == 0 then
      wrong[#wrong + 1] = name .. ": not installed"
    else
      local head = vim.system({ "git", "-C", dir, "rev-parse", "HEAD" }, { text = true }):wait()
      local at = (head.stdout or ""):gsub("%s+$", "")
      if at ~= info.commit then
        wrong[#wrong + 1] = ("%s: at %s, locked to %s"):format(name, at:sub(1, 8), info.commit:sub(1, 8))
      end
    end
    ::continue::
  end

  if #wrong > 0 then
    table.sort(wrong)
    io.stderr:write("plugins: not at their locked commits:\n  " .. table.concat(wrong, "\n  ") .. "\n")
    os.exit(1)
  end
  print("plugins: all " .. count .. " at their locked commits")
end

--- Report anything the config needs that is not on this box. Used by
--- verify.yml, and by hand when something is quietly not working.
function M.doctor()
  local wanted = {
    ["tree-sitter"] = "treesitter parsers (group_vars: tree_sitter_version)",
    ["lua-language-server"] = "lua",
    ["pyright-langserver"] = "python types",
    ruff = "python lint and format",
    gopls = "go",
    ["rust-analyzer"] = "rust",
    ["bash-language-server"] = "bash",
    ["vscode-json-language-server"] = "json",
    ["yaml-language-server"] = "yaml",
    ["ansible-language-server"] = "ansible",
    ["ansible-lint"] = "ansible diagnostics",
    ["terraform-ls"] = "terraform",
    marksman = "markdown",
    prettier = "json/yaml/markdown formatting",
    shfmt = "shell formatting",
    shellcheck = "shell diagnostics",
  }
  local missing = {}
  for bin, what in pairs(wanted) do
    if vim.fn.executable(bin) == 0 then missing[#missing + 1] = bin .. " (" .. what .. ")" end
  end
  table.sort(missing)
  if #missing > 0 then
    io.stderr:write("missing:\n  " .. table.concat(missing, "\n  ") .. "\n")
    os.exit(1)
  end
  print("editor: every language server and tool is present")
end

return M
