-- Editor behaviour: options, basic keys, pairs, surround, text objects, small automatic things.

-- ── options ────────
local o = vim.opt
-- the current line shows its own number, every other line its distance from it
o.number = true
o.relativenumber = true
o.signcolumn = "yes"
o.cursorline = true
o.scrolloff = 8
o.linebreak = true
o.mouse = "a"
o.clipboard = "unnamedplus"
o.undofile = true
o.ignorecase = true
o.smartcase = true
o.splitright = true
o.splitbelow = true
o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.updatetime = 250
o.confirm = true
o.list = true
o.listchars = { tab = "» ", trail = "·", nbsp = "␣" }

-- ── keys ────────
local map = vim.keymap.set
map("n", "<Esc>", "<cmd>nohlsearch<cr>")
map("n", "<leader>w", "<cmd>write<cr>", { desc = "save" })

-- ── editing ────────
-- brackets and quotes close themselves
require("mini.pairs").setup()
-- sa adds brackets/quotes around a motion or selection, sd deletes, sr replaces: saiw" quotes a word
require("mini.surround").setup()
-- more text objects: a argument, f function call, q any quote, b any bracket (cia, daf, vi")
require("mini.ai").setup()

-- ── small things ────────
vim.api.nvim_create_autocmd("TextYankPost", {
  callback = function() vim.hl.on_yank() end,
})

-- reopen a file where it was left
vim.api.nvim_create_autocmd("BufReadPost", {
  callback = function(args)
    local mark = vim.api.nvim_buf_get_mark(args.buf, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(args.buf) then
      pcall(vim.api.nvim_win_set_cursor, 0, mark)
    end
  end,
})
