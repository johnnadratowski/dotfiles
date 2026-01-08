" ==========================================================
" Keymaps (Vim/GVim/Neovim compatible)
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

" Equalize windows (handles winfixwidth/height)
nnoremap <C-w>= :call EqualizeWindows()<CR>
map <leader>= :call EqualizeWindows()<CR>

" Toggle fullscreen for current split
nnoremap <C-space> :call ToggleSplitFullscreen()<CR>

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
nnoremap <A-Up> :call ResizeWindow('up')<CR>
nnoremap <A-Down> :call ResizeWindow('down')<CR>
nnoremap <A-Left> :call ResizeWindow('left')<CR>
nnoremap <A-Right> :call ResizeWindow('right')<CR>

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

" Diff selection with clipboard
xnoremap <M-d> :<C-u>'<,'>call DiffSelectionWithClipboard()<CR>

" Yank line info (filepath:line: content)
nnoremap <leader>yl :call YankLineInfo()<CR>
