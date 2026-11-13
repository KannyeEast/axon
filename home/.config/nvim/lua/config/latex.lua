-- LaTeX with vimtex: <localleader>ll compiles continuously with latexmk, <localleader>lv shows the
-- PDF in zathura (the simple viewer: the full one needs X11 to find the window).

vim.g.vimtex_view_method = "zathura_simple"

-- shows \alpha in math as α and \textbf{x} as bold x; the cursor line shows the code
vim.api.nvim_create_autocmd("FileType", {
  pattern = "tex",
  callback = function() vim.opt_local.conceallevel = 2 end,
})
