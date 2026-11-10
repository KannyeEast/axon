-- Finding files, text and help with telescope.

local telescope = require("telescope")
telescope.setup({})
telescope.load_extension("fzf")

local find = require("telescope.builtin")
local map = vim.keymap.set
map("n", "<leader>ff", find.find_files, { desc = "files" })
map("n", "<leader>fg", find.live_grep, { desc = "text in files" })
map("n", "<leader>fb", find.buffers, { desc = "open buffers" })
map("n", "<leader>fr", find.oldfiles, { desc = "recent files" })
map("n", "<leader>fd", find.diagnostics, { desc = "diagnostics" })
map("n", "<leader>fh", find.help_tags, { desc = "help" })
