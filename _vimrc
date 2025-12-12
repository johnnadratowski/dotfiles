" ==========================================================
" Plugins
" ==========================================================

call plug#begin()

Plug 'antoinemadec/coc-fzf', {'branch': 'release'}
Plug 'AndrewRadev/sideways.vim'
Plug 'airblade/vim-gitgutter'
Plug 'chrisbra/NrrwRgn'
Plug 'chrisbra/matchit'
Plug 'christoomey/vim-tmux-navigator'
Plug 'dbeniamine/cheat.sh-vim'
Plug 'direnv/direnv.vim'
Plug 'editorconfig/editorconfig-vim'
Plug 'fatih/vim-go'
Plug 'glacambre/firenvim'
Plug 'heavenshell/vim-pydocstring', { 'do': 'make install', 'for': 'python' }
Plug 'itchyny/landscape.vim'
Plug 'itchyny/lightline.vim'
Plug 'itchyny/vim-gitbranch'
Plug 'johnnadratowski/molokai'
Plug 'johnnadratowski/vim-pug'
Plug 'johnnadratowski/vim-stylus'
Plug 'junegunn/fzf', {'dir': '~/.fzf','do': './install --all'}
Plug 'junegunn/fzf.vim' " needed for previews
Plug 'junegunn/limelight.vim'
Plug 'junegunn/vim-easy-align'
Plug 'nvim-lua/plenary.nvim'
Plug 'madox2/vim-ai'
Plug 'kchmck/vim-coffee-script'
Plug 'kristijanhusak/vim-dadbod-ui'
Plug 'leafgarland/typescript-vim'
Plug 'leafOfTree/vim-vue-plugin'
Plug 'maxbrunsfeld/vim-emacs-bindings'
Plug 'mbbill/undotree'
Plug 'mhinz/vim-startify'
Plug 'neoclide/coc.nvim', {'branch': 'release'}
Plug 'nvim-tree/nvim-web-devicons'
Plug 'pbogut/vim-dadbod-ssh'
Plug 'preservim/vim-colors-pencil' " Theme
Plug 'preservim/vim-wordchipper' " Shortcuts for insert mode
Plug 'preservim/vimux'
Plug 'prettier/vim-prettier'
Plug 'reedes/vim-lexical' " Better spellcheck mappings
Plug 'reedes/vim-litecorrect' " Better autocorrections
Plug 'reedes/vim-pencil' " Super-powered writing things
Plug 'reedes/vim-textobj-sentence' " Treat sentences as text objects
Plug 'reedes/vim-textobj-quote' " Treat quotes as text objects
Plug 'reedes/vim-wordy' " Weasel words and passive voice
Plug 'ryanoasis/vim-devicons' " For vim compatibility (nvim-web-devicons for neovim)
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
Plug 'ttibsi/pre-commit.nvim'
if has('nvim')
  Plug 'folke/snacks.nvim'
  Plug 'coder/claudecode.nvim'
endif
Plug 'vim-test/vim-test'
Plug 'wesQ3/vim-windowswap'
Plug 'yggdroot/LeaderF', { 'do': ':LeaderfInstallCExtension' }

call plug#end()

let g:coc_global_extensions = [ 
      \ 'coc-css', 
      \ 'coc-db',
      \ 'coc-dictionary',
      \ 'coc-emoji', 
      \ 'coc-eslint', 
      \ 'coc-go', 
      \ 'coc-highlight', 
      \ 'coc-html', 
      \ 'coc-json', 
      \ 'coc-lightbulb', 
      \ 'coc-omni', 
      \ 'coc-prettier', 
      \ 'coc-pyright', 
      \ 'coc-sh', 
      \ 'coc-snippets', 
      \ 'coc-sql', 
      \ 'coc-tsserver', 
      \ 'coc-vimlsp',
      \ ]

" ==========================================================
" Basic Settings
" ==========================================================

" Allow control characters to pass to vim for shortcuts
silent !stty -ixon > /dev/null 2>/dev/null

let mapleader=" "             " Map leader key to space

