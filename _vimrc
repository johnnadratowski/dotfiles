" ==========================================================
" Neovim/Vim Configuration
" ==========================================================

" ==========================================================
" Plugins
" ==========================================================

call plug#begin()

" Shared plugins (work in both vim and nvim)
Plug 'AndrewRadev/sideways.vim'
Plug 'airblade/vim-gitgutter'
Plug 'chrisbra/NrrwRgn'
Plug 'chrisbra/matchit'
Plug 'christoomey/vim-tmux-navigator'
Plug 'dbeniamine/cheat.sh-vim'
Plug 'direnv/direnv.vim'
Plug 'editorconfig/editorconfig-vim'
Plug 'fatih/vim-go'
Plug 'heavenshell/vim-pydocstring', { 'do': 'make install', 'for': 'python' }
Plug 'itchyny/landscape.vim'
Plug 'itchyny/lightline.vim'
Plug 'itchyny/vim-gitbranch'
Plug 'johnnadratowski/molokai'
Plug 'johnnadratowski/vim-pug'
Plug 'johnnadratowski/vim-stylus'
Plug 'junegunn/fzf', {'dir': '~/.fzf','do': './install --all'}
Plug 'junegunn/fzf.vim'
Plug 'junegunn/limelight.vim'
Plug 'junegunn/vim-easy-align'
Plug 'madox2/vim-ai'
Plug 'kchmck/vim-coffee-script'
Plug 'kristijanhusak/vim-dadbod-ui'
Plug 'leafgarland/typescript-vim'
Plug 'leafOfTree/vim-vue-plugin'
Plug 'maxbrunsfeld/vim-emacs-bindings'
Plug 'mbbill/undotree'
Plug 'mhinz/vim-startify'
Plug 'pbogut/vim-dadbod-ssh'
Plug 'preservim/vim-colors-pencil'
Plug 'preservim/vim-wordchipper'
Plug 'preservim/vimux'
Plug 'prettier/vim-prettier'
Plug 'reedes/vim-lexical'
Plug 'reedes/vim-litecorrect'
Plug 'reedes/vim-pencil'
Plug 'reedes/vim-textobj-sentence'
Plug 'reedes/vim-textobj-quote'
Plug 'reedes/vim-wordy'
Plug 'ryanoasis/vim-devicons'
Plug 'sebdah/vim-delve'
Plug 'sheerun/vim-wombat-scheme'
Plug 'stephpy/vim-yaml'
Plug 'thaerkh/vim-indentguides'
Plug 'thaerkh/vim-workspace'
Plug 'tpope/vim-abolish'
Plug 'tpope/vim-commentary'
Plug 'tpope/vim-dadbod'
Plug 'tpope/vim-dotenv'
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-repeat'
Plug 'tpope/vim-sensible'
Plug 'tpope/vim-surround'
Plug 'tpope/vim-vinegar'
Plug 'vim-test/vim-test'
Plug 'wesQ3/vim-windowswap'
Plug 'yggdroot/LeaderF', { 'do': ':LeaderfInstallCExtension' }

" Neovim-only plugins
if has('nvim')
  Plug 'antoinemadec/coc-fzf', {'branch': 'release'}
  Plug 'glacambre/firenvim'
  Plug 'neoclide/coc.nvim', {'branch': 'release'}
  Plug 'nvim-lua/plenary.nvim'
  Plug 'nvim-tree/nvim-web-devicons'
  Plug 'ttibsi/pre-commit.nvim'
  Plug 'folke/snacks.nvim'
  Plug 'coder/claudecode.nvim'
endif

call plug#end()

" ==========================================================
" Source Shared Modules
" ==========================================================

source ~/.vim/vimrc/settings.vim
source ~/.vim/vimrc/functions.vim
source ~/.vim/vimrc/keymaps.vim
source ~/.vim/vimrc/plugins-shared.vim
source ~/.vim/vimrc/leaderf.vim

