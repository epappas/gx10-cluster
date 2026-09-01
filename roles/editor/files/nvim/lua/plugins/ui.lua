-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
return {
  -- Catppuccin Mocha, and not for taste: ~/.tmux.conf's status bar is written
  -- in these exact hex values (#1e1e2e background, #89b4fa accent, #cdd6f4
  -- text). Any other colourscheme puts a seam across the top of the screen
  -- where the editor stops and tmux starts.
  {
    "catppuccin/nvim",
    name = "catppuccin",
    lazy = false,
    priority = 1000,
    opts = {
      flavour = "mocha",
      background = { dark = "mocha" },
      transparent_background = false,
      integrations = {
        blink_cmp = true,
        gitsigns = true,
        nvim_tree = true,
        telescope = { enabled = true },
        treesitter = true,
        which_key = true,
        native_lsp = { enabled = true, virtual_text = { errors = { "italic" } } },
        markdown = true,
        mason = false,
      },
    },
    config = function(_, opts)
      require("catppuccin").setup(opts)
      vim.cmd.colorscheme("catppuccin")
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
          -- "catppuccin-mocha", not "catppuccin": the plugin registers one
          -- lualine theme per flavour and there is no bare alias, so the
          -- obvious name silently falls back to `auto` with a warning.
          theme = "catppuccin-mocha",
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
        extensions = { "nvim-tree", "lazy", "trouble", "quickfix" },
      }
    end,
  },

  {
    "akinsho/bufferline.nvim",
    event = "VeryLazy",
    keys = {
      { "<leader>bp", "<cmd>BufferLineTogglePin<cr>", desc = "Pin buffer" },
      { "<leader>bd", "<cmd>bdelete<cr>", desc = "Delete buffer" },
      { "<leader>bo", "<cmd>BufferLineCloseOthers<cr>", desc = "Close other buffers" },
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
}