set clipboard=unnamed       " Use system clipboard
set cmdheight=2             " CoC - Give more space for displaying messages.
set colorcolumn=0           " The right hand gutter
set conceallevel=0          " The level to hide in a file
set confirm                 " Y-N-C prompt if closing with unsaved changes.
set cursorline              " have a line indicate the cursor location
set expandtab               " Use spaces, not tabs, for autoindent/tab key.
set ffs=unix,dos,mac        " Try recognizing dos, unix, and mac line endings.
set foldcolumn=0            " space of folds to be shown in sidebar
set foldlevel=2             " fold to 2nd level
set foldmethod=marker       " allow us to fold on indents
set foldmarker=#region,#endregion " fold based on #region / #endregion
set grepprg=ag              " replace the default grep program with ag
set hidden                  " CoC - TextEdit might fail if hidden is not set.
set history=1000            " Command history
set hlsearch                " Highlight searches by default.
set ignorecase              " Default to using case insensitive searches,
set incsearch               " Incremental search
set laststatus=2            " Always show statusline, even if only 1 window.
set lazyredraw              " Don't redraw screen in middle of macro
set linebreak               " don't wrap textin the middle of a word
set list                    " Show Whitespaces
set matchpairs+=<:>         " show matching <> (html mainly) as well
set modeline                " Allow vim options to be embedded in files;
set modelines=5             " they must be within the first or last 5 lines.
set mouse=a                 " Allow mouse
set mousehide               " Hid emouse when typing
set autoread                " Auto-reload files changed outside vim
set nobackup                " No backup file
set noerrorbells            " No bell on error
set nofoldenable            " DO NOT enable folds by default
set noshowmode              " Do not show the current mode, as we use lightline
set nostartofline           " Avoid moving cursor to BOL when jumping around
set noswapfile              " No swap file
set nowb                    " Make a write backup for write errors
set nowrap                  " No text wrapping by default
set nowritebackup           " CoC - some servers might have problesmw ith backup
set number                  " Show line numbers
set report=0                " : commands always print changed line count.
set scrolloff=5             " Number of lines to show above/below cursor
set shiftround              " rounds indent to a multiple of shiftwidth
set shiftwidth=2            " but an indent level is 2 spaces wide.
set shortmess+=a            " Use [+]/[RO]/[w] for modified/readonly/written.
set shortmess+=c            " CoC - Don't pass messages to |ins-completion-menu|. 
set showbreak=➡\            " Character to show at word wrap
set showcmd                 " Show incomplete normal mode commands as I type.
set showmatch               " Briefly jump to a paren once it's balanced
set signcolumn=yes          " CoC - Always show the signcolumn
set smartcase               " unless uppercase letters are used in the regex.
set smartindent             " use smart indent if there is no indent file
set softtabstop=2           " <BS> over an autoindent deletes both spaces.
set tabstop=2               " <tab> inserts 2 spaces
set updatetime=300          " CoC - user experience
set virtualedit=block       " Let cursor move past the last char in <C-v> mode
set visualbell              " Allow visual bells
set wildignore+=*.egg-info/**,eggs/**    " Ignore python egg folders
set wildignore+=*.o,*.obj,.git,*.pyc     " Ignore python, object, git files
set wildignore+=*/node_modules/**        " Ignore node modules
set wildignore+=*/tmp/*,*.so,*.swp,*.zip " Ignore temp, so, swap, and zip
set wildignore+=*/vendor/**              " Ignore vendor sources
set wildmode=longest,list,full             " <Tab> cycles between all matching choices.

" ==========================================================
" Keymaps
" ==========================================================

" Save buffer
nmap <c-s> :update!<CR>
imap <c-s> <Esc> :update!<CR>
nmap <M-s> :noautocmd update!<CR>
imap <M-s> <Esc>:noautocmd update!<CR>
nmap <F2> :update<CR>
imap <F2> <C-O>:update<CR>

" Scratch buffer creation
command! -nargs=* -bang -range -complete=filetype Scratch
            \ :call ScratchBuffer()
            \ | set filetype=<args>
nmap <leader>t :Scratch<CR>
nmap <leader>T :Scratch 

nmap <leader>bd :call WipeoutBuffers()<CR>

nmap <leader>sb :call SplitScroll()<CR>

" Fix weird behavior of Y
map Y y$

" for when we forget to use sudo to open/edit a file
cmap w!! w !sudo tee % >/dev/null
cmap W! w !sudo tee % >/dev/null

" Maximize/minimize
map <leader>^ <c-w>_<c-w>\|
map <leader>= <c-w>=

" Helper to temporarily disable winfixwidth/winfixheight on all windows
function! s:DisableWinFix()
  let l:saved = {}
  for winnr in range(1, winnr('$'))
    let winid = win_getid(winnr)
    let l:saved[winid] = {
          \ 'fixwidth': getwinvar(winnr, '&winfixwidth'),
          \ 'fixheight': getwinvar(winnr, '&winfixheight')
          \ }
    call setwinvar(winnr, '&winfixwidth', 0)
    call setwinvar(winnr, '&winfixheight', 0)
  endfor
  return l:saved
endfunction

function! s:RestoreWinFix(saved)
  for winnr in range(1, winnr('$'))
    let winid = win_getid(winnr)
    if has_key(a:saved, winid)
      call setwinvar(winnr, '&winfixwidth', a:saved[winid]['fixwidth'])
      call setwinvar(winnr, '&winfixheight', a:saved[winid]['fixheight'])
    endif
  endfor
endfunction

" Notify terminal windows of resize
function! s:RefreshTerminals()
  let l:curwin = win_getid()
  for winnr in range(1, winnr('$'))
    let bufnr = winbufnr(winnr)
    if getbufvar(bufnr, '&buftype') == 'terminal'
      call win_gotoid(win_getid(winnr))
      " Trigger resize by briefly entering and exiting terminal mode
      if has('nvim')
        call feedkeys("\<C-\>\<C-n>i\<C-\>\<C-n>", 'n')
      endif
    endif
  endfor
  call win_gotoid(l:curwin)
endfunction

" Toggle fullscreen for current split
let g:fullscreen_window = 0
let g:fullscreen_saved_sizes = {}

" Save window sizes before going fullscreen
function! s:SaveWindowSizes()
  let l:sizes = {}
  let l:sizes['_winids'] = []
  for winnr in range(1, winnr('$'))
    let winid = win_getid(winnr)
    call add(l:sizes['_winids'], winid)
    let l:sizes[winid] = {
          \ 'width': winwidth(winnr),
          \ 'height': winheight(winnr)
          \ }
  endfor
  return l:sizes
endfunction

" Check if window configuration has changed
function! s:WindowConfigChanged(saved)
  if empty(a:saved) || !has_key(a:saved, '_winids')
    return 1
  endif
  let l:current_winids = []
  for winnr in range(1, winnr('$'))
    call add(l:current_winids, win_getid(winnr))
  endfor
  return l:current_winids != a:saved['_winids']
endfunction

" Restore window sizes
function! s:RestoreWindowSizes(saved)
  if s:WindowConfigChanged(a:saved)
    " Configuration changed, use equal sizes
    execute "normal! \<C-w>="
    return
  endif
  " Save current window to restore focus later
  let l:curwin = win_getid()
  " Restore each window's size
  for winnr in range(1, winnr('$'))
    let winid = win_getid(winnr)
    if has_key(a:saved, winid)
      call win_gotoid(winid)
      execute 'resize ' . a:saved[winid]['height']
      execute 'vertical resize ' . a:saved[winid]['width']
    endif
  endfor
  " Restore focus to original window
  call win_gotoid(l:curwin)
endfunction

function! ToggleSplitFullscreen()
  let l:saved_fix = s:DisableWinFix()

  if g:fullscreen_window == win_getid()
    " Exiting fullscreen - clear flag first to prevent WinEnter re-triggering
    let l:saved_sizes = g:fullscreen_saved_sizes
    let g:fullscreen_window = 0
    let g:fullscreen_saved_sizes = {}
    call s:RestoreWindowSizes(l:saved_sizes)
  elseif g:fullscreen_window != 0
    " Different window going fullscreen while another was fullscreen
    " Just maximize this window, keep the original saved sizes
    execute "normal! \<C-w>_\<C-w>|"
    let g:fullscreen_window = win_getid()
  else
    " Entering fullscreen - save current sizes first
    let g:fullscreen_saved_sizes = s:SaveWindowSizes()
    execute "normal! \<C-w>_\<C-w>|"
    let g:fullscreen_window = win_getid()
  endif

  call s:RestoreWinFix(l:saved_fix)
  call s:RefreshTerminals()
endfunction

" Auto-fullscreen when focusing a different window while in fullscreen mode
function! s:AutoFullscreenOnFocus()
  if g:fullscreen_window != 0 && g:fullscreen_window != win_getid()
    call ToggleSplitFullscreen()
  endif
endfunction

augroup fullscreen_auto
  autocmd!
  autocmd WinEnter * call s:AutoFullscreenOnFocus()
augroup END

nnoremap <C-space> :call ToggleSplitFullscreen()<CR>
tnoremap <C-space> <C-\><C-n>:call ToggleSplitFullscreen()<CR>i

" Close Window
map <leader>x :bp \| bd #<CR>
map <leader>w :clo<CR>

" hide matches on <leader>space
nnoremap <leader><space> :nohlsearch<cr>

" Toggle word wrap
noremap <silent> <leader>W :call ToggleWrap()<CR>

" Close all non-buffer windows
nnoremap <silent> <Plug>(close-side-windows) :cclo <bar> :VimuxCloseRunner<CR>

" Quit window
nnoremap <C-q> :execute "normal \<Plug>(close-side-windows)" <bar> :qa<CR>

" Reload Vimrc
map <silent> <leader>V :source ~/.vimrc<CR>:exe ":echo 'vimrc reloaded'"<CR>
augroup myvimrc
  au!
  au BufWritePost .vimrc,_vimrc,vimrc,*/_vim/*,*/.vim/*.gvimrc,_gvimrc,gvimrc so $MYVIMRC | if has('gui_running') | so $MYGVIMRC | endif | echo "vimrc reloaded"
augroup END

vnoremap <leader>v :CreateRegion<CR>

" Stay in visual selection mode when changing indent
vnoremap < <gv
vnoremap > >gv

" Resize splits with arrow keys (handles winfixwidth/height)
function! ResizeWindow(dir)
  let l:saved_fix = s:DisableWinFix()
  if a:dir == 'up'
    resize +2
  elseif a:dir == 'down'
    resize -2
  elseif a:dir == 'left'
    vertical resize -2
  elseif a:dir == 'right'
    vertical resize +2
  endif
  call s:RestoreWinFix(l:saved_fix)
  " call s:RefreshTerminals()
endfunction
nnoremap <A-Up> :call ResizeWindow('up')<CR>
nnoremap <A-Down> :call ResizeWindow('down')<CR>
nnoremap <A-Left> :call ResizeWindow('left')<CR>
nnoremap <A-Right> :call ResizeWindow('right')<CR>
tnoremap <A-Up> <C-\><C-n><Cmd>call ResizeWindow('up')<CR><Cmd>startinsert<CR>
tnoremap <A-Down> <C-\><C-n><Cmd>call ResizeWindow('down')<CR><Cmd>startinsert<CR>
tnoremap <A-Left> <C-\><C-n><Cmd>call ResizeWindow('left')<CR><Cmd>startinsert<CR>
tnoremap <A-Right> <C-\><C-n><Cmd>call ResizeWindow('right')<CR><Cmd>startinsert<CR>

" Move lines up/down
nnoremap <A-j> :m .+1<CR>==
nnoremap <A-k> :m .-2<CR>==
vnoremap <A-j> :m '>+1<CR>gv=gv
vnoremap <A-k> :m '<-2<CR>gv=gv

" Keep cursor centered when scrolling/searching
nnoremap n nzzzv
nnoremap N Nzzzv
nnoremap <C-d> <C-d>zz
nnoremap <C-u> <C-u>zz

" ==========================================================
" Plugin Settings + Keymaps
" ==========================================================

" ClaudeCode {{{
  " Enter review mode: fullscreen (if not already), go to middle of buffer, stay in normal mode
  function! ClaudeReviewMode()
    let b:claude_stay_normal = 1
    " Only go fullscreen if not already fullscreen
    if g:fullscreen_window != win_getid()
      call ToggleSplitFullscreen()
      " Go to bottom of buffer, then M to middle of screen (delay to run after RefreshTerminals)
      call timer_start(50, {-> feedkeys("GM", "n")})
    else
      lua vim.schedule(function() vim.api.nvim_feedkeys("M", "n", false) end)
    endif
  endfunction

  " Exit review mode: return to insert/terminal mode (don't change fullscreen)
  function! ClaudeExitReviewMode()
    let b:claude_stay_normal = 0
    startinsert
  endfunction

  if has('nvim')
    lua << EOF
    require('claudecode').setup({
      -- Disable default keymaps, we'll set our own with <leader>C
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
    " Neovim keybindings using <leader><Tab> prefix
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

    " Fix Cmd+hjkl navigation in Claude terminal (macOS sends D-h, D-j, etc.)
    " Also disable Leaderf mappings (C-p, C-n, C-f) in Claude terminal
    " Auto-enter insert mode when entering Claude terminal
    augroup claudecode_terminal
      autocmd!
      autocmd TermOpen *claude* tnoremap <buffer> <c-h> <C-\><C-n>:TmuxNavigateLeft<CR>
      autocmd TermOpen *claude* tnoremap <buffer> <c-j> <C-\><C-n>:TmuxNavigateDown<CR>
      autocmd TermOpen *claude* tnoremap <buffer> <c-k> <C-\><C-n>:TmuxNavigateUp<CR>
      autocmd TermOpen *claude* tnoremap <buffer> <c-l> <C-\><C-n>:TmuxNavigateRight<CR>
      autocmd TermOpen *claude* tnoremap <buffer> <c-p> <c-p>
      autocmd TermOpen *claude* tnoremap <buffer> <c-n> <c-n>
      autocmd TermOpen *claude* tnoremap <buffer> <c-f> <c-f>
      autocmd TermOpen *claude* tnoremap <buffer> <M-Space> <Cmd>let b:claude_stay_normal=1<CR><C-\><C-n><Cmd>call ClaudeReviewMode()<CR>
      autocmd TermOpen *claude* nnoremap <buffer> <M-Space> <Cmd>call ClaudeExitReviewMode()<CR>
      autocmd TermOpen *claude* nnoremap <buffer> i <Cmd>call ClaudeExitReviewMode()<CR>
      autocmd TermOpen *claude* nnoremap <buffer> <Esc> <Cmd>call ClaudeExitReviewMode()<CR>
      autocmd BufEnter *claude* if &buftype == 'terminal' && !get(b:, 'claude_stay_normal', 0) | startinsert | endif
      autocmd WinEnter * if expand('%') =~ 'claude' && mode() != 't' && &buftype == 'terminal' && !get(b:, 'claude_stay_normal', 0) | startinsert | endif
      autocmd FocusGained * if expand('%') =~ 'claude' && &buftype == 'terminal' && !get(b:, 'claude_stay_normal', 0) | startinsert | endif
      autocmd CmdlineLeave * call timer_start(0, {-> execute("if expand('%') =~ 'claude' && &buftype == 'terminal' && !get(b:, 'claude_stay_normal', 0) | startinsert | endif")})
      " Rotate diff tab layout to put Claude terminal at bottom
      autocmd TabEnter * call timer_start(50, {-> s:RotateDiffLayout()})
    augroup END

  function! s:RotateDiffLayout()
    " Check if any window in this tab has diff mode
    let l:has_diff = 0
    let l:claude_win = 0
    for winnr in range(1, winnr('$'))
      if getwinvar(winnr, '&diff')
        let l:has_diff = 1
      endif
      " Find Claude terminal: must be a terminal buffer with 'claude' in name
      let l:bufnr = winbufnr(winnr)
      if getbufvar(l:bufnr, '&buftype') == 'terminal' && bufname(l:bufnr) =~ 'claude'
        let l:claude_win = winnr
      endif
    endfor
    " If this is a diff tab with Claude terminal, move terminal to bottom
    if l:has_diff && l:claude_win > 0
      execute l:claude_win . 'wincmd w'
      wincmd J
      " Resize to 25% of total height
      execute 'resize ' . (&lines / 4)
      " Keep focus on Claude terminal
      startinsert
    endif
  endfunction
  else
    " Vim fallback - basic terminal commands for Claude CLI
    nmap <leader>Cc :term claude<cr>
    nmap <leader>Cr :term claude --resume<cr>
    nmap <leader>CC :term claude --continue<cr>
  endif
" }}}


" vim-ai {{{
  let g:gpt_api_key = $GPT_API_TOKEN
  inoremap <C-g> <Esc> :AIEdit 
  vnoremap <C-g> :AIEdit 
  noremap <C-g> :AIEdit 

  vnoremap <leader>g :AI
  noremap <leader>g :AI
" }}}

" Pug {{{
  augroup pug
    au!
    " Horrible hack to get pug files to display syntax highlighting.  Need to
    " redetect file but after reload, or all highlighting doesn't work.
    au BufNewFile,BufRead,BufReadPost,BufEnter *.pug call timer_start(20, { tid -> execute('filetype detect')})
  augroup END
" }}}

" Less {{{
  augroup less
    au!
    " Horrible hack to get less files to display syntax highlighting.  Need to
    " redetect file but after reload, or all highlighting doesn't work.
    au BufNewFile,BufRead,BufReadPost,BufEnter *.less call timer_start(20, { tid -> execute('filetype detect')})
  augroup END
" }}}

" JSON {{{
  " Disable quote concealing in JSON files
  let g:vim_json_conceal=0
" }}}

" DBUI {{{
  nmap <leader>d :DBUIToggle<CR>
  augroup dbui
    autocmd!
    autocmd filetype sql nnoremap <buffer> <Enter> :DB<CR>
    autocmd filetype dbui nnoremap <buffer> <c-k> :TmuxNavigateUp<CR>
    autocmd filetype dbui nnoremap <buffer> <c-j> :TmuxNavigateDown<CR>
  augroup END

  if (has("nvim"))

    " Make escape work in the Neovim terminal.
    tnoremap <Esc> <C-\><C-n>

    " Make navigation into and out of Neovim terminal splits nicer.
    tnoremap <C-h> <C-\><C-N><C-w>h
    tnoremap <C-j> <C-\><C-N><C-w>j
    tnoremap <C-k> <C-\><C-N><C-w>k
    tnoremap <C-l> <C-\><C-N><C-w>l

  endif 
" }}}

" Netrw {{{
  let g:netrw_localcopycmd='cp'
  map <c-e> :call ExploreSessionRoot()<CR>
  map _ :call ExploreGitRoot()<CR>

  augroup netrw
    autocmd!
    autocmd filetype netrw call NetrwMapping()
    autocmd filetype netrw setl bufhidden=wipe
  augroup END
  
  function! NetrwMapping()
    nnoremap <buffer> <c-l> :TmuxNavigateRight<CR>
    nmap <buffer> <C-[> :bn<CR>
    "Leader-d duplicates file under cursor
    nnoremap <buffer> <silent> <Leader>d :call NetrwDuplicateFile()<CR>
  endfunction

  function! NetrwDuplicateFile()
    let l:curfile = netrw#Call("NetrwGetWord")
    if l:curfile == ''
      echo "No file under cursor"
      return
    endif
    let l:curdir = b:netrw_curdir
    let l:srcpath = l:curdir . '/' . l:curfile
    " Get extension and base name
    let l:ext = fnamemodify(l:curfile, ':e')
    let l:base = fnamemodify(l:curfile, ':r')
    if l:ext != ''
      let l:destfile = l:base . '-copy.' . l:ext
    else
      let l:destfile = l:curfile . '-copy'
    endif
    let l:destpath = l:curdir . '/' . l:destfile
    silent exec "!cp " . shellescape(l:srcpath) . " " . shellescape(l:destpath)
    redraw!
    echo "Copied " . l:curfile . " to " . l:destfile
  endfunction

" }}}

" markdown {{{

  let g:languagetool_jar='$HOME/LanguageTool-5.9/languagetool-commandline.jar'

  let g:pencil#wrapModeDefault = 'soft'
  let g:pencil#textwidth = 74
  let g:pencil#joinspaces = 2
  let g:pencil#cursorwrap = 1
  let g:pencil#conceallevel = 3
  let g:pencil#concealcursor = 'c'
  let g:pencil#softDetectSample = 20
  let g:pencil#softDetectThreshold = 130

  function SetMDOptions()
    setlocal wrap
    setlocal noexpandtab
    setl spell spl=en_us fdl=4 noru nonu nornu
    setl fdo+=search

    let g:lexical#spell_key = '<leader>s'
    let g:lexical#dictionary_key = '<leader>k'
    let g:lexical#thesaurus_key = '<leader>t' " Overrwites scratchpad mapping

    " Sentence Movement
    let g:textobj#sentence#select = 's'
    let g:textobj#sentence#move_p = '('
    let g:textobj#sentence#move_n = ')'

    " Litecorrect fix word
    nnoremap <M-s> [s1z=<c-o>
    inoremap <M-s> <c-g>u<Esc>[s1z=`]A<c-g>u

    " Wordchipper - delete with movement on keybind in insert
    inoremap <buffer> <expr> <C-e> wordchipper#chipWith('de')
    inoremap <buffer> <expr> <C-w> wordchipper#chipWith('dB')
    inoremap <buffer> <expr> <C-y> wordchipper#chipWith('d)')

    " Go to next wordy error
    noremap <silent> <F8> :<C-u>NextWordy<cr>
    xnoremap <silent> <F8> :<C-u>NextWordy<cr>
    inoremap <silent> <F8> <C-o>:NextWordy<cr>
    noremap <silent> <S-F8> :<C-u>PrevWordy<cr>
    xnoremap <silent> <S-F8> :<C-u>PrevWordy<cr>
    inoremap <silent> <S-F8> <C-o>:PrevWordy<cr>

    call pencil#init()
    call lexical#init()
    call litecorrect#init()
  endfunction

  augroup markdown
    autocmd!
    autocmd Filetype markdown,mkd,md,text call SetMDOptions()
  augroup END

" }}}

" stylus {{{
  augroup stylus
    autocmd!
    autocmd FileType stylus setlocal commentstring=//\ %s
  augroup END
" }}}

" typescript {{{
  augroup typescript_vue
    autocmd!
    autocmd FileType typescript setlocal re=2
    autocmd FileType vue setlocal re=2
  augroup END
" }}}

" NrrwRng {{{

  command! -nargs=* -bang -range -complete=filetype NN
              \ :<line1>,<line2> call nrrwrgn#NrrwRgn('',<q-bang>)
              \ | set filetype=<args>

" }}}

" vim-sideways {{{

  nmap ( :SidewaysLeft<CR>
  nmap ) :SidewaysRight<CR>
  omap aa <Plug>SidewaysArgumentTextobjA
  xmap aa <Plug>SidewaysArgumentTextobjA
  omap ia <Plug>SidewaysArgumentTextobjI
  xmap ia <Plug>SidewaysArgumentTextobjI

" }}}

" vim-test {{{

  let test#strategy = 'vimux'
  nmap <silent> t<C-n> :let test#project_root=GetGitRoot(expand('%')) \| TestNearest<CR>
  nmap <silent> t<C-f> :let test#project_root=GetGitRoot(expand('%')) \| TestFile<CR>
  nmap <silent> t<C-s> :let test#project_root=GetGitRoot(expand('%')) \| TestSuite<CR>
  nmap <silent> t<C-l> :let test#project_root=GetGitRoot(expand('%')) \| TestLast<CR>
  nmap <silent> t<C-g> :let test#project_root=GetGitRoot(expand('%')) \| TestVisit<CR>

" }}}


" rainbow parens {{{
  let g:rainbow_active = 1
" }}}


" easyalign {{{

  " Start interactive EasyAlign in visual mode (e.g. vipga)
  xmap ga <Plug>(EasyAlign)
  " Start interactive EasyAlign for a motion/text object (e.g. gaip)
  nmap ga <Plug>(EasyAlign)

" }}}
  

" gitgutter {{{
  if !exists("g:jn_statusline_updated")
    set statusline+=%{GitStatus()}
  endif
  let g:jn_statusline_updated = 1

" }}}


" vim-lightline {{{
  let g:lightline = {
        \ 'colorscheme': 'wombat',
        \ 'mode_map': {
        \ 'n' : 'N',
        \ 'i' : 'I',
        \ 'R' : 'R',
        \ 'v' : 'V',
        \ 'V' : 'VL',
        \ "\<C-v>": 'VB',
        \ 'c' : 'C',
        \ 's' : 'S',
        \ 'S' : 'SL',
        \ "\<C-s>": 'SB',
        \ 't': 'T',
        \ },
        \ 'active': {
        \   'left': [ [ 'mode', 'paste' ],
        \             [ 'gitroot', 'gitbranch', 'gitstatus', 'readonly', 'filename', 'modified' ] ]
        \ },
        \ 'component_function': {
        \   'gitbranch': 'gitbranch#name',
        \   'gitstatus': 'GitStatus',
        \   'gitroot': 'RootName'
        \ },
        \ 'component': {
        \   'filename': '%F'
        \ },
        \ }
" }}}


" Renamer {{{
  source ~/.vim/vimrc/renamer.vim
" }}}


" vim-startify {{{
  nmap <leader>H :Startify<CR>

  let g:startify_change_to_dir       = 0

  let g:startify_custom_header = [
        \'⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜',
        \'⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜',
        \'⬜⬜⬜⬜🟨🟨⬜⬜⬜⬜⬜⬜⬜⬜⬜',
        \'⬜⬜⬜⬜🟨🟨⬜⬜⬜⬜⬜⬜⬜⬜⬜',
        \'⬜⬜⬜⬜🟨🟨⬜⬜⬜⬜⬜⬜⬜⬜⬜',
        \'⬜⬜⬜⬜🟨🟨⬜⬛⬛⬜⬜⬜⬛⬛⬜',
        \'⬜⬜⬜⬜🟨🟨⬜⬛⬛⬛⬜⬜⬛⬛⬜',
        \'⬜⬜⬜⬜🟨🟨⬜⬛⬛⬛⬛⬜⬛⬛⬜',
        \'⬜🟨🟨🟨🟨🟨⬜⬛⬛⬛⬛⬛⬛⬛⬜',
        \'⬜🟨🟨🟨🟨🟨⬜⬛⬛⬜⬛⬛⬛⬛⬜',
        \'⬜⬜⬜⬜⬜⬜⬜⬛⬛⬜⬜⬛⬛⬛⬜',
        \'⬜⬜⬜⬜⬜⬜⬜⬛⬛⬜⬜⬜⬛⬛⬜',
        \'⬜⬜⬜⬜⬜⬜⬜⬛⬛⬜⬜⬜⬛⬛⬜',
        \'⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜',
        \'⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜⬜',
        \]

  let g:startify_bookmarks = [ {'v': '~/.vimrc'}, {'z': '~/.zshrc'} ]

  let g:startify_commands = [
      \ {'c': 'Cht'},
      \ ['Vim Reference', 'h ref'],
      \ ]

  let g:startify_lists = [
        \ { 'type': 'dir',       'header': ['   MRU '. getcwd()] },
        \ { 'type': 'commands',  'header': ['   Commands']       },
        \ { 'type': 'sessions',  'header': ['   Sessions']       },
        \ { 'type': 'bookmarks', 'header': ['   Bookmarks']      },
        \ { 'type': 'files',     'header': ['   MRU']            },
        \ ]
" }}}


" vim-go {{{
  " disable vim-go :GoDef short cut (gd)
  " this is handled by LanguageClient [LC]
  let g:go_def_mapping_enabled = 0
  augroup golang
    au BufWritePost *.go :GoImports
  augroup END

" }}}


" vim-prettier {{{
  let g:prettier#autoformat = 1
  let g:prettier#autoformat_require_pragma = 0
  let g:prettier#autoformat_config_present = 1
  let g:prettier#config#arrow_parens = 'always'

" }}}


" Pydocstring {{{
  let g:pydocstring_enable_mapping = 0
" }}}


" Persistent Undo {{{

  " Keep undo history across sessions, by storing in file.
  " Only works all the time.
  if has('persistent_undo')
    silent !mkdir -p ~/tmp/backups > /dev/null 2>&1
    set undodir=~/tmp/backups
    set undofile
  endif

" }}}


" vim-commentary {{{
  augroup vim_commentary
    autocmd!
    autocmd FileType vim setlocal commentstring=\"\ %s
    autocmd FileType vimrc setlocal commentstring=\"\ %s
    autocmd FileType vue setlocal commentstring=//\ %s
  augroup END
" }}}


" vim-workspace {{{
  nnoremap <leader>` :ToggleWorkspace<CR>
  let g:workspace_autosave = 0

" }}}


" vim-windowswap {{{
  let g:windowswap_map_keys = 0 "prevent default bindings
  nnoremap <silent> <leader>s :call WindowSwap#EasyWindowSwap()<CR>

" }}}


" vim-vue-plugin {{{
  let g:vim_vue_plugin_config = { 
        \'syntax': {
        \   'template': ['html', 'pug'],
        \   'script': ['javascript', 'typescript'],
        \   'style': ['css', 'stylus'],
        \},
        \'full_syntax': [],
        \'initial_indent': [],
        \'attribute': 0,
        \'keyword': 0,
        \'foldexpr': 0,
        \'debug': 0,
        \}

" }}}


" CoC {{{
  source ~/.vim/vimrc/coc.vim
" }}}


" Leaderf {{{
  source ~/.vim/vimrc/leaderf.vim
" }}}


" Undotree {{{
  map <leader>u :UndotreeToggle<CR>
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
    " Remove statusline and confirmation message on close
    set laststatus=0
    set noconfirm

    " Remove filesystem stuff
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

    " Update keybindings
    nnoremap <C-q> :qa!<CR>
    unmap _
    unmap <c-e>
    nnoremap <Esc><Esc> :call firenvim#focus_page()<CR>
    nnoremap <C-z> :call firenvim#hide_frame()<CR>

    " Assume editing markdown in github
    au BufEnter github.com_*.txt set filetype=markdown
    
    " set wrapping
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



" ==========================================================
" Functions
" ==========================================================

function! CreateRegionFold() range
  " Get the first line (the comment)
  let firstline = getline(a:firstline)

  " Extract indentation from the first line
  let indent = matchstr(firstline, '^\s*')

  " Extract comment text (remove comment markers)
  let comment_text = substitute(firstline, '^\s*//\s*', '', '')
  let comment_text = substitute(comment_text, '^\s*/\*\s*', '', '')
  let comment_text = substitute(comment_text, '\s*\*/\s*$', '', '')
  let comment_text = substitute(comment_text, '^\s*#\s*', '', '')

  " Insert #region at the first line with proper indentation
  call setline(a:firstline, indent . '// #region ' . comment_text)

  " Insert #endregion at the last line + 1 with proper indentation
  call append(a:lastline, indent . '// #endregion')
