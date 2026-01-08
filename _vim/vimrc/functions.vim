" ==========================================================
" Functions (Vim/GVim/Neovim compatible)
" ==========================================================

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

function! EqualizeWindows()
  let l:saved_fix = s:DisableWinFix()
  execute "normal! \<C-w>="
  call s:RestoreWinFix(l:saved_fix)
endfunction

" Notify terminal windows of resize (nvim-specific parts handled gracefully)
function! s:RefreshTerminals()
  let l:curwin = win_getid()
  for winnr in range(1, winnr('$'))
    let bufnr = winbufnr(winnr)
    if getbufvar(bufnr, '&buftype') == 'terminal'
      call win_gotoid(win_getid(winnr))
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

function! s:RestoreWindowSizes(saved)
  if s:WindowConfigChanged(a:saved)
    execute "normal! \<C-w>="
    return
  endif
  let l:curwin = win_getid()
  for winnr in range(1, winnr('$'))
    let winid = win_getid(winnr)
    if has_key(a:saved, winid)
      call win_gotoid(winid)
      let l:height = max([1, float2nr(a:saved[winid]['height'])])
      let l:width = max([1, float2nr(a:saved[winid]['width'])])
      execute 'resize ' . l:height
      execute 'vertical resize ' . l:width
    endif
  endfor
  call win_gotoid(l:curwin)
endfunction

function! ToggleSplitFullscreen()
  let l:saved_fix = s:DisableWinFix()

  if g:fullscreen_window == win_getid()
    let l:saved_sizes = g:fullscreen_saved_sizes
    let g:fullscreen_window = 0
    let g:fullscreen_saved_sizes = {}
    call s:RestoreWindowSizes(l:saved_sizes)
  elseif g:fullscreen_window != 0
    execute "normal! \<C-w>_\<C-w>|"
    let g:fullscreen_window = win_getid()
  else
    let g:fullscreen_saved_sizes = s:SaveWindowSizes()
    execute "normal! \<C-w>_\<C-w>|"
    let g:fullscreen_window = win_getid()
  endif

  call s:RestoreWinFix(l:saved_fix)
  call s:RefreshTerminals()
endfunction

function! s:AutoFullscreenOnFocus()
  if mode() == 't'
    return
  endif
  if g:fullscreen_window != 0 && g:fullscreen_window != win_getid()
    call ToggleSplitFullscreen()
  endif
endfunction

augroup fullscreen_auto
  autocmd!
  autocmd WinEnter * call s:AutoFullscreenOnFocus()
  autocmd WinNew * call s:ExitFullscreenOnNewWindow()
augroup END

function! s:ExitFullscreenOnNewWindow()
  if mode() == 't'
    return
  endif
  if g:fullscreen_window != 0
    let l:saved_sizes = g:fullscreen_saved_sizes
    let g:fullscreen_window = 0
    let g:fullscreen_saved_sizes = {}
    call s:RestoreWindowSizes(l:saved_sizes)
  endif
endfunction

function! ResizeWindow(dir)
  let l:saved_fix = s:DisableWinFix()
  let l:is_top = winnr() == winnr('k')
  let l:is_left = winnr() == winnr('h')
  if a:dir == 'up'
    execute 'resize ' . (l:is_top ? '-2' : '+2')
  elseif a:dir == 'down'
    execute 'resize ' . (l:is_top ? '+2' : '-2')
  elseif a:dir == 'left'
    execute 'vertical resize ' . (l:is_left ? '-2' : '+2')
  elseif a:dir == 'right'
    execute 'vertical resize ' . (l:is_left ? '+2' : '-2')
  endif
  call s:RestoreWinFix(l:saved_fix)
endfunction

function! CreateRegionFold() range
  let firstline = getline(a:firstline)
  let indent = matchstr(firstline, '^\s*')
  let comment_text = substitute(firstline, '^\s*//\s*', '', '')
  let comment_text = substitute(comment_text, '^\s*/\*\s*', '', '')
  let comment_text = substitute(comment_text, '\s*\*/\s*$', '', '')
  let comment_text = substitute(comment_text, '^\s*#\s*', '', '')
  call setline(a:firstline, indent . '// #region ' . comment_text)
  call append(a:lastline, indent . '// #endregion')
endfunction
command! -range CreateRegion <line1>,<line2>call CreateRegionFold()

function! WipeoutBuffers()
  let l:buffers = range(1, bufnr('$'))
  let l:currentTab = tabpagenr()
  try
    let l:tab = 0
    while l:tab < tabpagenr('$')
      let l:tab += 1
      let l:win = 0
      while l:win < winnr('$')
        let l:win += 1
        let l:thisbuf = winbufnr(l:win)
        call remove(l:buffers, index(l:buffers, l:thisbuf))
      endwhile
    endwhile
    if len(l:buffers)
      execute 'bwipeout' join(l:buffers)
    endif
  finally
    execute 'tabnext' l:currentTab
  endtry
endfunction

function! SplitScroll()
    :wincmd v
    :wincmd w
    execute "normal! \<C-d>"
    :set scrollbind
    :wincmd w
    :set scrollbind
endfunction

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
endfunction

function! CheatSheet()
  let old_reg = getreg("a")
  let old_reg_type = getregtype("a")
  try
    let @b = join(readfile($HOME . "/.vim/doc/cheatsheet.txt"), "\n")
    let @b .= "\n\n\n KeyMaps:\n=========\n"
    redir @a
    silent map | call feedkeys("\<CR>")
    redir END
    call ScratchBuffer()
    put b
    put a
    normal gg
  finally
    call setreg("a", old_reg, old_reg_type)
  endtry
endfunction

com! Cht call CheatSheet()

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

function! YankLineInfo()
    let l:filepath = expand("%:p")
    let l:linenr = line(".")
    let l:linecontent = getline(".")
    let l:clipboard_content = printf("%s:%d: %s", l:filepath, l:linenr, l:linecontent)
    call setreg('+', l:clipboard_content)
endfunction
