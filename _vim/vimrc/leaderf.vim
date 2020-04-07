" don't show the help in normal mode
let g:Lf_HideHelp = 1
let g:Lf_UseCache = 1
let g:Lf_UseVersionControlTool = 0
let g:Lf_IgnoreCurrentBufferName = 1
" popup mode
" let g:Lf_WindowPosition = 'popup'
let g:Lf_PreviewInPopup = 0
let g:Lf_CommandMap = {'<C-K>': ['<C-p>'], '<C-J>': ['<C-n>']}

nnoremap <C-p> :call CDRoot()<CR> <bar> :call DeselectNERDTree()<CR> <bar> :Leaderf file --popup<CR>
nnoremap <C-n> :call CDRoot()<CR> <bar> :call DeselectNERDTree()<CR> <bar> :Leaderf buffer --popup<CR>
nnoremap <leader>f :call CDRoot()<CR> <bar> :call DeselectNERDTree() <bar> :Leaderf rg 
nnoremap <C-f> :call CDRoot()<CR> <bar> :call DeselectNERDTree() <bar> :Leaderf rg<CR>

" nnoremap <silent> <expr> <Plug>(leaderf-nerd) (expand('%') =~ 'NERD_tree' ? "\<c-w>\<c-w>" : '').":Leaderf file\<CR>"
" nnoremap <silent> <expr> <Plug>(leaderf-nerd-buffer) (expand('%') =~ 'NERD_tree' ? "\<c-w>\<c-w>" : '').":Leaderf buffer\<CR>"
" nnoremap <silent> <expr> <Plug>(leaderf-nerd-rg) (expand('%') =~ 'NERD_tree' ? "\<c-w>\<c-w>" : '').":Leaderf rg\<CR>"
" nmap <silent> <leader>f <Plug>(leaderf-nerd)
" nmap <silent> <leader>m <Plug>(leaderf-nerd-buffer)
" nmap <silent> <leader>h <Plug>(leaderf-nerd-rg)
" nmap <silent> <expr> <C-p> ":call CDRoot()\<CR>"."<Space>f"
" nmap <silent> <expr> p  ":call CDRoot()\<CR>"."<Space>m"
" nmap <silent> <C-f> :call DeselectNERDTree() <bar> :Leaderf rg<CR>

let g:Lf_WildIgnore = {
        \ 'dir': ['node_modules', 'vendor', '.svn','.git','.hg', '.mypy_cache'],
        \ 'file': ['*.sw?','~$*','*.bak','*.exe','*.o','*.so','*.py[co]']
        \}
