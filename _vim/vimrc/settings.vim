" ==========================================================
" Basic Settings (Vim/GVim/Neovim compatible)
" ==========================================================

" Allow control characters to pass to vim for shortcuts
silent !stty -ixon > /dev/null 2>/dev/null

let mapleader=" "             " Map leader key to space

set clipboard=unnamed       " Use system clipboard
set cmdheight=2             " Give more space for displaying messages.
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
set hidden                  " TextEdit might fail if hidden is not set.
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
set mousehide               " Hide mouse when typing
set autoread                " Auto-reload files changed outside vim
set nobackup                " No backup file
set noerrorbells            " No bell on error
set nofoldenable            " DO NOT enable folds by default
set noshowmode              " Do not show the current mode, as we use lightline
set nostartofline           " Avoid moving cursor to BOL when jumping around
set noswapfile              " No swap file
set nowb                    " Make a write backup for write errors
set nowrap                  " No text wrapping by default
set nowritebackup           " some servers might have problems with backup
set number                  " Show line numbers
set report=0                " : commands always print changed line count.
set scrolloff=5             " Number of lines to show above/below cursor
set shiftround              " rounds indent to a multiple of shiftwidth
set shiftwidth=2            " but an indent level is 2 spaces wide.
set shortmess+=a            " Use [+]/[RO]/[w] for modified/readonly/written.
set shortmess+=c            " Don't pass messages to |ins-completion-menu|.
set showbreak=➡\            " Character to show at word wrap
set showcmd                 " Show incomplete normal mode commands as I type.
set showmatch               " Briefly jump to a paren once it's balanced
set signcolumn=yes          " Always show the signcolumn
set smartcase               " unless uppercase letters are used in the regex.
set smartindent             " use smart indent if there is no indent file
set softtabstop=2           " <BS> over an autoindent deletes both spaces.
set tabstop=2               " <tab> inserts 2 spaces
set updatetime=300          " user experience
set virtualedit=block       " Let cursor move past the last char in <C-v> mode
set visualbell              " Allow visual bells
set wildignore+=*.egg-info/**,eggs/**    " Ignore python egg folders
set wildignore+=*.o,*.obj,.git,*.pyc     " Ignore python, object, git files
set wildignore+=*/node_modules/**        " Ignore node modules
set wildignore+=*/tmp/*,*.so,*.swp,*.zip " Ignore temp, so, swap, and zip
set wildignore+=*/vendor/**              " Ignore vendor sources
set wildmode=longest,list,full           " <Tab> cycles between all matching choices.
