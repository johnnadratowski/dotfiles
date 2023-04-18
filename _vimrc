" ==========================================================
" Plugins
" ==========================================================

call plug#begin()

Plug 'antoinemadec/coc-fzf', {'branch': 'release'}
Plug 'AndrewRadev/sideways.vim'
Plug 'airblade/vim-gitgutter'
Plug 'chrisbra/NrrwRgn'
Plug 'christoomey/vim-tmux-navigator'
Plug 'dbeniamine/cheat.sh-vim'
Plug 'editorconfig/editorconfig-vim'
Plug 'fatih/vim-go'
Plug 'frazrepo/vim-rainbow'
Plug 'glacambre/firenvim'
Plug 'iloginow/vim-stylus'
Plug 'itchyny/landscape.vim'
Plug 'itchyny/lightline.vim'
Plug 'itchyny/vim-gitbranch'
Plug 'johnnadratowski/molokai'
Plug 'johnnadratowski/vim-pug'
Plug 'junegunn/fzf', {'dir': '~/.fzf','do': './install --all'}
Plug 'junegunn/fzf.vim' " needed for previews
Plug 'junegunn/goyo.vim' 
Plug 'junegunn/limelight.vim'
Plug 'junegunn/vim-easy-align'
Plug 'junegunn/vim-peekaboo'
Plug 'kristijanhusak/vim-dadbod-ui'
Plug 'leafgarland/typescript-vim'
Plug 'leafOfTree/vim-vue-plugin'
Plug 'maxbrunsfeld/vim-emacs-bindings'
Plug 'mbbill/undotree'
Plug 'mhinz/vim-startify'
Plug 'neoclide/coc.nvim', {'branch': 'release'}
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
Plug 'ryanoasis/vim-devicons'
Plug 'sebdah/vim-delve'
Plug 'sheerun/vim-wombat-scheme'
Plug 'stephpy/vim-yaml'
Plug 'thaerkh/vim-indentguides'
Plug 'thaerkh/vim-workspace'
Plug 'tmhedberg/matchit'
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
Plug 'yggdroot/LeaderF', { 'do': ':LeaderfInstallCExtension' }

call plug#end()

