" ==========================================================
" Display and Themes (Vim/GVim/Neovim compatible)
" ==========================================================

if has("gui_running")
   set guifont=Hack\ Regular\ Nerd\ Font\ Complete\ Mono:h14
else
   set t_Co=256
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

" Theme
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
