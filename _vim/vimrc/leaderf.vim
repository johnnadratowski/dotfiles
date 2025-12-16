" don't show the help in normal mode
let g:Lf_HideHelp = 1
let g:Lf_UseCache = 0
let g:Lf_UseMemoryCache = 0
let g:Lf_UseVersionControlTool = 0
let g:Lf_IgnoreCurrentBufferName = 1
let g:Lf_ShowHidden = 1
" popup mode
" let g:Lf_WindowPosition = 'popup'
let g:Lf_PreviewInPopup = 1
let g:Lf_CommandMap = {'<C-K>': ['<C-p>'], '<C-J>': ['<C-n>']}

" Exit fullscreen before opening LeaderF to avoid window sizing issues
function! s:ExitFullscreenForLeaderf()
  if exists('g:fullscreen_window') && g:fullscreen_window != 0
    let l:saved_sizes = g:fullscreen_saved_sizes
    let g:fullscreen_window = 0
    let g:fullscreen_saved_sizes = {}
    if exists('*s:RestoreWindowSizes')
      call s:RestoreWindowSizes(l:saved_sizes)
    else
      execute "normal! \<C-w>="
    endif
  endif
endfunction

command! -bang -nargs=* -complete=file LeaderfRg exec printf("Leaderf<bang> rg %s", escape('<args>', '\\'))
nnoremap <leader>p :call <SID>ExitFullscreenForLeaderf() <bar> :call CDRoot() <bar> :Leaderf file --popup<CR>
nnoremap <C-p> :call <SID>ExitFullscreenForLeaderf() <bar> :call CDGitRoot() <bar> :Leaderf file --popup<CR>
nnoremap <C-b> :call <SID>ExitFullscreenForLeaderf() <bar> :call CDRoot() <bar> :Leaderf buffer --popup<CR>
nnoremap <C-f> :call <SID>ExitFullscreenForLeaderf() <bar> :call CDGitRoot() <bar> :Leaderf --stayOpen rg 
xnoremap <C-f> :<C-U>call <SID>ExitFullscreenForLeaderf() <bar> <C-R>=printf("LeaderfRg! --stayOpen -F -e %s ", leaderf#Rg#visual())<CR>

let g:Lf_WildIgnore = {
        \ 'dir': ['node_modules', 'vendor', '.svn','.git','.hg', '.mypy_cache', 'public'],
        \ 'file': ['*.sw?','~$*','*.bak','*.exe','*.o','*.so','*.py[co]','Pipfile.lock','pi.txt']
        \}
