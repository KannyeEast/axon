-- How nvim looks: the colour scheme, icons, statusline, notifications, indent guides, and
-- which-key, which lists the keys that can follow a prefix.

vim.o.termguicolors = true
vim.cmd.colorscheme("terminal")

-- the statusline shows the mode; one statusline for every window
vim.o.showmode = false
vim.o.laststatus = 3
-- hover, signature and other floating windows get a frame
vim.o.winborder = "rounded"

local icons = require("mini.icons")
icons.setup()
-- plugins that ask for nvim-web-devicons get the same icons
icons.mock_nvim_web_devicons()

require("mini.statusline").setup()

-- messages and language server progress in a corner instead of the command line
local notify = require("mini.notify")
notify.setup()
vim.notify = notify.make_notify()

-- snacks writes lazygit's theme and the undo preview into nvim's cache folder without creating it;
-- plugin managers do that, Nix doesn't
vim.fn.mkdir(vim.fn.stdpath("cache"), "p")

require("snacks").setup({
  indent = { enabled = true, animate = { enabled = false } },
  -- the picker also serves vim.ui.select (code actions and the like); the tree opens for `nvim .`
  picker = {
    enabled = true,
    -- dotfiles are half of what gets edited here; ignored files stay hidden
    sources = {
      explorer = { hidden = true },
      files = { hidden = true },
      grep = { hidden = true },
    },
  },
  explorer = { enabled = true },
})

local wk = require("which-key")
wk.setup({})
wk.add({
  { "<leader>c", group = "code" },
  { "<leader>f", group = "find" },
  { "<leader>g", group = "git" },
  { "<leader>l", group = "latex" },
  { "<leader>u", group = "toggle" },
  { "<leader>x", group = "problems" },
})