endfunction
command! -range CreateRegion <line1>,<line2>call CreateRegionFold()

function! WipeoutBuffers()
  " list of *all* buffer numbers
  let l:buffers = range(1, bufnr('$'))

  " what tab page are we in?
  let l:currentTab = tabpagenr()
  try
    " go through all tab pages
    let l:tab = 0
    while l:tab < tabpagenr('$')
      let l:tab += 1

      " go through all windows
      let l:win = 0
      while l:win < winnr('$')
        let l:win += 1
        " whatever buffer is in this window in this tab, remove it from
        " l:buffers list
        let l:thisbuf = winbufnr(l:win)
        call remove(l:buffers, index(l:buffers, l:thisbuf))
      endwhile
    endwhile

    " if there are any buffers left, delete them
    if len(l:buffers)
      execute 'bwipeout' join(l:buffers)
    endif
  finally
    " go back to our original tab page
    execute 'tabnext' l:currentTab
  endtry
endfunction

fu! SplitScroll()
    :wincmd v
    :wincmd w
    execute "normal! \<C-d>"
    :set scrollbind
    :wincmd w
    :set scrollbind
endfu

function! ToggleWrap()
  if &wrap
    echo "Wrap OFF"
    setlocal nowrap
    set virtualedit=all
    silent! nunmap <buffer> k
    silent! nunmap <buffer> j
    silent! nunmap <buffer> <Home>
    silent! nunmap <buffer> <End>
    silent! iunmap <buffer> k
    silent! iunmap <buffer> j
    silent! iunmap <buffer> <Home>
    silent! iunmap <buffer> <End>
  else
    echo "Wrap ON"
    setlocal wrap linebreak nolist
    set virtualedit=
    setlocal display+=lastline
    noremap  <buffer> <silent> k   gk
    noremap  <buffer> <silent> j gj
    noremap  <buffer> <silent> <Home> g<Home>
    noremap  <buffer> <silent> <End>  g<End>
  endif
