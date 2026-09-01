-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
--
-- Per-language plugins. Everything that is only a language SERVER lives in
-- lsp.lua; these are the ones that add a workflow.
return {
  -- --- Rust ----------------------------------------------------------------
  -- rustaceanvim rather than a plain lspconfig entry: it drives rust-analyzer
  -- through the extensions that are not in the LSP spec at all - expand macro,
  -- open Cargo.toml for a dependency, runnables/debuggables, and the
  -- "explain this error" flow that makes E0502 readable.
  --
  -- rust-analyzer itself comes from rustup (roles/dev_rust adds the component
  -- to the pinned toolchain), so it always matches the compiler that will be
  -- run - which the standalone binary does not.
  {
    "mrcjkb/rustaceanvim",
    ft = { "rust" },
    init = function()
      vim.g.rustaceanvim = {
        server = {
          default_settings = {
            ["rust-analyzer"] = {
              cargo = { allFeatures = true, buildScripts = { enable = true } },
              procMacro = { enable = true },
              checkOnSave = true,
              check = { command = "clippy", extraArgs = { "--no-deps" } },
              inlayHints = { lifetimeElisionHints = { enable = "skip_trivial" } },
            },
          },
        },
      }
    end,
    keys = {
      { "<leader>cr", "<cmd>RustLsp runnables<cr>", ft = "rust", desc = "Rust runnables" },
      { "<leader>cd", "<cmd>RustLsp debuggables<cr>", ft = "rust", desc = "Rust debuggables" },
      { "<leader>ce", "<cmd>RustLsp explainError<cr>", ft = "rust", desc = "Explain this error" },
      { "<leader>cm", "<cmd>RustLsp expandMacro<cr>", ft = "rust", desc = "Expand macro" },
      { "<leader>cp", "<cmd>RustLsp parentModule<cr>", ft = "rust", desc = "Parent module" },
    },
  },
  {
    "saecki/crates.nvim",
    event = { "BufRead Cargo.toml" },
    opts = { completion = { crates = { enabled = true } }, lsp = { enabled = true, actions = true, completion = true, hover = true } },
  },

  -- --- Go ------------------------------------------------------------------
  -- gopls does the language work (lsp.lua). go.nvim adds what it does not:
  -- struct tags, table-test scaffolding and interface stubs, which are most of
  -- what is tedious about writing Go by hand.
  --
  -- Not vim-go, which is the other obvious choice: its :GoUpdateBinaries
  -- installs a dozen unpinned tools from the internet on first run, which is
  -- the pattern this repo removed from three other roles. go.nvim leans on
  -- gopls, and gopls is installed by roles/dev_go at a pinned version.
  {
    "ray-x/go.nvim",
    dependencies = { "ray-x/guihua.lua" },
    ft = { "go", "gomod" },
    opts = {
      -- gopls is started by lsp.lua; go.nvim must not start a second one.
      lsp_cfg = false,
      lsp_inlay_hints = { enable = false },
      -- The formatter is conform's LSP fallback (gopls, with gofumpt on).
      -- Two format-on-save paths on one buffer is how you get a cursor that
      -- jumps a line every time you save.
      lsp_document_formatting = false,
      trouble = true,
    },
    keys = {
      { "<leader>ct", "<cmd>GoTestFunc<cr>", ft = "go", desc = "Test this function" },
      { "<leader>cT", "<cmd>GoTest<cr>", ft = "go", desc = "Test this package" },
      { "<leader>ca", "<cmd>GoAddTag<cr>", ft = "go", desc = "Add struct tags" },
      { "<leader>ci", "<cmd>GoImpl<cr>", ft = "go", desc = "Implement interface" },
      { "<leader>cf", "<cmd>GoFillStruct<cr>", ft = "go", desc = "Fill struct" },
    },
  },

  -- --- Markdown ------------------------------------------------------------
  -- Rendered IN the buffer - headings, tables, code blocks, callouts - rather
  -- than in a browser. These machines are edited over SSH; a preview plugin
  -- that opens localhost:8080 has nothing to open it on.
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown", "codecompanion" },
    dependencies = { "nvim-treesitter/nvim-treesitter", "nvim-tree/nvim-web-devicons" },
    opts = {
      completions = { lsp = { enabled = true } },
      heading = { sign = false },
      code = { sign = false, width = "block", right_pad = 2 },
    },
    keys = {
      { "<leader>um", "<cmd>RenderMarkdown toggle<cr>", desc = "Markdown rendering" },
    },
  },

  -- --- Data exploration ----------------------------------------------------
  -- CSV as a table: aligned columns, a header line that stays put, and
  -- <leader>xc to drop back to the raw text. Benchmark output on this box is
  -- CSV (roles/monitoring's gx10-sample writes it), so this is the format the
  -- machine's own history arrives in.
  {
    "hat0uma/csvview.nvim",
    ft = { "csv", "tsv" },
    cmd = { "CsvViewToggle", "CsvViewEnable" },
    opts = {
      parser = { comments = { "#", "//" } },
      view = { display_mode = "border", header_lnum = 1, sticky_header = { enabled = true } },
    },
    keys = {
      { "<leader>xc", "<cmd>CsvViewToggle<cr>", desc = "CSV table view" },
    },
  },

  -- SQL, against anything with a URL: duckdb over a parquet directory,
  -- sqlite, or postgres on another host. :DBUI keeps the connections and the
  -- queries as files, so an exploration survives the session it started in.
  {
    "kristijanhusak/vim-dadbod-ui",
    dependencies = {
      { "tpope/vim-dadbod", lazy = true },
      { "kristijanhusak/vim-dadbod-completion", ft = { "sql", "mysql", "plsql" }, lazy = true },
    },
    cmd = { "DBUI", "DBUIToggle", "DBUIAddConnection", "DBUIFindBuffer" },
    init = function()
      vim.g.db_ui_use_nerd_fonts = 1
      vim.g.db_ui_save_location = vim.fn.stdpath("data") .. "/dadbod_ui"
      vim.g.db_ui_execute_on_save = 0  -- :w saves the query; <leader>S runs it
    end,
    keys = {
      { "<leader>xd", "<cmd>DBUIToggle<cr>", desc = "Database UI" },
      { "<leader>xf", "<cmd>DBUIFindBuffer<cr>", desc = "Find DB buffer" },
    },
  },
}
