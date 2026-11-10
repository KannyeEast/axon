-- How nvim looks: the colour scheme, icons, statusline, notifications, indent guides, and
-- which-key, which lists the keys that can follow a prefix.

vim.o.termguicolors = true
vim.cmd.colorscheme("terminal")

-- the statusline shows the mode; one statusline for every window
vim.o.showmode = false
vim.o.laststatus = 3
-- hover, signature and other floating windows get a frame
vim.o.winborder = "rounded"

require("mini.icons").setup()
-- plugins that ask for nvim-web-devicons get the same icons
MiniIcons.mock_nvim_web_devicons()

require("mini.statusline").setup()

-- messages and language server progress in a corner instead of the command line
require("mini.notify").setup()
vim.notify = MiniNotify.make_notify()

require("snacks").setup({
  indent = { enabled = true, animate = { enabled = false } },
})

local wk = require("which-key")
wk.setup({})
wk.add({
  { "<leader>c", group = "code" },
  { "<leader>f", group = "find" },
  { "<leader>g", group = "git" },
  { "<leader>l", group = "latex" },
})