endfunction

function! RootName()
  return fnamemodify(GetGitRoot(GetCurFile()), ":t")
endfunction

function! GitStatus()
  let [a,m,r] = GitGutterGetHunkSummary()
  return printf('+%d ~%d -%d', a, m, r)
endfunction

function! GetCurFile()
  try
    let l:curFile = expand('%:p')
  catch /.*/
    echo "Error getting current file: " . v:exception
  endtry
  if l:curFile == ""
    let l:curFile = getcwd()
  endif
  return fnamemodify(l:curFile, ':p')
endfunction

function! CDGitRoot()
  let l:curFile = GetCurFile()
  try
    let l:root = GetGitRoot(l:curFile)
  catch /.*/
    echo "Error getting git root: " . v:exception
    return
  endtry
  if string(l:root) != "0"
    execute 'cd' l:root
  endif
endfunction

function! CDRoot()
  try
    let l:root = GetRoot()
  catch /.*/
    echo "Error getting root: " . v:exception
    return
  endtry
  try
    if string(l:root) != "0"
      execute 'cd' l:root
    endif
  catch /.*/
    echo "Error setting root: ". l:root . "Error: " . v:exception
    return
  endtry
  return 0
endfunction

function! GetRoot()
  if !exists("g:TreeOriginalRoot")
    let l:curFile = GetCurFile()

    let l:root = GetSessionRoot(l:curFile)

    if ! l:root
      let l:root = GetGitRoot(l:curFile)
      if l:root 
        return l:root
      endif
    endif

    return 0
  else
    return g:TreeOriginalRoot
  endif
