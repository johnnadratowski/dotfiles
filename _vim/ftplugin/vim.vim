 noremap <silent><buffer> <F8> <ESC>:w<CR> <bar> :exec 'source '.bufname('%')<CR> <bar> :echom "Reloaded File"<CR>
 noremap <silent><buffer> <F9> <ESC>:w<CR> <bar> :exec 'source '.bufname('%')<CR> <bar> :echom "Reloaded File"<CR> <bar> :normal! @:<CR>
 noremap <silent><buffer> <F10> <ESC>:w<CR> <bar> :exec 'source '.bufname('%')<CR> <bar> :echom "Reloaded File"<CR> <bar> :call JNTest()<CR>