" ==========================================================
" Neovim-specific Configuration
" ==========================================================

if has('nvim')
  " CoC extensions
  let g:coc_global_extensions = ['coc-css', 'coc-db', 'coc-dictionary', 'coc-emoji', 'coc-eslint', 'coc-go', 'coc-highlight', 'coc-html', 'coc-json', 'coc-lightbulb', 'coc-omni', 'coc-prettier', 'coc-pyright', 'coc-sh', 'coc-snippets', 'coc-sql', 'coc-tsserver', 'coc-vimlsp']

  " Terminal mode keymaps
  tnoremap <C-space> <C-\><C-n>:call ToggleSplitFullscreen()<CR>i
  tnoremap <A-Up> <C-\><C-n><Cmd>call ResizeWindow('up')<CR><Cmd>startinsert<CR>
  tnoremap <A-Down> <C-\><C-n><Cmd>call ResizeWindow('down')<CR><Cmd>startinsert<CR>
  tnoremap <A-Left> <C-\><C-n><Cmd>call ResizeWindow('left')<CR><Cmd>startinsert<CR>
  tnoremap <A-Right> <C-\><C-n><Cmd>call ResizeWindow('right')<CR><Cmd>startinsert<CR>
  tnoremap <A-h> <C-\><C-n><Cmd>call ResizeWindow('left')<CR><Cmd>startinsert<CR>
  tnoremap <A-j> <C-\><C-n><Cmd>call ResizeWindow('down')<CR><Cmd>startinsert<CR>
  tnoremap <A-k> <C-\><C-n><Cmd>call ResizeWindow('up')<CR><Cmd>startinsert<CR>
  tnoremap <A-l> <C-\><C-n><Cmd>call ResizeWindow('right')<CR><Cmd>startinsert<CR>
  tnoremap <Esc> <C-\><C-n>
  tnoremap <C-h> <C-\><C-N><C-w>h
  tnoremap <C-j> <C-\><C-N><C-w>j
  tnoremap <C-k> <C-\><C-N><C-w>k
  tnoremap <C-l> <C-\><C-N><C-w>l

  " Neovim true color
  let $NVIM_TUI_ENABLE_TRUE_COLOR=1

  " CoC configuration
  source ~/.vim/vimrc/coc.vim

  " ClaudeCode {{{
    " Enter review mode: fullscreen (if not already), scroll to last prompt, stay in normal mode
    function! ClaudeReviewMode()
      let b:claude_stay_normal = 1
      if g:fullscreen_window != win_getid()
        call ToggleSplitFullscreen()
        call timer_start(50, {-> s:ScrollToLastPrompt()})
      else
        call s:ScrollToLastPrompt()
      endif
    endfunction

    " Scroll to the last user prompt in Claude terminal
    function! s:ScrollToLastPrompt()
lua << EOF
      vim.schedule(function()
        local bufnr = vim.api.nvim_get_current_buf()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        for i = #lines, 1, -1 do
          if lines[i]:match('^> ') or lines[i]:match('Ready to code%?') then
            vim.api.nvim_win_set_cursor(0, {i, 0})
            vim.cmd('normal! zt')
            return
          end
        end
        vim.cmd('normal! G')
      end)
EOF
    endfunction

    " Exit review mode: return to insert/terminal mode
    function! ClaudeExitReviewMode()
      let b:claude_stay_normal = 0
      startinsert
    endfunction

lua << EOF
    require('claudecode').setup({
      keys = { disable = true },
      focus_after_send = true,
      diff_opts = {
        layout = "vertical",
        open_in_new_tab = true,
        keep_terminal_focus = true,
      },
      terminal = {
        split_side = "left",
        snacks_win_opts = {
          position = "bottom",
          height = 0.4,
          width = 1.0,
        }
      },
      terminal_cmd = 'SHELL="$(which bash)" claude'
    })
