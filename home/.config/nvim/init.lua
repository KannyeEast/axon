-- Neovim as an IDE for the terminal. Nix installs the plugins (modules/features/terminal/shell.nix);
-- these files set them up, one area per file under lua/config/, the colours in colors/.
--
-- Keys nvim brings itself: K hover, grn rename, gra code action, grr references,
-- ctrl-] definition, [d ]d previous/next diagnostic, gcc comment a line.
-- Space and a pause lists every key that can follow.

vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("config.options")
require("config.ui")
require("config.find")
require("config.code")
require("config.git")
require("config.latex")
