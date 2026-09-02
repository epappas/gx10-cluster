-- Managed by gx10-cluster ansible (roles/editor). Local edits are OVERWRITTEN.
--
-- Closing a buffer without closing the window it is sitting in.
--
-- `:bdelete` does not do that. A window must always display SOME buffer, so
-- when the one being deleted is on screen and vim has nothing obvious to put
-- in its place, it closes the window instead - and if that was the last
-- window, it quits the editor. On a tab bar that looks exactly like "closing a
-- tab exited my editor", which is what it did here.
--
-- So: point every window showing the buffer at something else FIRST, then
-- delete it. This is the job every distribution hands to mini.bufremove or
-- snacks.bufdelete; it is ~30 lines, so it is here instead of a plugin.
local M = {}

--- The buffer a window should show once `buf` is gone: the alternate file if
--- it is still a real listed buffer, otherwise the next listed one, otherwise
--- nothing (and the caller makes a scratch buffer).
local function replacement(win, buf)
  local alt = vim.fn.winbufnr(win) == buf and vim.fn.bufnr("#") or -1
  if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
    return alt
  end
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    if other ~= buf and vim.bo[other].buflisted and vim.api.nvim_buf_is_valid(other) then
      return other
    end
  end
  return nil
end

--- Close a buffer, keeping the window layout.
--- @param buf integer|nil defaults to the current buffer
--- @param force boolean|nil discard unsaved changes
function M.close(buf, force)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf

  -- Refuse rather than silently discard. `:bd!` and <leader>bD are the ways to
  -- say you meant it.
  if not force and vim.bo[buf].modified then
    return vim.notify(
      ("%s has unsaved changes - :w first, or <leader>bD to discard"):format(
        vim.fs.basename(vim.api.nvim_buf_get_name(buf)) ~= "" and vim.fs.basename(vim.api.nvim_buf_get_name(buf))
          or "this buffer"
      ),
      vim.log.levels.WARN
    )
  end

  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      local other = replacement(win, buf)
      if other then
        vim.api.nvim_win_set_buf(win, other)
      else
        -- Nothing left to show. An empty scratch buffer keeps the window - and
        -- the editor - open, which is what closing the last tab should do.
        vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
      end
    end
  end

  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = force or false })
  end
end

--- Close every OTHER listed buffer, keeping this one and the layout.
function M.close_others()
  local keep = vim.api.nvim_get_current_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if buf ~= keep and vim.bo[buf].buflisted and not vim.bo[buf].modified then
      M.close(buf)
    end
  end
end

return M
