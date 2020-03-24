" Largely adapted from
" https://github.com/tpope/vim-abolish/blob/master/plugin/abolish.vim#L443


function! s:buildPart(part)
  let l:output = ""
  let l:prevWasCap = 0
  for i in range(1, strchars(a:part))
    let l:char = strcharpart(a:part, i-1, 1)
    if i == 1 || matchstr(l:char, '^\l$') == ""
      if i != 1
        let l:output ..= "{,-,_, }"
      endif
      let l:output ..= "{" .. tolower(l:char) .. "," .. toupper(l:char) .. "}"
    else 
      let l:output ..= l:char
      continue
    endif
  endfor
  return l:output
endfunction

function! s:command(cmd,bad,good,flags)
  let bad = s:buildPart(a:bad)
  let good = s:buildPart(a:good)
  return a:cmd .. "/" .. l:bad .. "/" .. l:good .. "/" .. a:flags
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
  if a:bang
    let cmd .= "!"
  endif
  return s:command(cmd,bad,good,flags)
endfunction

command! -nargs=1 -bang -bar -range=0 Rename
      \ :exec s:rename(<bang>0,<line1>,<line2>,<count>,[<f-args>])

if exists(':R') != 2
  command -nargs=1 -bang -bar -range=0 R
        \ :exec s:rename(<bang>0,<line1>,<line2>,<count>,[<f-args>])
endif