endfunction

function! s:getRoot(path, suffix)
  if a:path == '/' || a:path == '' || a:path == '.'
    return 0
  endif

  let l:files = split(globpath(a:path, a:suffix), '\n')
  if len(l:files) > 0
    return a:path
  endif
 return s:getRoot(fnamemodify(a:path, ':h'), a:suffix)
endfunction

function! GetSessionRoot(path)
  return s:getRoot(a:path, "Session.vim")
endfunction

function! GetGitRoot(path)
  return s:getRoot(a:path, ".git/")
endfunction

let s:files = split(globpath(getcwd(), "Session.vim"), '\n')
if len(s:files) > 0
  let g:TreeOriginalRoot = getcwd()
endif

function! ExploreSessionRoot()
  let l:root = GetRoot()
  if string(l:root) != "0"
    execute 'Explore' l:root
  endif
endfunction

function! ExploreGitRoot()
  try
    let l:root = GetGitRoot(GetCurFile())
  catch /.*/
    echo "Error getting root: " . v:exception
    return
  endtry
  if string(l:root) != "0"
    execute 'Explore' l:root
  endif
endfunction

function! ScratchBuffer()
    vsplit
    noswapfile hide enew
    setlocal buftype=nofile
    setlocal bufhidden=hide
    "setlocal nobuflisted
    "file scratch
