" Largely adapted from
" https://github.com/tpope/vim-abolish/blob/master/plugin/abolish.vim#L443


function! s:command(cmd,bad,good,flags)
  debug
  return a:cmd.'/'.lhs.'/\=Abolished()'."/".opts.flags
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
    call s:throw("E471: Argument required")
  elseif len(args) > 3
    call s:throw("E488: Trailing characters")
  endif
  let [bad,good,flags] = (args + [""])[0:2]
  if a:count == 0
    let cmd = "substitute"
  else
    let cmd = a:line1.",".a:line2."substitute"
  endif
  return s:substitute_command(cmd,bad,good,flags)
endfunction

command! -nargs=1 -bang -bar -range=0 Rename
      \ :exec s:rename(<bang>0,<line1>,<line2>,<count>,<q-args>)

