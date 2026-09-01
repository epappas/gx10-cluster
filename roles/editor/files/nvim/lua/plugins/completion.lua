-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
return {
  {
    "saghen/blink.cmp",
    event = "InsertEnter",
    -- No `version = "*"`. Tag-pinning here is what upstream suggests, but it
    -- checks the plugin out on a detached HEAD, and lazy.nvim cannot then
    -- write a branch into lazy-lock.json (assertion failure in
    -- manage/lock.lua). The lockfile IS the pin in this repo, so tracking the
    -- branch and locking the commit is both sufficient and the thing that
    -- works.
    dependencies = { "rafamadriz/friendly-snippets", "saghen/blink.lib" },
    opts = {
      keymap = {
        -- Enter accepts, Tab moves through a snippet's placeholders, C-n/C-p
        -- walk the list. Chosen over the Tab-accepts presets because Tab is
        -- also indent, and a Tab that sometimes indents and sometimes commits
        -- a completion is the single most common "why did it write that"
        -- moment for anyone who did not configure the editor themselves.
        preset = "enter",
        ["<C-space>"] = { "show", "show_documentation", "hide_documentation" },
      },
      appearance = { nerd_font_variant = "mono" },
      completion = {
        documentation = { auto_show = true, auto_show_delay_ms = 200 },
        list = { selection = { preselect = false, auto_insert = false } },
        ghost_text = { enabled = false },
      },
      signature = { enabled = true },
      sources = {
        default = { "lsp", "path", "snippets", "buffer" },
      },
      -- The Lua matcher, not the Rust one. blink's default implementation
      -- downloads a prebuilt binary from GitHub on first start (or builds it
      -- with a NIGHTLY toolchain, which this repo does not install - rustup is
      -- pinned to a stable version in group_vars). The Lua matcher needs
      -- neither, and the difference is microseconds per keystroke on a
      -- 20-core machine.
      fuzzy = { implementation = "lua" },
    },
    opts_extend = { "sources.default" },
  },
}
