-- Neovim as a text editor with a few extras: syntax trees, fuzzy finding, git signs and the Nix
-- language server. Nix installs the plugins; this file only sets them up.
--
-- Keys nvim brings itself: K hover, grn rename, gra code action, grr references,
-- ctrl-] definition, [d ]d previous/next diagnostic, gcc comment a line.

vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- ── options ────────
local o = vim.opt
-- the terminal's palette instead of nvim's own colours, so alacritty decides the look
o.termguicolors = false
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
o.completeopt = { "menuone", "noselect", "popup" }

local map = vim.keymap.set
map("n", "<Esc>", "<cmd>nohlsearch<cr>")
map("n", "<leader>w", "<cmd>write<cr>", { desc = "save" })

-- ── finding ────────
local telescope = require("telescope")
telescope.setup({})
telescope.load_extension("fzf")

local find = require("telescope.builtin")
map("n", "<leader>ff", find.find_files, { desc = "files" })
map("n", "<leader>fg", find.live_grep, { desc = "text in files" })
map("n", "<leader>fb", find.buffers, { desc = "open buffers" })
map("n", "<leader>fr", find.oldfiles, { desc = "recent files" })
map("n", "<leader>fd", find.diagnostics, { desc = "diagnostics" })
map("n", "<leader>fh", find.help_tags, { desc = "help" })

-- ── syntax ────────
-- every parser is installed; a buffer gets tree highlighting and indent when its language has one
vim.api.nvim_create_autocmd("FileType", {
  callback = function(args)
    if pcall(vim.treesitter.start, args.buf) then
      vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
    end
  end,
})

-- ── git ────────
require("gitsigns").setup({
  on_attach = function(buf)
    local gs = require("gitsigns")
    local function bmap(lhs, rhs, desc)
      map("n", lhs, rhs, { buffer = buf, desc = desc })
    end
    bmap("]c", function() gs.nav_hunk("next") end, "next change")
    bmap("[c", function() gs.nav_hunk("prev") end, "previous change")
    bmap("<leader>gp", gs.preview_hunk, "preview change")
    bmap("<leader>gr", gs.reset_hunk, "undo change")
    bmap("<leader>gb", gs.blame_line, "blame line")
  end,
})

-- ── language servers ────────
-- nil for Nix; it formats with nixfmt when that is on PATH, as in the config repo's devshell
vim.lsp.config("nil_ls", {
  settings = { ["nil"] = { formatting = { command = { "nixfmt" } } } },
})
vim.lsp.enable("nil_ls")

vim.diagnostic.config({ virtual_text = true, severity_sort = true })

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local client = assert(vim.lsp.get_client_by_id(args.data.client_id))
    if client:supports_method("textDocument/completion") then
      vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
    end
    map("n", "<leader>cf", vim.lsp.buf.format, { buffer = args.buf, desc = "format" })
  end,
})

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
