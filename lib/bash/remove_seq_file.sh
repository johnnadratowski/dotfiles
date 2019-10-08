function remove () {
  local at="${1}"
  local dest="${2:-.}"

  local sep="${SEP:-_}"
  local pad="${PAD:-3}"

  if [[ "${at}" == "" ]]; then
    echo "Must specify index as first parameter"
    exit 1
  fi

  for file in ${dest}/*; do
    if [[ "${file}" =~ ([[:digit:]]{3})${sep}(.+\.{0,1}.*) ]]; then
      local num="${BASH_REMATCH[1]}"
      local filename="${BASH_REMATCH[2]}"
      if (( num > at )); then
        mv "${file}" "${dest}/$(printf "%0${pad}d\n" "$(( num - 1))")${sep}${filename}"
      elif (( num == at )); then
        rm "${file}"
      fi
    fi
  done
}

remove $@