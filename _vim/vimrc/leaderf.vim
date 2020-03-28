" don't show the help in normal mode
let g:Lf_HideHelp = 1
let g:Lf_UseCache = 1
let g:Lf_UseVersionControlTool = 0
let g:Lf_IgnoreCurrentBufferName = 1
" popup mode
let g:Lf_WindowPosition = 'popup'
let g:Lf_PreviewInPopup = 0
let g:Lf_CommandMap = {'<C-K>': ['<C-p>'], '<C-J>': ['<C-n>']}

nnoremap <silent> <expr> <Plug>(leaderf-nerd) (expand('%') =~ 'NERD_tree' ? "\<c-w>\<c-w>" : '').":Leaderf file\<CR>"
nmap <silent> <leader>f <Plug>(leaderf-nerd)
nmap <silent> <expr> <C-p> ":call CDRoot()\<CR>"."<Space>f"
let g:Lf_WildIgnore = {
        \ 'dir': ['node_modules', 'vendor', '.svn','.git','.hg', '.mypy_cache'],
        \ 'file': ['*.sw?','~$*','*.bak','*.exe','*.o','*.so','*.py[co]']
        \}
