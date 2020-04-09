" don't show the help in normal mode
let g:Lf_HideHelp = 1
let g:Lf_UseCache = 1
let g:Lf_UseVersionControlTool = 0
let g:Lf_IgnoreCurrentBufferName = 1
" popup mode
" let g:Lf_WindowPosition = 'popup'
let g:Lf_PreviewInPopup = 0
let g:Lf_CommandMap = {'<C-K>': ['<C-p>'], '<C-J>': ['<C-n>']}

command! -bang -nargs=* -complete=file LeaderfRg exec printf("Leaderf<bang> rg %s", escape('<args>', '\\'))
nnoremap <C-p> :call CDRoot()<CR> <bar> :Leaderf file --popup<CR>
nnoremap <C-n> :call CDRoot()<CR> <bar> :Leaderf buffer --popup<CR>
nnoremap <leader>f :call CDRoot()<CR> <bar> :LeaderfRg --stayOpen 
nnoremap <C-f> :call CDRoot()<CR> <bar> :LeaderfRg --popup<CR>
xnoremap <C-f> :<C-U><C-R>=printf("LeaderfRg! --stayOpen -F -e %s ", leaderf#Rg#visual())<CR>
noremap go :<C-U>Leaderf! rg --recall<CR>

let g:Lf_WildIgnore = {
        \ 'dir': ['node_modules', 'vendor', '.svn','.git','.hg', '.mypy_cache'],
        \ 'file': ['*.sw?','~$*','*.bak','*.exe','*.o','*.so','*.py[co]']
        \}
