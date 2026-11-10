-- Finding things with snacks' picker (files, text, symbols, help), and the file tree in a sidebar.
-- In a picker: Alt-h shows hidden files, Alt-i ignored ones, Ctrl-q sends the list to quickfix.

local pick = require("snacks").picker
local map = vim.keymap.set

map("n", "<leader>e", function() pick.explorer() end, { desc = "file tree" })

map("n", "<leader>ff", function() pick.files() end, { desc = "files" })
map("n", "<leader>fg", function() pick.grep() end, { desc = "text in files" })
map({ "n", "x" }, "<leader>fw", function() pick.grep_word() end, { desc = "word or selection" })
map("n", "<leader>fb", function() pick.buffers() end, { desc = "open buffers" })
map("n", "<leader>fr", function() pick.recent() end, { desc = "recent files" })
map("n", "<leader>fs", function() pick.lsp_symbols() end, { desc = "symbols in file" })
map("n", "<leader>fS", function() pick.lsp_workspace_symbols() end, { desc = "symbols in project" })
map("n", "<leader>fd", function() pick.diagnostics() end, { desc = "diagnostics" })
map("n", "<leader>fh", function() pick.help() end, { desc = "help" })
map("n", "<leader>fk", function() pick.keymaps() end, { desc = "keys" })
map("n", "<leader>fu", function() pick.undo() end, { desc = "undo history" })
map("n", "<leader>f.", function() pick.resume() end, { desc = "last picker" })

-- definitions and references as a list with preview instead of the quickfix window
map("n", "gd", function() pick.lsp_definitions() end, { desc = "definition" })
map("n", "grr", function() pick.lsp_references() end, { desc = "references" })
