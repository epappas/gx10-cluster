-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
return {
  -- VSCode Dark Modern. The colours are NOT only an editor setting: the tmux
  -- status bar in roles/shell/files/tmux.conf is written in the same hex
  -- values, so the top of the screen reads as one surface rather than showing
  -- a seam where the editor stops and tmux starts. Change the palette here and
  -- that file has to change in the same commit - it is listed at the top of
  -- tmux.conf for exactly that reason.
  {
    "Mofiqul/vscode.nvim",
    lazy = false,
    priority = 1000,
    opts = {
      style = "dark",
      transparent = false,
      -- VSCode italicises comments and this is the one place the terminal can
      -- disagree: an italic that renders as a colour swap is worse than none.
      -- Left on because the colour carries the meaning either way.
      italic_comments = true,
      underline_links = true,
      -- The file tree keeps the editor background instead of the darker panel
      -- one. Two backgrounds side by side in a terminal read as a rendering
      -- fault more often than as a design.
      disable_nvimtree_bg = true,
    },
    config = function(_, opts)
      require("vscode").setup(opts)
      vim.cmd.colorscheme("vscode")
    end,
  },

  -- Icons. They need a Nerd Font in the TERMINAL, which is a client-side
  -- setting no play here can make - see docs/runbooks/edit-code.md. Without
  -- one you get replacement boxes and nothing worse.
  { "nvim-tree/nvim-web-devicons", lazy = true },
  { "MunifTanjim/nui.nvim", lazy = true },
  { "nvim-lua/plenary.nvim", lazy = true },

  {
    "nvim-lualine/lualine.nvim",
    event = "VeryLazy",
    opts = function()
      return {
        options = {
          -- Set from the colourscheme, so the bar cannot drift from the
          -- editor the way a hardcoded flavour name did.
          theme = "vscode",
          globalstatus = true,             -- one bar, matching laststatus = 3
          section_separators = { left = "", right = "" },
          component_separators = { left = "|", right = "|" },
          disabled_filetypes = { statusline = { "dashboard", "alpha" } },
        },
        sections = {
          lualine_a = { "mode" },
          lualine_b = { "branch", { "diff", symbols = { added = "+", modified = "~", removed = "-" } } },
          lualine_c = {
            { "diagnostics", symbols = { error = "E", warn = "W", info = "I", hint = "H" } },
            { "filename", path = 1, symbols = { modified = " ●", readonly = " ro" } },
          },
          lualine_x = {
            -- Which language servers are actually attached. The single most
            -- common editor question on a box where the servers are installed
            -- by a play rather than by the editor is "is it even running", and
            -- this answers it without :LspInfo.
            {
              function()
                local names = {}
                for _, client in pairs(vim.lsp.get_clients({ bufnr = 0 })) do
                  names[#names + 1] = client.name
                end
                return table.concat(names, ",")
              end,
              icon = "lsp:",
              cond = function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end,
            },
            "encoding",
            "filetype",
          },
          lualine_y = { "progress" },
          lualine_z = { "location" },
        },
        -- Breadcrumbs, VSCode's line above the buffer. Deliberately the file
        -- PATH rather than LSP symbols: nvim-navic would add a plugin and 26
        -- symbol-kind icons that need a Nerd Font to render, and the enclosing
        -- function is already on screen - treesitter-context below sticks it
        -- to the top as you scroll. Path plus sticky context is what VSCode's
        -- breadcrumb row and sticky scroll give you between them.
        winbar = {
          lualine_c = {
            { "filename", path = 3, separator = ">", symbols = { modified = " *", readonly = " ro" } },
          },
        },
        inactive_winbar = {
          lualine_c = { { "filename", path = 3, separator = ">" } },
        },
        extensions = { "nvim-tree", "lazy", "trouble", "quickfix" },
      }
    end,
  },

  {
    "akinsho/bufferline.nvim",
    event = "VeryLazy",
    keys = {
      { "<leader>bp", "<cmd>BufferLineTogglePin<cr>", desc = "Pin buffer" },
      { "<leader>b1", "<cmd>BufferLineGoToBuffer 1<cr>", desc = "Buffer 1" },
      { "<leader>b2", "<cmd>BufferLineGoToBuffer 2<cr>", desc = "Buffer 2" },
      { "<leader>b3", "<cmd>BufferLineGoToBuffer 3<cr>", desc = "Buffer 3" },
      { "<leader>b4", "<cmd>BufferLineGoToBuffer 4<cr>", desc = "Buffer 4" },
    },
    opts = {
      options = {
        diagnostics = "nvim_lsp",
        always_show_bufferline = true,
        separator_style = "thin",
        show_buffer_close_icons = false,
        offsets = {
          { filetype = "NvimTree", text = "files", highlight = "Directory", separator = true },
        },
        diagnostics_indicator = function(_, _, diag)
          return (diag.error and "E" .. diag.error .. " " or "") .. (diag.warning and "W" .. diag.warning or "")
        end,
      },
    },
  },

  -- The map of everything below. <leader> on its own opens it; this is what
  -- makes the keymaps discoverable instead of memorised, and it is why the
  -- groups below carry real names.
  {
    "folke/which-key.nvim",
    event = "VeryLazy",
    opts = {
      preset = "helix",
      spec = {
        { "<leader>a", group = "ai" },
        { "<leader>b", group = "buffers" },
        { "<leader>c", group = "code" },
        { "<leader>f", group = "find" },
        { "<leader>g", group = "git" },
        { "<leader>l", group = "lsp" },
        { "<leader>r", group = "repl (send to tmux)" },
        { "<leader>s", group = "session" },
        { "<leader>t", group = "tmux", icon = "T" },
        { "<leader>u", group = "toggles" },
        { "<leader>x", group = "explore data" },
        { "[", group = "previous" },
        { "]", group = "next" },
      },
    },
    keys = {
      { "<leader>?", function() require("which-key").show({ global = false }) end, desc = "Keymaps for this buffer" },
    },
  },

  -- Indent guides. Ansible and Kubernetes YAML is where a wrong indent level
  -- is both easiest to write and hardest to see.
  {
    "lukas-reineke/indent-blankline.nvim",
    main = "ibl",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
      indent = { char = "│" },
      scope = { enabled = true, show_start = false, show_end = false },
      exclude = { filetypes = { "help", "checkhealth", "man", "lazy", "NvimTree", "dbui", "markdown" } },
    },
  },

  -- Sticky scroll. VSCode pins the enclosing function, class or YAML key to
  -- the top of the viewport as you scroll past its opening line; without it
  -- the answer to "which task am I inside" is a scroll upwards and back.
  -- Worth more here than in most editors, because ansible task files are long
  -- lists of near-identical blocks.
  {
    "nvim-treesitter/nvim-treesitter-context",
    event = { "BufReadPost", "BufNewFile" },
    opts = {
      -- Three lines, not the default of everything. The context is taken from
      -- the top of the window, so a deeply nested block can otherwise eat a
      -- third of a terminal split before you have read a line of code.
      max_lines = 3,
      multiline_threshold = 1,
      trim_scope = "outer",
      mode = "cursor",
      -- ASCII, like every other marker in this config: a Nerd Font is a
      -- client-side setting no play here can make.
      separator = "-",
    },
    keys = {
      { "<leader>uc", "<cmd>TSContextToggle<cr>", desc = "Sticky context" },
    },
  },

  -- Colour swatches, the way VSCode paints #rrggbb and rgb() in place. The
  -- payload here is theme and status-bar hex: this repo's tmux.conf and the
  -- colourscheme above are edited as literal colour values, and reading them
  -- as text is guesswork.
  {
    "catgoose/nvim-colorizer.lua",
    event = "BufReadPre",
    opts = {
      -- names = false, or every occurrence of the WORD "red" in prose and in
      -- ansible output gets a swatch. The hex and rgb() forms are the ones
      -- that carry a colour.
      user_default_options = { names = false, css = true, mode = "background" },
    },
  },
}
