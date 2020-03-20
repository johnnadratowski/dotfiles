" ==========================================================
" Basic Settings
" ==========================================================

set nocompatible              " Don't be compatible with vi
let mapleader=" "             " Map leader key to space

syntax on                     " syntax highlighing
filetype on                   " try to detect filetypes
filetype plugin indent on     " enable loading indent file for filetype

set autoread                " Automatically reload files changes outside vim
set autoindent                " same indentation as previous line
set backspace=indent,eol,start  "Allow backspace in insert mode
set background=dark           " We are using dark background in vim
set clipboard=unnamed        " Use system clipboard
set colorcolumn=80          " The right hand gutter
set confirm                 " Y-N-C prompt if closing with unsaved changes.
set cursorline              " have a line indicate the cursor location
set expandtab               " Use spaces, not tabs, for autoindent/tab key.
set ffs=unix,dos,mac        " Try recognizing dos, unix, and mac line endings.
set foldlevel=99            " don't fold by default
set foldmethod=indent       " allow us to fold on indents
set grepprg=ag              " replace the default grep program with ag
set history=1000            " Command history
set hlsearch                " Highlight searches by default.
set ignorecase              " Default to using case insensitive searches,
set laststatus=2            " Always show statusline, even if only 1 window.
set linebreak               " don't wrap textin the middle of a word
set list
set ls=2                    " allways show status line
set matchpairs+=<:>         " show matching <> (html mainly) as well
set modeline                " Allow vim options to be embedded in files;
set modelines=5             " they must be within the first or last 5 lines.
set mouse=a                 " Allow mouse
set mousehide               " Hid emouse when typing
set nobackup                " No backup file
set noerrorbells            " No bell on error
set nostartofline           " Avoid moving cursor to BOL when jumping around
set noswapfile              " No swap file
set nowrap                  " No text wrapping by default
set nowb                      " Make a write backup for write errors
set number                  " Show line numbers
set report=0                " : commands always print changed line count.
set shiftround              " rounds indent to a multiple of shiftwidth
set shiftwidth=2            " but an indent level is 2 spaces wide.
set shortmess+=a            " Use [+]/[RO]/[w] for modified/readonly/written.
set showcmd                 " Show incomplete normal mode commands as I type.
set showmode                " Show the current mode down below
set showmatch               " Briefly jump to a paren once it's balanced
set smartcase               " unless uppercase letters are used in the regex.
set smarttab               " unless uppercase letters are used in the regex.
set smartindent             " use smart indent if there is no indent file
set softtabstop=2           " <BS> over an autoindent deletes both spaces.
set tabstop=2               " <tab> inserts 2 spaces
set visualbell              " Allow visual bells
set virtualedit=block       " Let cursor move past the last char in <C-v> mode
set wildignore+=*.egg-info/**,eggs/**    " Ignore python egg folders
set wildignore+=*.o,*.obj,.git,*.pyc     " Ignore python, object, git files
set wildignore+=*/node_modules/**        " Ignore node modules
set wildignore+=*/tmp/*,*.so,*.swp,*.zip " Ignore temp, so, swap, and zip
set wildignore+=*/vendor/**              " Ignore vendor sources
set wildmode=full             " <Tab> cycles between all matching choices.

"""" Display

colorscheme molokai

if has("gui_running")
    set guifont=Roboto\ Mono\ Light\ for\ Powerline
    "colorscheme desert
    " Remove menu bar
    "set guioptions-=m

    " Remove toolbar
    " set guioptions-=T
endif

"""" Persistent Undo
" Keep undo history across sessions, by storing in file.
" Only works all the time.
if has('persistent_undo')
  silent !mkdir -p ~/tmp/backups > /dev/null 2>&1
  set undodir=~/tmp/backups
  set undofile
endif

" Enable true color
if exists('+termguicolors')
  let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
  let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
  set termguicolors
endif



" ==========================================================
" Plugin Settings + Keymaps
" ==========================================================


""" vim-commentary
autocmd FileType vim setlocal commentstring=\"\ %s
autocmd FileType vimrc setlocal commentstring=\"\ %s
autocmd FileType vue setlocal commentstring=//\ %s

""" vim-workspace
nnoremap <leader>` :ToggleWorkspace<CR>

""" CoC

source ~/.vim/vimrc/coc.vim


""" NERDTree

source ~/.vim/vimrc/nerdtree.vim


""" Leaderf
let g:Lf_FollowLinks = 1
let g:Lf_PreviewInPopup = 1
map <leader>f :Leaderf file --popup<CR>


""" Search

"Search for the word under cursor
nnoremap <Leader>s :Ags<Space><C-R>=expand('<cword>')<CR><CR>
" Search for the visually selected text
vnoremap <Leader>s y:Ags<Space><C-R>='"' . escape(@", '"*?()[]{}.') . '"'<CR><CR>
" Run Ags
nnoremap <Leader>a :Ags<Space>
" Quit Ags
nnoremap <Leader><Leader>a :AgsQuit<CR>



""" Undotree

map <leader>g :UndotreeToggle<CR>




" ==========================================================
" Language Settings
" ==========================================================


" Vim





" ==========================================================
" Keymaps
" ==========================================================

nmap <leader>bd :call WipeoutBuffers()<CR>

nmap <leader>sb :call SplitScroll()<CR>


" Edit VimRC
map <silent> <leader>v :e ~/.vimrc<CR>

" Reload Vimrc
map <silent> <leader>V :source ~/.vimrc<CR>:filetype detect<CR>:exe ":echo 'vimrc reloaded'"<CR>

" open/close the quickfix window
nmap <leader>c :copen<CR>
nmap <leader>C :cclose<CR>

" for when we forget to use sudo to open/edit a file
cmap w!! w !sudo tee % >/dev/null
cmap W! w !sudo tee % >/dev/null

" Window Maps
map <leader>j <c-w>j
map <leader>k <c-w>k
map <leader>h <c-w>h
map <leader>l <c-w>l

map <leader>J <c-w>J
map <leader>K <c-w>K
map <leader>H <c-w>H
map <leader>L <c-w>L

" Maximize/minimize
map <leader>^ <c-w>_<c-w>\|
map <leader>= <c-w>=

map <leader>- <c-w>s
map <leader>\| <c-w>v

map <leader>x :bd<CR>
map <leader>w :clo<CR>

" Paste/copy from/to system clipboard
map <leader>p "+p
map <leader>y "+y

" Quit window on <leader>q
nnoremap <leader>q :q<CR>
nnoremap <leader>Q :qa<CR>

" hide matches on <leader>space
nnoremap <leader><space> :nohlsearch<cr>

" Remove trailing whitespace on <leader>S
nnoremap <leader>S :%s/\s\+$//<cr>:let @/=''<CR>

" Set working directory
nnoremap <leader>. :lcd %:p:h<CR>

noremap <silent> <Leader>W :call ToggleWrap()<CR>








" ==========================================================
" Functions
" ==========================================================

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

function ToggleWrap()
  if &wrap
    echo "Wrap OFF"
    setlocal nowrap
    set virtualedit=all
    silent! nunmap <buffer> <Up>
    silent! nunmap <buffer> <Down>
    silent! nunmap <buffer> <Home>
    silent! nunmap <buffer> <End>
    silent! iunmap <buffer> <Up>
    silent! iunmap <buffer> <Down>
    silent! iunmap <buffer> <Home>
    silent! iunmap <buffer> <End>
  else
    echo "Wrap ON"
    setlocal wrap linebreak nolist
    set virtualedit=
    setlocal display+=lastline
    noremap  <buffer> <silent> <Up>   gk
    noremap  <buffer> <silent> <Down> gj
    noremap  <buffer> <silent> <Home> g<Home>
    noremap  <buffer> <silent> <End>  g<End>
    inoremap <buffer> <silent> <Up>   <C-o>gk
    inoremap <buffer> <silent> <Down> <C-o>gj
    inoremap <buffer> <silent> <Home> <C-o>g<Home>
    inoremap <buffer> <silent> <End>  <C-o>g<End>
  endif
endfunction
