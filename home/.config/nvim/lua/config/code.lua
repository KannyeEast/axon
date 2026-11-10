-- Understanding code: syntax trees and language servers.

-- ── syntax ────────
-- every parser is installed; a buffer gets tree highlighting and indent when its language has one,
-- except TeX, where vimtex's own syntax drives its motions and text objects
vim.api.nvim_create_autocmd("FileType", {
  callback = function(args)
    if args.match ~= "tex" and pcall(vim.treesitter.start, args.buf) then
      vim.bo[args.buf].indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
    end
  end,
})

-- ── language servers ────────
-- nil for Nix; it formats with nixfmt when that is on PATH, as in the config repo's devshell
vim.lsp.config("nil_ls", {
  settings = { ["nil"] = { formatting = { command = { "nixfmt" } } } },
})
vim.lsp.enable("nil_ls")
-- texlab only where LaTeX is installed
if vim.fn.executable("texlab") == 1 then
  vim.lsp.enable("texlab")
end

vim.diagnostic.config({ virtual_text = true, severity_sort = true })

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(args)
    local client = assert(vim.lsp.get_client_by_id(args.data.client_id))
    if client:supports_method("textDocument/completion") then
      vim.lsp.completion.enable(true, client.id, args.buf, { autotrigger = true })
    end
    vim.keymap.set("n", "<leader>cf", vim.lsp.buf.format, { buffer = args.buf, desc = "format" })
  end,
})
