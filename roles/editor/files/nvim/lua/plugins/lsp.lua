-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
--
-- Language servers, formatters and linters.
--
-- THERE IS NO mason.nvim HERE, deliberately. mason downloads server binaries
-- on first use, unpinned, from whatever the registry points at that day - the
-- same `curl | sh` shape this repo removed from three other roles. It is also
-- a poor fit for this hardware specifically: a good half of its registry ships
-- x86_64 assets only, so on aarch64 you get an install that appears to succeed
-- and a server that never starts.
--
-- Instead roles/editor installs every server from a pinned release, and the
-- list below only says how to CONFIGURE them. `:GX10Servers` shows which ones
-- were found on this box.
return {
  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = { "b0o/SchemaStore.nvim" },
    config = function()
      -- Per-server settings. Neovim 0.11+ merges these over the defaults that
      -- nvim-lspconfig ships in its own lsp/<name>.lua, so only the deltas
      -- belong here - no cmd, no root markers, no filetypes.
      local servers = {
        -- Editing this config, and roles/editor's own lua.
        lua_ls = {
          settings = {
            Lua = {
              runtime = { version = "LuaJIT" },
              workspace = { checkThirdParty = false },
              -- Without this every `vim.` in this config is an undefined
              -- global, which is 200 false diagnostics in the one tree you
              -- most want clean.
              diagnostics = { globals = { "vim" } },
              telemetry = { enable = false },
              format = { enable = true, defaultConfig = { indent_style = "space", indent_size = "2" } },
            },
          },
        },

        -- Python: types from pyright, lint and format from ruff. Two servers
        -- on purpose - ruff is far faster at what it does and pyright does
        -- not do it at all - with pyright's own linter turned off so the same
        -- unused import is not reported twice in two wordings.
        pyright = {
          settings = {
            python = {
              analysis = {
                typeCheckingMode = "basic",
                diagnosticMode = "openFilesOnly",
                autoSearchPaths = true,
                useLibraryCodeForTypes = true,
              },
            },
          },
        },
        ruff = {
          -- Hover belongs to pyright; ruff's is a stub that would win by
          -- attaching second.
          on_attach = function(client) client.server_capabilities.hoverProvider = false end,
        },

        gopls = {
          settings = {
            gopls = {
              gofumpt = true,
              staticcheck = true,
              usePlaceholders = true,
              analyses = { unusedparams = true, shadow = true, nilness = true },
              hints = {
                assignVariableTypes = true,
                compositeLiteralFields = true,
                constantValues = true,
                parameterNames = true,
                rangeVariableTypes = true,
              },
            },
          },
        },

        bashls = {
          -- Every shell script in this repo is bash and shellcheck already
          -- gates them in CI; this is the same check while you type.
          settings = { bashIde = { shellcheckPath = "shellcheck" } },
        },

        jsonls = {
          settings = {
            json = {
              -- SchemaStore is a plugin, not a download: package.json,
              -- .github/workflows, tsconfig and ~700 others get validation and
              -- completion with no network call at open time.
              schemas = require("schemastore").json.schemas(),
              validate = { enable = true },
            },
          },
        },

        yamlls = {
          settings = {
            yaml = {
              schemaStore = { enable = false, url = "" }, -- superseded by the plugin below
              schemas = require("schemastore").yaml.schemas(),
              keyOrdering = false,   -- alphabetical keys in a playbook is not a rule anyone wants
              format = { enable = false }, -- prettier does this, via conform
              validate = true,
            },
            -- redhat.telemetry is on by default in this server.
            redhat = { telemetry = { enabled = false } },
          },
        },

        -- Ansible. The server shells out to ansible-lint and ansible-doc, both
        -- of which roles/editor installs as pinned uv tools, so module
        -- documentation on hover and lint-on-save work against the same
        -- ansible-core that `make check` uses.
        ansiblels = {
          settings = {
            ansible = {
              validation = { enabled = true, lint = { enabled = true, path = "ansible-lint" } },
              ansible = { path = "ansible" },
              python = { interpreterPath = "python3" },
            },
          },
        },

        terraformls = {},
        marksman = {},
      }

      for name, config in pairs(servers) do
        vim.lsp.config(name, config)
      end
      -- rust_analyzer is deliberately NOT in this list: rustaceanvim starts
      -- and configures it, and enabling it here too would attach two clients
      -- to every Rust buffer.
      vim.lsp.enable(vim.tbl_keys(servers))

      -- Which servers this box actually has. The list above is aspirational
      -- until the play has run; when something is silently not attaching this
      -- is the first thing to look at.
      vim.api.nvim_create_user_command("GX10Servers", function()
        local lines = { "server           binary                          state" }
        local cmds = {
          lua_ls = "lua-language-server", pyright = "pyright-langserver", ruff = "ruff",
          gopls = "gopls", bashls = "bash-language-server", jsonls = "vscode-json-language-server",
          yamlls = "yaml-language-server", ansiblels = "ansible-language-server",
          terraformls = "terraform-ls", marksman = "marksman", rust_analyzer = "rust-analyzer",
        }
        local attached = {}
        for _, client in pairs(vim.lsp.get_clients()) do attached[client.name] = true end
        for _, name in ipairs(vim.fn.sort(vim.tbl_keys(cmds))) do
          local bin = cmds[name]
          local found = vim.fn.exepath(bin)
          lines[#lines + 1] = ("%-16s %-31s %s"):format(
            name, bin,
            found == "" and "MISSING - make apply TAGS=editor"
              or (attached[name] and "attached" or "installed")
          )
        end
        vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "gx10 language servers" })
      end, { desc = "Which language servers are installed and attached" })

      -- Buffer-local maps, set when a server attaches rather than globally:
      -- gd in a file with no server should stay vim's own gd.
      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("gx10_lsp_attach", { clear = true }),
        callback = function(ev)
          local function map(lhs, rhs, desc, mode)
            vim.keymap.set(mode or "n", lhs, rhs, { buffer = ev.buf, desc = desc })
          end
          map("gd", vim.lsp.buf.definition, "Go to definition")
          map("gD", vim.lsp.buf.declaration, "Go to declaration")
          map("gr", vim.lsp.buf.references, "References")
          map("gi", vim.lsp.buf.implementation, "Implementation")
          map("gy", vim.lsp.buf.type_definition, "Type definition")
          map("K", vim.lsp.buf.hover, "Hover")
          map("<leader>lr", vim.lsp.buf.rename, "Rename symbol")
          map("<leader>la", vim.lsp.buf.code_action, "Code action", { "n", "v" })
          map("<leader>ll", "<cmd>checkhealth vim.lsp<cr>", "LSP health")
          map("<leader>lR", function() vim.cmd("LspRestart") end, "Restart servers")

          local client = vim.lsp.get_client_by_id(ev.data.client_id)
          -- Inlay hints on where the server offers them. They are the reason
          -- to run gopls and rust-analyzer at all on unfamiliar code.
          if client and client:supports_method("textDocument/inlayHint") then
            vim.lsp.inlay_hint.enable(true, { bufnr = ev.buf })
          end
        end,
      })
    end,
  },

  -- Formatting. Every formatter here is installed by the play; conform falls
  -- back to the language server when no external one is configured, which is
  -- what covers Lua, Go and Rust.
  {
    "stevearc/conform.nvim",
    event = "BufWritePre",
    cmd = "ConformInfo",
    keys = {
      { "<leader>lf", function() require("conform").format({ async = true, lsp_format = "fallback" }) end,
        mode = { "n", "v" }, desc = "Format buffer" },
      { "<leader>uf", function()
          vim.g.gx10_format_on_save = not vim.g.gx10_format_on_save
          vim.notify("format on save " .. (vim.g.gx10_format_on_save and "on" or "off"))
        end, desc = "Format on save" },
    },
    init = function()
      vim.g.gx10_format_on_save = true
      vim.o.formatexpr = "v:lua.require'conform'.formatexpr()"
    end,
    opts = {
      formatters_by_ft = {
        python = { "ruff_fix", "ruff_format", "ruff_organize_imports" },
        sh = { "shfmt" },
        bash = { "shfmt" },
        json = { "prettier" },
        jsonc = { "prettier" },
        yaml = { "prettier" },
        ["yaml.ansible"] = { "prettier" },
        markdown = { "prettier" },
        -- Deliberately absent: terraform. `terraform fmt` needs the terraform
        -- binary, which is not installed here - terraform-ls alone is enough
        -- to READ and navigate HCL, which is what an ML cluster needs it for.
      },
      format_on_save = function(buf)
        if not vim.g.gx10_format_on_save or vim.b[buf].gx10_big_file then return end
        return { timeout_ms = 2000, lsp_format = "fallback" }
      end,
      formatters = {
        -- Two spaces and a simplified script, matching the shell scripts this
        -- repo ships and what shellcheck is run against in CI.
        shfmt = { prepend_args = { "-i", "2", "-ci", "-s" } },
      },
    },
  },

  -- Linters the language servers do not run themselves.
  {
    "mfussenegger/nvim-lint",
    event = { "BufReadPost", "BufWritePost" },
    config = function()
      local lint = require("lint")
      lint.linters_by_ft = {
        -- yaml.ansible is linted by ansible-language-server already; this is
        -- the plain-YAML case (CI workflows, docker compose, group_vars in a
        -- tree with no roles/ next to it).
        yaml = { "yamllint" },
        markdown = { "markdownlint" },
      }
      -- shellcheck is bash-language-server's job, and running it twice puts
      -- the same SC2086 on the line twice.
      local function try_lint()
        if vim.b.gx10_big_file then return end
        local names = lint.linters_by_ft[vim.bo.filetype] or {}
        local runnable = {}
        for _, name in ipairs(names) do
          local linter = lint.linters[name]
          local cmd = type(linter) == "table" and linter.cmd or name
          if vim.fn.executable(cmd) == 1 then runnable[#runnable + 1] = name end
        end
        if #runnable > 0 then lint.try_lint(runnable) end
      end
      vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave" }, {
        group = vim.api.nvim_create_augroup("gx10_lint", { clear = true }),
        callback = try_lint,
      })
    end,
  },

  { "b0o/SchemaStore.nvim", lazy = true, version = false },
}