EOF

    " ClaudeCode keybindings
    nmap <leader><Tab>c <cmd>ClaudeCode<cr>
    nmap <leader><Tab>f <cmd>ClaudeCodeFocus<cr>
    nmap <leader><Tab>r <cmd>ClaudeCode --resume<cr>
    nmap <leader><Tab><Tab> <cmd>ClaudeCode --continue<cr>
    nmap <leader><Tab>m <cmd>ClaudeCodeSelectModel<cr>
    nmap <leader><Tab>b <cmd>ClaudeCodeAdd %<cr>
    xmap <leader><Tab>s <cmd>ClaudeCodeSend<cr>
    nmap <leader><Tab>s V<cmd>ClaudeCodeSend<cr>
    nmap <leader><Tab>a <cmd>ClaudeCodeDiffAccept<cr>
    nmap <leader><Tab>d <cmd>ClaudeCodeDiffDeny<cr>

    " Diff navigation
    augroup claudecode_diff
      autocmd!
      autocmd OptionSet diff if &diff | call s:SetupDiffMappings() | endif
      autocmd BufEnter * if &diff | call s:SetupDiffMappings() | endif
    augroup END

    function! s:SetupDiffMappings()
      nnoremap <buffer> ]c ]czz
      nnoremap <buffer> [c [czz
      nnoremap <buffer> <leader>a <cmd>ClaudeCodeDiffAccept<cr>
      nnoremap <buffer> <leader>d <cmd>ClaudeCodeDiffDeny<cr>
      nnoremap <buffer> <leader>A <cmd>ClaudeCodeDiffAccept<cr>:tabnext<cr>
    endfunction

    " Auto-open Claude terminal when opening claude.md
    function! s:OpenClaudeIfNeeded()
      for bufnr in range(1, bufnr('$'))
        if bufname(bufnr) =~ 'claude' && getbufvar(bufnr, '&buftype') == 'terminal'
          return
        endif
      endfor
      ClaudeCode
    endfunction

    augroup claudecode_auto_open
      autocmd!
      autocmd BufRead claude.md call s:OpenClaudeIfNeeded()
    augroup END

    " Setup Claude terminal mappings (called from TermOpen and BufEnter)
    function! s:SetupClaudeTerminalMappings()
      if get(b:, 'claude_mappings_set', 0)
        return
      endif
      let b:claude_mappings_set = 1
      tnoremap <buffer> <c-h> <C-\><C-n>:TmuxNavigateLeft<CR>
      tnoremap <buffer> <c-j> <C-\><C-n>:TmuxNavigateDown<CR>
      tnoremap <buffer> <c-k> <C-\><C-n>:TmuxNavigateUp<CR>
      tnoremap <buffer> <c-l> <C-\><C-n>:TmuxNavigateRight<CR>
      tnoremap <buffer> <c-w>= <C-\><C-n>:call EqualizeWindows()<CR>:startinsert<CR>
      tnoremap <buffer> <c-p> <c-p>
      tnoremap <buffer> <c-n> <c-n>
      tnoremap <buffer> <c-f> <c-f>
      tnoremap <buffer> <M-Space> <Cmd>let b:claude_stay_normal=1<CR><C-\><C-n><Cmd>call ClaudeReviewMode()<CR>
      nnoremap <buffer> <M-Space> <Cmd>call ClaudeExitReviewMode()<CR>
      nnoremap <buffer> i <Cmd>call ClaudeExitReviewMode()<CR>
      nnoremap <buffer> <Esc> <Cmd>call ClaudeExitReviewMode()<CR>
      tnoremap <buffer> <Tab> <Cmd>let b:claude_stay_normal=1<CR><C-\><C-n>M
      nnoremap <buffer> <Tab> <Cmd>call ClaudeExitReviewMode()<CR>
    endfunction

    augroup claudecode_terminal
      autocmd!
      autocmd TermOpen *claude* call s:SetupClaudeTerminalMappings()
      autocmd BufEnter * if expand('%') =~ 'claude' && &buftype == 'terminal' | call s:SetupClaudeTerminalMappings() | endif
      autocmd BufEnter *claude* if &buftype == 'terminal' && !get(b:, 'claude_stay_normal', 0) | startinsert | endif
      autocmd WinEnter * if expand('%') =~ 'claude' && mode() != 't' && &buftype == 'terminal' && !get(b:, 'claude_stay_normal', 0) | startinsert | endif
      autocmd FocusGained * if expand('%') =~ 'claude' && &buftype == 'terminal' && !get(b:, 'claude_stay_normal', 0) | startinsert | endif
      autocmd CmdlineLeave * call timer_start(0, {-> execute("if expand('%') =~ 'claude' && &buftype == 'terminal' && !get(b:, 'claude_stay_normal', 0) | startinsert | endif")})
      autocmd TabEnter * call timer_start(50, {-> s:RotateDiffLayout()})
    augroup END

    function! s:RotateDiffLayout()
      let l:has_diff = 0
      let l:claude_win = 0
      for winnr in range(1, winnr('$'))
        if getwinvar(winnr, '&diff')
          let l:has_diff = 1
        endif
        let l:bufnr = winbufnr(winnr)
        if getbufvar(l:bufnr, '&buftype') == 'terminal' && bufname(l:bufnr) =~ 'claude'
          let l:claude_win = winnr
        endif
      endfor
      if l:has_diff && l:claude_win > 0
        execute l:claude_win . 'wincmd w'
        wincmd J
        let l:height = max([1, float2nr(&lines / 4)])
        execute 'resize ' . l:height
        startinsert
      endif
    endfunction
  " }}}

  " firenvim {{{
    let g:firenvim_config = {
        \ 'globalSettings': {
            \ 'alt': 'all',
        \  },
        \ 'localSettings': {
            \ '.*': {
                \ 'cmdline': 'neovim',
                \ 'priority': 0,
                \ 'selector': 'textarea',
                \ 'takeover': 'never',
            \ },
        \ }
    \ }

    if exists('g:started_by_firenvim')
      set laststatus=0
      set noconfirm
      let g:loaded_netrw       = 1
      let g:loaded_netrwPlugin = 1
      let g:loaded_vinegar = 1
      let g:loaded_lightline = 1
      let g:loaded_startify = 1
      let g:loaded_fugitive = 1
      let g:loaded_gitbranch = 1
      let g:loaded_gitgutter = 1
      let g:loaded_tmux_navigator = 1
      let g:loaded_vimux = 1
      let g:leaderf_loaded = 1
      let g:loaded_undotree = 1
      let g:loaded_sensible = 1

      nnoremap <C-q> :qa!<CR>
      unmap _
      unmap <c-e>
      nnoremap <Esc><Esc> :call firenvim#focus_page()<CR>
      nnoremap <C-z> :call firenvim#hide_frame()<CR>

      au BufEnter github.com_*.txt set filetype=markdown
      set wrap linebreak nolist
      set virtualedit=
      set display+=lastline
      noremap  <silent> k   gk
      noremap  <silent> j gj
      noremap  <silent> <Home> g<Home>
      noremap  <silent> <End>  g<End>
      inoremap <silent> k   <C-o>gk
      inoremap <silent> j <C-o>gj
      inoremap <silent> <Home> <C-o>g<Home>
      inoremap <silent> <End>  <C-o>g<End>
    endif
  " }}}

else
  " Vim-only settings
  let g:firenvim_loaded = 1

  " Vim fallback - basic terminal commands for Claude CLI
  nmap <leader>Cc :term claude<cr>
  nmap <leader>Cr :term claude --resume<cr>
  nmap <leader>CC :term claude --continue<cr>
endif

" ==========================================================
" Theme (loaded last)
" ==========================================================

source ~/.vim/vimrc/theme.vim
