let NERDTreeShowBookmarks=1
let NERDTreeQuitOnOpen=1
let NERDTreeMouseMode=2
let NERDTreeChDirMode=2
let NERDTreeAutoDeleteBuffer = 1
let NERDTreeShowHidden=1
let NERDTreeMinimalUI = 1
let NERDTreeDirArrows = 1
let NERDTreeIgnore=['\.pyc','\~$','\.swo$','\.swp$','\.git','\.hg','\.svn','\.bzr']
let NERDTreeKeepTreeInNewTab=1
let g:nerdtree_tabs_open_on_gui_startup=0

nnoremap <C-e> :NERDTreeToggle<CR>
map <leader>n :NERDTreeToggle<CR>
map - :NERDTree %<CR>
map ~ :call NERDTreeSessionRoot()<CR>

function! NERDTreeSessionRoot()
  let l:curFile = expand('%:p')
  if l:curFile == ""
    let l:curFile = getcwd()
  endif

  let l:root = GetSessionRoot(l:curFile)
  if ! l:root
    let l:root = GetGitRoot(l:curFile)
  endif
  if string(l:root) != "0"
    execute 'NERDTree' l:root
  endif
endfunction

function! GetRoot(path, suffix)
  if a:path == '/'
    return 0
  endif

  let l:files = split(globpath(a:path, a:suffix), '\n')
  if len(l:files) > 0
    return a:path
  endif
 return GetRoot(fnamemodify(a:path, ':h'), a:suffix)
endfunction

function! GetSessionRoot(path)
  return GetRoot(a:path, "Session.vim")
endfunction

function! GetGitRoot(path)
  return GetRoot(a:path, ".git/")
endfunction

