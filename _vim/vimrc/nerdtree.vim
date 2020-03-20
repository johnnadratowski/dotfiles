let NERDTreeShowBookmarks=1
let NERDTreeQuitOnOpen=1
let NERDTreeMouseMode=2
let NERDTreeAutoDeleteBuffer = 1
let NERDTreeShowHidden=1
let NERDTreeMinimalUI = 1
let NERDTreeDirArrows = 1
let NERDTreeIgnore=['\.pyc','\~$','\.swo$','\.swp$','\.git','\.hg','\.svn','\.bzr']
let NERDTreeKeepTreeInNewTab=1
let g:nerdtree_tabs_open_on_gui_startup=0

map <leader>n :NERDTreeToggle<CR>
map - :NERDTree %<CR>
map ~ :call NERDTreeSessionRoot()<CR>

function! NERDTreeSessionRoot()
  let l:curFile = expand('%:p')
  if l:curFile == ""
    let l:curFile = getcwd()
  endif

  let l:root = GetSessionRoot(l:curFile)
  execute 'NERDTree' l:root
endfunction

function! GetSessionRoot(path)
  if a:path == '/'
    return 0
  endif

  let l:files = split(globpath(a:path, '*'), '\n')
  call filter(l:files, { idx, val -> val ==? a:path . "/Session.vim" })
  if len(l:files) > 0
    return a:path
  endif
 return GetSessionRoot(fnamemodify(a:path, ':h'))
endfunction

