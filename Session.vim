let SessionLoad = 1
if &cp | set nocp | endif
let s:so_save = &so | let s:siso_save = &siso | set so=0 siso=0
let v:this_session=expand("<sfile>:p")
silent only
silent tabonly
cd ~/go/src/github.com/Unified/dotfiles
if expand('%') == '' && !&modified && line('$') <= 1 && getline(1) == ''
  let s:wipebuf = bufnr('%')
endif
set shortmess=aoO
argglobal
%argdel
edit _vim/pack/john/start/NrrwRgn/post.pl
set splitbelow splitright
wincmd _ | wincmd |
split
1wincmd k
wincmd w
set nosplitbelow
set nosplitright
wincmd t
set winminheight=0
set winheight=1
set winminwidth=0
set winwidth=1
exe '1resize ' . ((&lines * 24 + 25) / 51)
exe '2resize ' . ((&lines * 23 + 25) / 51)
argglobal
setlocal fdm=indent
setlocal fde=0
setlocal fmr={{{,}}}
setlocal fdi=#
setlocal fdl=99
setlocal fml=1
setlocal fdn=20
setlocal fen
let s:l = 7 - ((6 * winheight(0) + 12) / 24)
if s:l < 1 | let s:l = 1 | endif
exe s:l
normal! zt
7
normal! 0
wincmd w
argglobal
enew
file _vim/pack/john/start/NrrwRgn/NrrwRgn.vmb
setlocal fdm=marker
setlocal fde=0
setlocal fmr=[[[,]]]
setlocal fdi=#
setlocal fdl=0
setlocal fml=1
setlocal fdn=20
setlocal fen
wincmd w
2wincmd w
exe '1resize ' . ((&lines * 24 + 25) / 51)
exe '2resize ' . ((&lines * 23 + 25) / 51)
tabnext 1
badd +365 _vimrc
badd +12 _vim/vimrc/leaderf.vim
badd +1 _vim/pack/john/start/vim-vue/test/vimrc
badd +52 _hammerspoon/window.lua
badd +26 _hammerspoon/init.lua
badd +1 _hammerspoon/browser.lua
badd +22 _hammerspoon/applications.lua
badd +3 _hammerspoon/timestamp.lua
badd +126 _hammerspoon/snippets.lua
badd +5 _hammerspoon/anycomplete.lua
badd +1 _zshrc
badd +542 _vim/pack/john/start/NrrwRgn/NrrwRgn.vmb
badd +20 _vim/pack/john/start/NrrwRgn/autoload/nrrwrgn.vim
badd +69 _vim/pack/john/start/NrrwRgn/plugin/NrrwRgn.vim
badd +7 _vim/pack/john/start/NrrwRgn/post.pl
if exists('s:wipebuf') && len(win_findbuf(s:wipebuf)) == 0
  silent exe 'bwipe ' . s:wipebuf
endif
unlet! s:wipebuf
set winheight=1 winwidth=20 shortmess=filnxtToOSac
set winminheight=1 winminwidth=1
let s:sx = expand("<sfile>:p:r")."x.vim"
if file_readable(s:sx)
  exe "source " . fnameescape(s:sx)
endif
let &so = s:so_save | let &siso = s:siso_save
doautoall SessionLoadPost
unlet SessionLoad
" vim: set ft=vim :
