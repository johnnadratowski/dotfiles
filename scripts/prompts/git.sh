# This is the standard prompt originally created by me

COL_SEP="\[${COL_Y}${COL_BRIGHT}\]"
COL_PTH="\[${COL_G}${COL_BRIGHT}\]"
COL_TIME="\[${COL_B}${COL_BRIGHT}\]"
COL_D="\[${COL_C}${COL_BRIGHT}\]"
COL_PROC="\[${COL_R}${COL_BRIGHT}\]"
COL_MACH="\[${COL_M}${COL_BRIGHT}\]"

PT_SEP="${COL_SEP}###${COL_RST}"
PT_PTH="${COL_PTH}\w${COL_RST}"
PT_TIME="${COL_TIME}\d \@${COL_RST}"
PT_D="${COL_D}$(parse_git_branch)${COL_RST}"
PT_PROC="${COL_PROC}\j${COL_RST}"
PT_MACH="${COL_MACH}\H${COL_RST}"

PS1="\n ${PT_SEP} ${PT_PTH} | ${PT_TIME} ${PT_SEP} ${PT_D} \n "
PS1+="\u@${PT_MACH}|(${PT_PROC})\$>"

export PS1
