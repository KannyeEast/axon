-- Understanding and writing code: syntax trees, language servers, completion, formatting and the
-- problem list.

local map = vim.keymap.set

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
-- nixd completes packages and NixOS options from the config repo, for the host it runs on
local flake = os.getenv("NH_FLAKE")
if flake then
  local repo = ('(builtins.getFlake "%s")'):format(flake)
  vim.lsp.config("nixd", {
    settings = {
      nixd = {
        nixpkgs = { expr = repo .. ".inputs.nixpkgs.legacyPackages.${builtins.currentSystem}" },
        options = {
          nixos = {
            expr = ('%s.nixosConfigurations."%s".options'):format(repo, vim.fn.hostname()),
          },
        },
      },
    },
  })
end

-- server and its program; each starts where the program is on PATH. Desktops install these
-- (modules/features/dev/languages.nix); one from a project's devshell only needs adding here
local servers = {
  bashls = "bash-language-server",
  jsonls = "vscode-json-language-server",
  lua_ls = "lua-language-server",
  marksman = "marksman",
  nixd = "nixd",
  taplo = "taplo",
  texlab = "texlab",
  yamlls = "yaml-language-server",
}
for name, program in pairs(servers) do
  if vim.fn.executable(program) == 1 then
    vim.lsp.enable(name)
  end
end

-- the vim API and the installed plugins for lua_ls, in nvim's config
require("lazydev").setup({})

vim.diagnostic.config({ virtual_text = true, severity_sort = true })
-- parameter names and types inline, where the server offers them
vim.lsp.inlay_hint.enable()

-- ── completion ────────
-- Enter accepts, Tab and Shift-Tab jump through a snippet, Ctrl-Space opens the menu
require("blink.cmp").setup({
  keymap = { preset = "enter" },
  completion = { documentation = { auto_show = true } },
  signature = { enabled = true },
  sources = {
    per_filetype = { lua = { inherit_defaults = true, "lazydev" } },
    providers = {
      lazydev = { name = "LazyDev", module = "lazydev.integrations.blink", score_offset = 100 },
    },
  },
})

-- ── formatting ────────
-- on save, with the language's usual formatter, else the language server's
local conform = require("conform")
conform.setup({
  formatters_by_ft = {
    bash = { "shfmt" },
    lua = { "stylua" },
    nix = { "nixfmt" },
    sh = { "shfmt" },
    toml = { "taplo" },
  },
  -- shfmt indents with tabs unless an .editorconfig says otherwise
  formatters = { shfmt = { prepend_args = { "-i", "2" } } },
  default_format_opts = { lsp_format = "fallback" },
  format_on_save = function()
    if vim.g.autoformat ~= false then
      return {}
    end
  end,
})
map({ "n", "x" }, "<leader>cf", conform.format, { desc = "format" })

-- ── problems ────────
local trouble = require("trouble")
trouble.setup({})
map("n", "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>", { desc = "all problems" })
map("n", "<leader>xb", "<cmd>Trouble diagnostics toggle filter.buf=0<cr>", { desc = "this file" })
map("n", "<leader>xs", "<cmd>Trouble symbols toggle<cr>", { desc = "symbols outline" })
map("n", "<leader>xq", "<cmd>Trouble qflist toggle<cr>", { desc = "quickfix list" })

-- ── toggles ────────
local toggle = require("snacks").toggle
toggle
  .new({
    id = "autoformat",
    name = "format on save",
    get = function() return vim.g.autoformat ~= false end,
    set = function(on) vim.g.autoformat = on end,
  })
  :map("<leader>uf")
toggle.inlay_hints():map("<leader>uh")
toggle.diagnostics():map("<leader>ud")
