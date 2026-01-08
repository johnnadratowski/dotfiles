" ==========================================================
" Plugin Settings (Vim/GVim/Neovim compatible)
" ==========================================================

" vim-ai {{{
  let g:gpt_api_key = $GPT_API_TOKEN
  inoremap <C-g> <Esc> :AIEdit
  vnoremap <C-g> :AIEdit
  noremap <C-g> :AIEdit

  vnoremap <leader>g :AI
  noremap <leader>g :AI
" }}}

" Pug {{{
  augroup pug
    au!
    au BufNewFile,BufRead,BufReadPost,BufEnter *.pug call timer_start(20, { tid -> execute('filetype detect')})
  augroup END
" }}}

" Less {{{
  augroup less
    au!
    au BufNewFile,BufRead,BufReadPost,BufEnter *.less call timer_start(20, { tid -> execute('filetype detect')})
  augroup END
" }}}

" JSON {{{
  let g:vim_json_conceal=0
" }}}

" DBUI {{{
  nmap <leader>d :DBUIToggle<CR>
  augroup dbui
    autocmd!
    autocmd filetype sql nnoremap <buffer> <Enter> :DB<CR>
    autocmd filetype dbui nnoremap <buffer> <c-k> :TmuxNavigateUp<CR>
    autocmd filetype dbui nnoremap <buffer> <c-j> :TmuxNavigateDown<CR>
  augroup END
" }}}

" Netrw {{{
  let g:netrw_localcopycmd='cp'
  map <c-e> :call ExploreSessionRoot()<CR>
  map _ :call ExploreGitRoot()<CR>

  augroup netrw
    autocmd!
    autocmd filetype netrw call NetrwMapping()
    autocmd filetype netrw setl bufhidden=wipe
  augroup END

  function! NetrwMapping()
    nnoremap <buffer> <c-l> :TmuxNavigateRight<CR>
    nmap <buffer> <C-[> :bn<CR>
    nnoremap <buffer> <silent> <Leader>d :call NetrwDuplicateFile()<CR>
  endfunction

  function! NetrwDuplicateFile()
    let l:curfile = netrw#Call("NetrwGetWord")
    if l:curfile == ''
      echo "No file under cursor"
      return
    endif
    let l:curdir = b:netrw_curdir
    let l:srcpath = l:curdir . '/' . l:curfile
    let l:ext = fnamemodify(l:curfile, ':e')
    let l:base = fnamemodify(l:curfile, ':r')
    if l:ext != ''
      let l:destfile = l:base . '-copy.' . l:ext
    else
      let l:destfile = l:curfile . '-copy'
    endif
    let l:destpath = l:curdir . '/' . l:destfile
    silent exec "!cp " . shellescape(l:srcpath) . " " . shellescape(l:destpath)
    redraw!
    echo "Copied " . l:curfile . " to " . l:destfile
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

  function! SetMDOptions()
    setlocal wrap
    setlocal noexpandtab
    setl spell spl=en_us fdl=4 noru nonu nornu
    setl fdo+=search

    let g:lexical#spell_key = '<leader>s'
    let g:lexical#dictionary_key = '<leader>k'
    let g:lexical#thesaurus_key = '<leader>t'

    let g:textobj#sentence#select = 's'
    let g:textobj#sentence#move_p = '('
    let g:textobj#sentence#move_n = ')'

    nnoremap <M-s> [s1z=<c-o>
    inoremap <M-s> <c-g>u<Esc>[s1z=`]A<c-g>u

    inoremap <buffer> <expr> <C-e> wordchipper#chipWith('de')
    inoremap <buffer> <expr> <C-w> wordchipper#chipWith('dB')
    inoremap <buffer> <expr> <C-y> wordchipper#chipWith('d)')

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

  augroup markdown
    autocmd!
    autocmd Filetype markdown,mkd,md,text call SetMDOptions()
  augroup END
" }}}

" stylus {{{
  augroup stylus
    autocmd!
    autocmd FileType stylus setlocal commentstring=//\ %s
  augroup END
" }}}

" typescript {{{
  augroup typescript_vue
    autocmd!
    autocmd FileType typescript setlocal re=2
    autocmd FileType vue setlocal re=2
  augroup END
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
" }}}

" rainbow parens {{{
  let g:rainbow_active = 1
" }}}

" easyalign {{{
  xmap ga <Plug>(EasyAlign)
  nmap ga <Plug>(EasyAlign)
" }}}

" gitgutter {{{
  if !exists("g:jn_statusline_updated")
    set statusline+=%{GitStatus()}
  endif
  let g:jn_statusline_updated = 1
" }}}

" vim-lightline {{{
  let g:lightline = {
        \ 'colorscheme': 'wombat',
        \ 'mode_map': {
        \ 'n' : 'N',
        \ 'i' : 'I',
        \ 'R' : 'R',
        \ 'v' : 'V',
        \ 'V' : 'VL',
        \ "\<C-v>": 'VB',
        \ 'c' : 'C',
        \ 's' : 'S',
        \ 'S' : 'SL',
        \ "\<C-s>": 'SB',
        \ 't': 'T',
        \ },
        \ 'active': {
        \   'left': [ [ 'mode', 'paste' ],
        \             [ 'gitroot', 'gitbranch', 'gitstatus', 'readonly', 'filename', 'modified' ] ]
        \ },
        \ 'component_function': {
        \   'gitbranch': 'gitbranch#name',
        \   'gitstatus': 'GitStatus',
        \   'gitroot': 'RootName'
        \ },
        \ 'component': {
        \   'filename': '%F'
        \ },
        \ }
" }}}

" Renamer {{{
  source ~/.vim/vimrc/renamer.vim
" }}}

" vim-startify {{{
  nmap <leader>H :Startify<CR>

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

  let g:startify_bookmarks = [ {'v': '~/.vimrc'}, {'z': '~/.zshrc'} ]

  let g:startify_commands = [
      \ {'c': 'Cht'},
      \ ['Vim Reference', 'h ref'],
      \ ]

  let g:startify_lists = [
        \ { 'type': 'dir',       'header': ['   MRU '. getcwd()] },
        \ { 'type': 'commands',  'header': ['   Commands']       },
        \ { 'type': 'sessions',  'header': ['   Sessions']       },
        \ { 'type': 'bookmarks', 'header': ['   Bookmarks']      },
        \ { 'type': 'files',     'header': ['   MRU']            },
        \ ]
" }}}

" vim-go {{{
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

" Pydocstring {{{
  let g:pydocstring_enable_mapping = 0
" }}}

" Persistent Undo {{{
  if has('persistent_undo')
    silent !mkdir -p ~/tmp/backups > /dev/null 2>&1
    set undodir=~/tmp/backups
    set undofile
  endif
" }}}

" vim-commentary {{{
  augroup vim_commentary
    autocmd!
    autocmd FileType vim setlocal commentstring=\"\ %s
    autocmd FileType vimrc setlocal commentstring=\"\ %s
    autocmd FileType vue setlocal commentstring=//\ %s
  augroup END
" }}}

" vim-workspace {{{
  nnoremap <leader>` :ToggleWorkspace<CR>
  let g:workspace_autosave = 0
" }}}

" vim-windowswap {{{
  let g:windowswap_map_keys = 0
  nnoremap <silent> <leader>s :call WindowSwap#EasyWindowSwap()<CR>
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

" Undotree {{{
  map <leader>u :UndotreeToggle<CR>
" }}}