endfunction

function! CheatSheet()
  let old_reg = getreg("a")          " save the current content of register a
  let old_reg_type = getregtype("a") " save the type of the register as well
  try
    let @b = join(readfile($HOME . "/.vim/doc/cheatsheet.txt"), "\n")
    let @b .= "\n\n\n KeyMaps:\n=========\n"
    redir @a                           " redirect output to register a
    " Get the list of all key mappings silently, satisfy "Press ENTER to continue"
    silent map | call feedkeys("\<CR>")
    redir END                          " end output redirection
    call ScratchBuffer()               " new buffer in window
    put b
    put a                              " put content of register
    normal gg
  finally                              " Execute even if exception is raised
    call setreg("a", old_reg, old_reg_type) " restore register a
  endtry
endfunction

com! Cht call CheatSheet()      " Enable :CheatSheet to call the function

function! DiffSelectionWithClipboard() range
    let l:selection = getline(a:firstline-1, a:lastline)
    tabnew
    setlocal bufhidden=wipe buftype=nofile nobuflisted noswapfile
    :file clipboard
    :1put *
    silent 0d_
    diffthis
    vertical new
    setlocal bufhidden=wipe buftype=nofile nobuflisted noswapfile
    :file selection
    call setline(1, l:selection)
    silent 0d_
    diffthis
