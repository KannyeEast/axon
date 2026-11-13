-- Nix installs the plugins (modules/features/terminal/shell.nix); lua/config/ sets them up, one
-- area per file, and colors/ holds the colour scheme.
-- Keys nvim brings itself: K hover, grn rename, gra code action, grr references, ctrl-] definition,
-- [d ]d previous/next diagnostic, gcc comment a line. Space and a pause lists what can follow.

vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("config.options")
require("config.ui")
require("config.find")
require("config.code")
require("config.git")
require("config.latex")
