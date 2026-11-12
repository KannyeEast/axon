-- The terminal's palette as a full colour scheme: mini.base16 turns 16 colours into every syntax,
-- language server and plugin group. The colours come from alacritty.toml;
-- base03, base04, base06, base09 and base0F aren't in the terminal and are mixed from its colours.
-- Change the terminal's palette, change this one with it.
local p = {
  base00 = "#0c0c12", -- background
  base01 = "#1c1e27", -- raised background: statusline, cursor line
  base02 = "#323947", -- selection
  base03 = "#5f6a80", -- comments
  base04 = "#7f8ba1", -- line numbers, quiet text
  base05 = "#a5b6cf", -- text
  base06 = "#c6d0e0", -- parameters
  base07 = "#e6e8ee",
  base08 = "#ff6b7a", -- red: errors, deleted
  base09 = "#f5a97f", -- orange: constants, numbers
  base0A = "#f1d8a5", -- yellow: types
  base0B = "#95d3af", -- green: strings
  base0C = "#98d3ee", -- cyan: keys, fields, properties, escapes, math
  base0D = "#8aa2ff", -- blue: functions, concealed symbols
  base0E = "#c79bf0", -- magenta: keywords, LaTeX commands
  base0F = "#d99a8f", -- brown: delimiters
}
require("mini.base16").setup({ palette = p })

-- base16 colours identifiers and statements red, which turns TOML keys and every `return` into
-- warnings, and leaves fields and parameters uncoloured; red stays for errors
local function hl(group, opts) vim.api.nvim_set_hl(0, group, opts) end
hl("Identifier", { fg = p.base0C })
hl("Statement", { fg = p.base0E })
hl("@keyword.return", { link = "Statement" })
hl("@variable.member", { link = "Identifier" })
hl("@variable.parameter", { fg = p.base06, italic = true })

vim.g.colors_name = "terminal"
