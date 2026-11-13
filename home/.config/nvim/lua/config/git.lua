-- Git: changed lines in the sign column, with keys to jump between, preview and undo them, and
-- lazygit in a float; a file opened from lazygit opens in this nvim.

local lazygit = require("snacks").lazygit
vim.keymap.set("n", "<leader>gg", function() lazygit.open() end, { desc = "lazygit" })
vim.keymap.set("n", "<leader>gl", function() lazygit.log() end, { desc = "log" })
vim.keymap.set(
  "n",
  "<leader>gf",
  function() lazygit.log_file() end,
  { desc = "history of this file" }
)

require("gitsigns").setup({
  on_attach = function(buf)
    local gs = require("gitsigns")
    local function map(lhs, rhs, desc) vim.keymap.set("n", lhs, rhs, { buffer = buf, desc = desc }) end
    map("]c", function() gs.nav_hunk("next") end, "next change")
    map("[c", function() gs.nav_hunk("prev") end, "previous change")
    map("<leader>gp", gs.preview_hunk, "preview change")
    map("<leader>gr", gs.reset_hunk, "undo change")
    map("<leader>gb", gs.blame_line, "blame line")
  end,
})
