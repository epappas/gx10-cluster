-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
--
-- Parsers are COMPILED on this machine, by the play, at provision time - see
-- roles/editor/tasks/main.yml and gx10.provision. The list itself lives in
-- lua/gx10/parsers.lua, because the play needs to read it too.
--
-- The main branch, not master: master is frozen upstream, and main is what
-- neovim 0.11+ expects. It compiles grammars with the tree-sitter CLI (pinned
-- and installed by the play) rather than invoking cc itself, and it does NOT
-- start highlighting for you - hence the autocmd below.
local parsers = require("gx10.parsers")

return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "main",
    lazy = false,
    build = ":TSUpdate",
    config = function()
      require("nvim-treesitter").setup({})
      -- install() is a no-op for parsers that are already present and already
      -- at the locked revision, so this is cheap on every start after the
      -- first. The play installs them ahead of time so the first interactive
      -- start is not spent compiling.
      local missing = {}
      local have = require("nvim-treesitter.config").get_installed("parsers")
      for _, lang in ipairs(parsers) do
        if not vim.tbl_contains(have, lang) then missing[#missing + 1] = lang end
      end
      if #missing > 0 then require("nvim-treesitter").install(missing) end

      -- The main branch does not start highlighting for you.
      vim.api.nvim_create_autocmd("FileType", {
        group = vim.api.nvim_create_augroup("gx10_treesitter", { clear = true }),
        callback = function(ev)
          if vim.b[ev.buf].gx10_big_file then return end
          local lang = vim.treesitter.language.get_lang(vim.bo[ev.buf].filetype)
          if lang and vim.treesitter.language.add(lang) then
            pcall(vim.treesitter.start, ev.buf, lang)
            -- Treesitter indent is still opt-in and still the better answer
            -- for YAML, Lua and Go.
            vim.bo[ev.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
          end
        end,
      })
    end,
  },
}
