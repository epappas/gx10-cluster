-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
return {
  -- --- The tmux boundary, erased ------------------------------------------
  -- <C-h/j/k/l> move between nvim splits AND tmux panes with the same four
  -- keys: if there is a split that way it goes there, otherwise it hands off
  -- to tmux. The other half of this lives in ~/.tmux.conf, which runs the
  -- same check from the other side (roles/shell). Both halves are required;
  -- either one alone gives you keys that work in one direction only.
  {
    "christoomey/vim-tmux-navigator",
    lazy = false,
    init = function()
      -- Its own mappings are <C-w>-prefixed variants we do not want; the four
      -- below are declared here so which-key can describe them.
      vim.g.tmux_navigator_no_mappings = 1
      -- Write the buffer when navigating AWAY to a tmux pane, so the shell
      -- you are moving to sees the file you were just editing.
      vim.g.tmux_navigator_save_on_switch = 1
    end,
    keys = {
      { "<C-h>", "<cmd>TmuxNavigateLeft<cr>", desc = "Pane/split left" },
      { "<C-j>", "<cmd>TmuxNavigateDown<cr>", desc = "Pane/split down" },
      { "<C-k>", "<cmd>TmuxNavigateUp<cr>", desc = "Pane/split up" },
      { "<C-l>", "<cmd>TmuxNavigateRight<cr>", desc = "Pane/split right" },
    },
  },

  -- Send code to a REPL running in another tmux pane. This is the data
  -- exploration loop on these boxes: ipython (or the ml venv's python, or
  -- llama-cli) lives in a pane, the notebook-shaped thing is a plain .py file
  -- in the editor, and <leader>rr runs the block you are looking at.
  --
  -- Why not a notebook plugin: molten/image.nvim need a terminal that speaks
  -- the kitty graphics protocol, and these machines are reached over SSH from
  -- whatever client is to hand. Text to a pane works from everything.
  {
    "jpalardy/vim-slime",
    keys = {
      { "<leader>rr", "<Plug>SlimeParagraphSend", desc = "Send paragraph to REPL" },
      { "<leader>rl", "<Plug>SlimeLineSend", desc = "Send line to REPL" },
      { "<leader>r", "<Plug>SlimeRegionSend", mode = "x", desc = "Send selection to REPL" },
      { "<leader>rb", "<cmd>%SlimeSend<cr>", desc = "Send whole buffer to REPL" },
      { "<leader>rc", "<cmd>SlimeConfig<cr>", desc = "Choose the REPL pane" },
      {
        "<leader>rp",
        function() require("gx10.tmux").run(". ~/venvs/ml/bin/activate 2>/dev/null; ipython") end,
        desc = "Start ipython in the runner pane",
      },
      {
        "<leader>rq",
        function() require("gx10.tmux").run("gx10-status") end,
        desc = "gx10-status in the runner pane",
      },
    },
    init = function()
      vim.g.slime_target = "tmux"
      -- {last} is the pane you were in before this one, which is what the
      -- runner pane <leader>rp opens becomes. :SlimeConfig retargets it.
      vim.g.slime_default_config = { socket_name = "default", target_pane = "{last}" }
      vim.g.slime_dont_ask_default = 1
      -- Load-bearing for ipython: without bracketed paste it re-indents every
      -- line it receives and a multi-line block arrives as a syntax error.
      vim.g.slime_bracketed_paste = 1
      vim.g.slime_no_mappings = 1
    end,
  },

  -- --- Finding things -----------------------------------------------------
  {
    "nvim-telescope/telescope.nvim",
    cmd = "Telescope",
    dependencies = {
      "nvim-lua/plenary.nvim",
      -- Compiled, not the Lua sorter: this repo is small but ~/models and the
      -- venvs are not, and the Lua sorter is noticeably slower once a picker
      -- has tens of thousands of candidates. build-essential is already a
      -- dependency of roles/base, so the build costs nothing extra.
      { "nvim-telescope/telescope-fzf-native.nvim", build = "make" },
    },
    keys = {
      { "<leader><space>", "<cmd>Telescope find_files<cr>", desc = "Find files" },
      { "<leader>ff", "<cmd>Telescope find_files<cr>", desc = "Files" },
      { "<leader>fg", "<cmd>Telescope live_grep<cr>", desc = "Grep (ripgrep)" },
      { "<leader>fw", "<cmd>Telescope grep_string<cr>", desc = "Grep word under cursor" },
      { "<leader>fb", "<cmd>Telescope buffers<cr>", desc = "Buffers" },
      { "<leader>fr", "<cmd>Telescope oldfiles<cr>", desc = "Recent files" },
      { "<leader>fh", "<cmd>Telescope help_tags<cr>", desc = "Help" },
      { "<leader>fk", "<cmd>Telescope keymaps<cr>", desc = "Keymaps" },
      { "<leader>fc", "<cmd>Telescope commands<cr>", desc = "Commands" },
      { "<leader>fd", "<cmd>Telescope diagnostics<cr>", desc = "Diagnostics" },
      { "<leader>fs", "<cmd>Telescope lsp_document_symbols<cr>", desc = "Document symbols" },
      { "<leader>fS", "<cmd>Telescope lsp_dynamic_workspace_symbols<cr>", desc = "Workspace symbols" },
      { "<leader>f/", "<cmd>Telescope current_buffer_fuzzy_find<cr>", desc = "Search in buffer" },
      { "<leader>gs", "<cmd>Telescope git_status<cr>", desc = "Git status" },
      { "<leader>gc", "<cmd>Telescope git_commits<cr>", desc = "Git commits" },
    },
    opts = function()
      local actions = require("telescope.actions")
      return {
        defaults = {
          prompt_prefix = "  ",
          selection_caret = "> ",
          path_display = { "truncate" },
          -- Model weights and venvs are the two directories that make a
          -- grep here take minutes instead of milliseconds.
          file_ignore_patterns = { "%.git/", "node_modules/", "%.venv/", "venvs/", "models/", "%.safetensors", "%.gguf" },
          mappings = {
            i = {
              ["<C-j>"] = actions.move_selection_next,
              ["<C-k>"] = actions.move_selection_previous,
              ["<esc>"] = actions.close,
              ["<C-q>"] = actions.smart_send_to_qflist + actions.open_qflist,
            },
          },
        },
        pickers = {
          find_files = { hidden = true },
        },
        extensions = {
          fzf = { fuzzy = true, override_generic_sorter = true, override_file_sorter = true },
        },
      }
    end,
    config = function(_, opts)
      local telescope = require("telescope")
      telescope.setup(opts)
      pcall(telescope.load_extension, "fzf")
    end,
  },

  -- --- The tree ------------------------------------------------------------
  {
    "nvim-tree/nvim-tree.lua",
    cmd = { "NvimTreeToggle", "NvimTreeFindFile" },
    init = function()
      -- `nvim .` and `nvim ~/src/thing` have to open the tree. netrw is in
      -- init.lua's disabled list and this plugin is lazy, so without this a
      -- directory argument opens an empty unnamed buffer and gives no hint
      -- that anything went wrong - which is the first thing anyone types.
      --
      -- Loading it here rather than handling the buffer ourselves: nvim-tree's
      -- own hijack_directories does the work once the plugin is loaded, and
      -- init runs before the argument's buffer is read.
      local arg = vim.fn.argv(0)
      if type(arg) == "string" and arg ~= "" and vim.fn.isdirectory(arg) == 1 then
        require("lazy").load({ plugins = { "nvim-tree.lua" } })
      end
    end,
    keys = {
      { "<leader>e", "<cmd>NvimTreeToggle<cr>", desc = "File tree" },
      { "<leader>E", "<cmd>NvimTreeFindFile<cr>", desc = "Reveal file in tree" },
    },
    opts = {
      view = { width = 34 },
      renderer = { group_empty = true, highlight_git = true },
      -- The tree is a view of the project, not of $HOME: without this,
      -- opening a file from ~/src puts the root there and the next find is
      -- against 130 GB of weights.
      respect_buf_cwd = true,
      update_focused_file = { enable = true },
      filters = { dotfiles = false, custom = { "^%.git$" } },
      git = { enable = true, ignore = false },
      diagnostics = { enable = true },
      actions = { open_file = { quit_on_open = false } },
    },
  },

  -- --- Git -----------------------------------------------------------------
  {
    "lewis6991/gitsigns.nvim",
    event = { "BufReadPre", "BufNewFile" },
    opts = {
      signs = {
        add = { text = "+" },
        change = { text = "~" },
        delete = { text = "_" },
        topdelete = { text = "‾" },
        changedelete = { text = "~" },
      },
      current_line_blame_opts = { delay = 300, virt_text_pos = "eol" },
      on_attach = function(buf)
        local gs = require("gitsigns")
        local function map(mode, lhs, rhs, desc)
          vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc })
        end
        map("n", "]h", gs.next_hunk, "Next hunk")
        map("n", "[h", gs.prev_hunk, "Previous hunk")
        map("n", "<leader>gh", gs.preview_hunk, "Preview hunk")
        map("n", "<leader>gr", gs.reset_hunk, "Reset hunk")
        map("n", "<leader>ga", gs.stage_hunk, "Stage hunk")
        map("n", "<leader>gA", gs.stage_buffer, "Stage buffer")
        map("n", "<leader>gu", gs.undo_stage_hunk, "Unstage hunk")
        map("n", "<leader>gb", function() gs.blame_line({ full = true }) end, "Blame line")
        map("n", "<leader>gB", gs.toggle_current_line_blame, "Blame line (inline, toggle)")
        map("n", "<leader>gd", gs.diffthis, "Diff this file")
      end,
    },
  },

  -- --- Diagnostics, in a list ---------------------------------------------
  {
    "folke/trouble.nvim",
    cmd = "Trouble",
    keys = {
      { "<leader>lD", "<cmd>Trouble diagnostics toggle<cr>", desc = "Diagnostics (project)" },
      { "<leader>lb", "<cmd>Trouble diagnostics toggle filter.buf=0<cr>", desc = "Diagnostics (buffer)" },
      { "<leader>ls", "<cmd>Trouble symbols toggle focus=false<cr>", desc = "Symbol outline" },
      { "<leader>lq", "<cmd>Trouble qflist toggle<cr>", desc = "Quickfix list" },
    },
    opts = { focus = true },
  },

  -- --- Sessions ------------------------------------------------------------
  -- These boxes are used over SSH inside tmux, so nvim is routinely killed by
  -- a dropped connection rather than closed. Restoring the session per
  -- directory makes that a non-event.
  {
    "folke/persistence.nvim",
    event = "BufReadPre",
    opts = {},
    keys = {
      { "<leader>ss", function() require("persistence").load() end, desc = "Restore session for this directory" },
      { "<leader>sl", function() require("persistence").load({ last = true }) end, desc = "Restore last session" },
      { "<leader>sd", function() require("persistence").stop() end, desc = "Do not save this session" },
    },
  },

  -- --- Small edits ---------------------------------------------------------
  { "windwp/nvim-autopairs", event = "InsertEnter", opts = {} },
  { "kylechui/nvim-surround", event = "VeryLazy", opts = {} },
}
