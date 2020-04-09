"""""""""""""""""
" Options
"""""""""""""""""
let NERDTreeShowBookmarks=1
let NERDTreeQuitOnOpen=1
let NERDTreeMouseMode=2
let NERDTreeChDirMode=2
let NERDTreeAutoDeleteBuffer = 1
let NERDTreeShowHidden=1
let NERDTreeMinimalUI = 1
let NERDTreeDirArrows = 1
let NERDTreeIgnore=['\.pyc','\~$','\.swo$','\.swp$','\.hg','\.svn','\.bzr']
let NERDTreeKeepTreeInNewTab=1
let g:nerdtree_tabs_open_on_gui_startup=0


"""""""""""""""""
" Key Maps
"""""""""""""""""
nnoremap <C-e> :NERDTreeToggle<CR>
map - :call DeselectNERDTree() <bar> :NERDTreeFind<CR>
map _ :call NERDTreeSessionRoot()<CR>

"""""""""""""""""
" Autocmds
"""""""""""""""""
" Auto open NERDTree on vim open
"autocmd vimenter * NERDTree

"Close vim if NERDTree is only window open
autocmd BufEnter * if (winnr("$") == 1 && exists("b:NERDTree") && b:NERDTree.isTabTree()) | q | endif

" If more than one window and previous buffer was NERDTree, go back to it.
autocmd BufEnter * if bufname('#') =~# "^NERD_tree_" && winnr('$') > 1 | b# | endif

" autocmd BufEnter * silent! if bufname('%') !~# 'NERD_tree_' | cd %:p:h | NERDTreeCWD | wincmd p | endif

"""""""""""""""""
" Functions
"""""""""""""""""
function! DeselectNERDTree() 
  if (expand('%') =~ 'NERD_tree') 
    wincmd w
  endif
endfunction

function! NERDTreeSessionRoot()
  let l:root = GetRoot()
  if string(l:root) != "0"
    execute 'NERDTree' l:root
  endif
endfunction