endfunction

" Map the function to a key combination, for example <leader>d
xnoremap <M-d> :<C-u>'<,'>call DiffSelectionWithClipboard()<CR>

function! YankLineInfo()
    let l:filepath = expand("%:p")
    let l:linenr = line(".")
    let l:linecontent = getline(".")
    let l:clipboard_content = printf("%s:%d: %s", l:filepath, l:linenr, l:linecontent)
    call setreg('+', l:clipboard_content)
endfunction

nnoremap <leader>yl :call YankLineInfo()<CR>
" ==========================================================
" Display and Themes
" ==========================================================

if has("gui_running")
   set guifont=Hack\ Regular\ Nerd\ Font\ Complete\ Mono
else
   set t_Co=256
endif

if (has("nvim"))
  "For Neovim 0.1.3 and 0.1.4 < https://github.com/neovim/neovim/pull/2198 >
  let $NVIM_TUI_ENABLE_TRUE_COLOR=1
else
  let g:firenvim_loaded = 1 "Firenvim doesn't work with vim
endif

" Enable true color
if exists('+termguicolors')
  set termguicolors
endif

" Cursor vert bar in insert mode
let &t_SI = "\e[6 q"
let &t_EI = "\e[2 q"
augroup visuals
  au!
  autocmd VimEnter * silent !echo -ne "\e[2 q"
augroup END

" Theme {{{
  colorscheme molokai
  let g:molokai_override_bg = 0
  let g:molokai_original = 0

  " Set highlight type
  hi clear SpellRare
  hi SpellRare gui=undercurl guisp=yellow
  hi clear SpellBad
  hi SpellBad gui=undercurl guisp=red
  hi clear CocWarningHighlight
  hi CocWarningHighlight ctermfg=yellow guifg=#c4ab39 gui=undercurl term=undercurl
  hi clear CocErrorHighlight
  hi CocErrorHighlight gui=undercurl guisp=red

" }}}
