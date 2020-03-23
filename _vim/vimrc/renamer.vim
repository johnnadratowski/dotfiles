" Largely adapted from
" https://github.com/tpope/vim-abolish/blob/master/plugin/abolish.vim#L443


function! s:buildPart(part)
  let l:output = ""
  for i in range(1, strlen(a:part))
    echo strpart(a:part, i, 1)
  endfor
endfunction

function! s:command(cmd,bad,good,flags)
  echom printf("%s %s %s %s", a:cmd, a:bad, a:good, a:flags)
  s:buildPart(a:bad)
endfunction

function! s:rename(bang,line1,line2,count,args)
  if get(a:args,0,'') =~ '^[/?'']'
    let separator = matchstr(a:args[0],'^.')
    let args = split(join(a:args,' '),separator,1)
    call remove(args,0)
  else
    let args = a:args
  endif
  if len(args) < 2
    throw "Need find and replace args"
  elseif len(args) > 3
    throw "Too many args"
  endif
  let [bad,good,flags] = (args + [""])[0:2]
  if a:count == 0
    let cmd = "Subvert"
  else
    let cmd = a:line1.",".a:line2."Subvert"
  endif
  return s:command(cmd,bad,good,flags)
endfunction

command! -nargs=1 -bang -bar -range=0 Rename
      \ :exec s:rename(<bang>0,<line1>,<line2>,<count>,[<f-args>])

function! JNTest()
  s:buildPart('foo')
endfunction



