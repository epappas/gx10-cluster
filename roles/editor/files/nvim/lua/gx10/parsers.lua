-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
--
-- The treesitter parsers this box compiles at provision time. Kept in its own
-- module because two things need the same list: the plugin spec, which
-- installs anything missing when you start the editor, and gx10.provision,
-- which the play calls headlessly so the first interactive start is not spent
-- compiling 35 grammars.
--
-- Neovim ships only c, lua, markdown, markdown_inline, query, vim and vimdoc.
-- Everything else here falls back to regex syntax without a parser: no
-- structural folds, no reliable indent, and a visibly worse highlight on
-- exactly the files this cluster is edited for.
return {
  -- What this repo and its workloads are written in
  "python", "rust", "go", "gomod", "gosum", "bash", "lua", "vim", "vimdoc", "query",
  -- Config and data. `jsonc` is deliberately absent - nvim-treesitter rejects
  -- it as "unsupported language" and the json parser handles jsonc buffers.
  "yaml", "json", "json5", "toml", "hcl", "terraform", "dockerfile",
  "make", "cmake", "ninja", "csv", "sql", "regex", "ssh_config",
  -- Prose
  "markdown", "markdown_inline", "html",
  -- Git
  "git_config", "git_rebase", "gitcommit", "gitignore", "diff",
  -- C, C++ and CUDA, for reading llama.cpp and hand-written kernels
  "c", "cpp", "cuda",
}