let g:coc_global_extensions = [ 
      \ 'coc-css', 
      \ 'coc-db',
      \ 'coc-dictionary',
      \ 'coc-emoji', 
      \ 'coc-eslint', 
      \ 'coc-go', 
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

set nocompatible              " Don't be compatible with vi
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
set foldmethod=indent       " allow us to fold on indents
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
set ls=2                    " allways show status line
set matchpairs+=<:>         " show matching <> (html mainly) as well
set modeline                " Allow vim options to be embedded in files;
set modelines=5             " they must be within the first or last 5 lines.
set mouse=a                 " Allow mouse
set mousehide               " Hid emouse when typing
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
nmap <c-s> :w<CR>

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

" Close Window
map <leader>x :bp \| bd #<CR>
map <leader>w :clo<CR>

" hide matches on <leader>space
nnoremap <leader><space> :nohlsearch<cr>

" Toggle word wrap
noremap <silent> <leader>W :call ToggleWrap()<CR>

" Close all non-buffer windows
nnoremap <silent> <Plug>(close-side-windows) :cclo <bar> :VimuxCloseRunner<CR>
nmap <C-m> <Plug>(close-side-windows)

" Quit window
nnoremap <C-q> :execute "normal \<Plug>(close-side-windows)" <bar> :qa<CR>

" Reload Vimrc
map <silent> <leader>V :source ~/.vimrc<CR>:exe ":echo 'vimrc reloaded'"<CR>
augroup myvimrc
  au!
  au BufWritePost .vimrc,_vimrc,vimrc,*/_vim/*,*/.vim/*.gvimrc,_gvimrc,gvimrc so $MYVIMRC | if has('gui_running') | so $MYGVIMRC | endif | echo "vimrc reloaded"
augroup END

" Stay in visual selection mode when changing indent
vnoremap < <gv
vnoremap > >gv

" ==========================================================
" Plugin Settings + Keymaps
" ==========================================================

" Pug {{{
augroup pug
  au!
  " Horrible hack to get pug files to display syntax highlighting.  Need to
  " redetect file but after reload, or all highlighting doesn't work.
  au BufNewFile,BufRead,BufReadPost,BufEnter *.pug call timer_start(20, { tid -> execute('filetype detect')})
augroup END
" }}}

" JSON {{{
  " Disable quote concealing in JSON files
  let g:vim_json_conceal=0
" }}}

" DBUI {{{
  nmap <leader>d :DBUIToggle<CR>
  autocmd filetype sql nnoremap <buffer> <Enter> :DB<CR>
  autocmd filetype dbui nnoremap <buffer> <c-k> :TmuxNavigateUp<CR>
  autocmd filetype dbui nnoremap <buffer> <c-j> :TmuxNavigateDown<CR>

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
  map <c-e> :call ExploreSessionRoot()<CR>
  map _ :call ExploreGitRoot()<CR>

  augroup netrw
    autocmd!
    autocmd filetype netrw call NetrwMapping()
    autocmd filetype netrw setl bufhidden=wipe " delete netrw buffer when hidden
  augroup END

  function! NetrwMapping()
      nnoremap <buffer> <c-l> :TmuxNavigateRight<CR>
      nmap <buffer> <C-[> :bn<CR>
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

    " toggle goyo
    nmap <leader>G :Goyo<CR>

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

  function! s:goyo_enter()
    if executable('tmux') && strlen($TMUX)
      silent !tmux set status off
      silent !tmux list-panes -F '\#F' | grep -q Z || tmux resize-pane -Z
    endif
    set noshowmode
    set noshowcmd
    setlocal showbreak=NONE
    set scrolloff=999
    Limelight
    " ...
  endfunction

  function! s:goyo_leave()
    if executable('tmux') && strlen($TMUX)
      silent !tmux set status on
      silent !tmux list-panes -F '\#F' | grep -q Z && tmux resize-pane -Z
    endif
    set scrolloff=5
    set showmode
    set showcmd
    setlocal showbreak=➡\
    Limelight!
  endfunction

  autocmd Filetype markdown,mkd,md,text call SetMDOptions()
  autocmd! User GoyoEnter nested call <SID>goyo_enter()
  autocmd! User GoyoLeave nested call <SID>goyo_leave()

" }}}

" stylus {{{

  autocmd FileType stylus setlocal commentstring=//\ %s

" }}}

" typescript {{{

  autocmd FileType typescript setlocal re=2
  autocmd FileType vue setlocal re=2

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

  " augroup golang_test
  "   au BufWritePost *.spec.*,*_test.go :let test#project_root=GetGitRoot(expand('%')) | TestNearest
  "   au BufEnter,BufLeave *.spec.*,*_test.go :let test#project_root=GetGitRoot(expand('%')) | TestFile
  " augroup END

" }}}


" rainbow parens
let g:rainbow_active = 1

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

" vim-lightline
let g:lightline = {
      \ 'colorscheme': 'one',
      \ 'active': {
      \   'left': [ [ 'mode', 'paste' ],
      \             [ 'gitroot', 'gitbranch', 'gitstatus', 'readonly', 'filename', 'modified' ] ]
      \ },
      \ 'component_function': {
      \   'gitbranch': 'gitbranch#name',
      \   'gitstatus': 'GitStatus',
      \   'gitroot': 'RootName'
      \ },
      \ }

" Renamer
source ~/.vim/vimrc/renamer.vim

" vim-startify
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
    autocmd FileType vim setlocal commentstring=\"\ %s
    autocmd FileType vimrc setlocal commentstring=\"\ %s
    autocmd FileType vue setlocal commentstring=//\ %s
  augroup END

" }}}

" vim-workspace {{{
  nnoremap <leader>` :ToggleWorkspace<CR>
  let g:workspace_autosave = 0

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
  map <leader>g :UndotreeToggle<CR>

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
    inoremap <buffer> <silent> k   <C-o>gk
    inoremap <buffer> <silent> j <C-o>gj
    inoremap <buffer> <silent> <Home> <C-o>g<Home>
    inoremap <buffer> <silent> <End>  <C-o>g<End>
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



" ==========================================================
" Display and Themes
" ==========================================================

if has("gui_running")
   "set guifont=Roboto\ Mono\ Light\ for\ Powerline
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
  " let &t_8f = "\<Esc>[38;2;%lu;%lu;%lum"
  " let &t_8b = "\<Esc>[48;2;%lu;%lu;%lum"
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
  "autocmd vimenter * ++nested colorscheme molokai
  
  " Set highlight type
  if has("gui_running")
    hi clear SpellRare
    hi SpellRare gui=undercurl guisp=yellow
    hi clear SpellBad
    hi SpellBad gui=undercurl guisp=red
    hi clear CocWarningHighlight
    hi CocWarningHighlight ctermfg=yellow guifg=#c4ab39 gui=undercurl term=undercurl
    hi clear CocErrorHighlight
    hi CocErrorHighlight gui=undercurl guisp=red 
  else
    hi clear SpellRare
    hi SpellRare gui=undercurl guisp=yellow
    hi clear SpellBad
    hi SpellBad gui=undercurl guisp=red
    hi clear CocWarningHighlight
    hi CocWarningHighlight ctermfg=yellow guifg=#c4ab39 gui=undercurl term=undercurl
    hi clear CocErrorHighlight
    hi CocErrorHighlight gui=undercurl guisp=red 
  endif

" }}}

