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

map <leader>T :tabnew<CR>
map <leader>W :tabclose<CR>

map <leader>x :clo<CR>
map <leader>w :bd<CR>

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




" ==========================================================
" Basic Settings
" ==========================================================

set nocompatible              " Don't be compatible with vi
let mapleader=","             " change the leader to be a comma vs slash

syntax on                     " syntax highlighing
filetype on                   " try to detect filetypes
filetype plugin indent on     " enable loading indent file for filetype

set background=dark           " We are using dark background in vim
set wildmode=full             " <Tab> cycles between all matching choices.
set mouse=a
set mousehide
set clipboard=unnamed

" don't bell or blink
set noerrorbells
set vb t_vb=

" Ignore these files when completing
set wildignore+=*.o,*.obj,.git,*.pyc
set wildignore+=eggs/**
set wildignore+=*.egg-info/**

set grepprg=ag         " replace the default grep program with ag


""" Moving Around/Editing
set colorcolumn=100
set cursorline              " have a line indicate the cursor location
set nostartofline           " Avoid moving cursor to BOL when jumping around
set virtualedit=block       " Let cursor move past the last char in <C-v> mode
set showmatch               " Briefly jump to a paren once it's balanced
set wrap                    " don't wrap text
set linebreak               " don't wrap textin the middle of a word
set smartindent             " use smart indent if there is no indent file
set tabstop=4               " <tab> inserts 4 spaces
set shiftwidth=4            " but an indent level is 2 spaces wide.
set softtabstop=4           " <BS> over an autoindent deletes both spaces.
set expandtab               " Use spaces, not tabs, for autoindent/tab key.
set shiftround              " rounds indent to a multiple of shiftwidth
set matchpairs+=<:>         " show matching <> (html mainly) as well
set foldmethod=indent       " allow us to fold on indents
set foldlevel=99            " don't fold by default

"""" Reading/Writing
set modeline                " Allow vim options to be embedded in files;
set modelines=5             " they must be within the first or last 5 lines.
set ffs=unix,dos,mac        " Try recognizing dos, unix, and mac line endings.

"""" Messages, Info, Status
set ls=2                    " allways show status line
set vb t_vb=                " Disable all bells.  I hate ringing/flashing.
set confirm                 " Y-N-C prompt if closing with unsaved changes.
set showcmd                 " Show incomplete normal mode commands as I type.
set report=0                " : commands always print changed line count.
set shortmess+=a            " Use [+]/[RO]/[w] for modified/readonly/written.
set laststatus=2            " Always show statusline, even if only 1 window.

" displays tabs with :set list & displays when a line runs off-screen
set list

""" Searching and Patterns
set ignorecase              " Default to using case insensitive searches,
set smartcase               " unless uppercase letters are used in the regex.
set hlsearch                " Highlight searches by default.

"""" Display
if has("gui_running")
    colorscheme vividchalk
    set guifont=Inconsolata\ Bold\ 12
    "colorscheme desert
    " Remove menu bar
    "set guioptions-=m

    " Remove toolbar
    " set guioptions-=T
else
    colorscheme vividchalk
    set guifont=Inconsolata\ Bold\ 8
endif






" ==========================================================
" Language Settings
" ==========================================================

" Javascript
"autocmd BufNewFile,BufRead *.vue set filetype=vue








" ==========================================================
" Plugin Settings + Keymaps
" ==========================================================

""" NERDTree

let NERDTreeShowBookmarks=1
let NERDTreeChDirMode=0
let NERDTreeQuitOnOpen=1
let NERDTreeMouseMode=2
let NERDTreeShowHidden=1
let NERDTreeIgnore=['\.pyc','\~$','\.swo$','\.swp$','\.git','\.hg','\.svn','\.bzr']
let NERDTreeKeepTreeInNewTab=1
let g:nerdtree_tabs_open_on_gui_startup=0

map <leader>n :NERDTreeToggle<CR>

""" CommandT

map <leader>f :CtrlP<CR>

""" Searcoft/vim-ags.git
"Search for the word under cursor
nnoremap <Leader>s :Ags<Space><C-R>=expand('<cword>')<CR><CR>
" Search for the visually selected text
vnoremap <Leader>s y:Ags<Space><C-R>='"' . escape(@", '"*?()[]{}.') . '"'<CR><CR>
" Run Ags
nnoremap <Leader>a :Ags<Space>
" Quit Ags
nnoremap <Leader><Leader>a :AgsQuit<CR>



""" Gundo

map <leader>g :GundoToggle<CR>

